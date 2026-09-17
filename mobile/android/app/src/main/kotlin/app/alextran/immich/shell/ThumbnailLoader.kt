package app.alextran.immich.shell

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import android.os.SystemClock
import android.provider.MediaStore
import android.util.LruCache
import android.util.Size
import androidx.annotation.RequiresApi
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import app.alextran.immich.core.HttpClientManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min

/**
 * Pictures for the native grid and viewer: the server's thumbnail, preview or original for a
 * remote asset, the MediaStore's for a local one, decoded to fill a square of [sizePx] and kept
 * in one memory cache. Glide is configured with every cache off (Dart caches on its side), so
 * this does not go through it.
 *
 * HDR is a decode option, not a display one: an Ultra HDR JPEG decoded through `ImageDecoder`
 * on 14+ carries its gain map, and the viewer's window then draws it above SDR white. Grid
 * thumbnails drop the map so a wall of highlights does not glare.
 */
object ThumbnailLoader {
  enum class Level { THUMB, PREVIEW, ORIGINAL }

  private val cache = object : LruCache<String, Bitmap>(CACHE_BYTES) {
    override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
  }

  /** Main thread only, so one decode serves every cell that asks for the same picture. */
  private val inFlight = HashMap<String, Deferred<Bitmap?>>()
  private val waiters = HashMap<String, Int>()
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  // Mostly waiting on the network; a fling composes hundreds of cells and the visible ones must
  // not queue behind the ones it flew past.
  @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
  private val decoders = Dispatchers.IO.limitedParallelism(12)

  fun key(asset: TimelineAsset, sizePx: Int, level: Level, hdr: Boolean) =
    "${asset.id}@$sizePx/${level.ordinal}${if (hdr) "h" else ""}"

  fun cached(asset: TimelineAsset, sizePx: Int, level: Level = Level.THUMB, hdr: Boolean = false): Bitmap? =
    cache.get(key(asset, sizePx, level, hdr))

  /** The best picture already decoded for an asset, largest first. */
  fun bestCached(asset: TimelineAsset, sizes: List<Int>): Bitmap? {
    for (size in sizes) {
      cached(asset, size, Level.ORIGINAL, hdr = true)?.let { return it }
      cached(asset, size, Level.PREVIEW)?.let { return it }
      cached(asset, size, Level.THUMB)?.let { return it }
    }
    return null
  }

  suspend fun load(context: Context, asset: TimelineAsset, sizePx: Int, level: Level, hdr: Boolean): Bitmap? {
    val key = key(asset, sizePx, level, hdr)
    cache.get(key)?.let { return it }
    val job = inFlight.getOrPut(key) {
      scope.async {
        val started = SystemClock.uptimeMillis()
        val bitmap = withContext(decoders) {
          runCatching { fetch(context.applicationContext, asset, sizePx, level, hdr) }
            .onFailure { shellLog("[shell:thumb] ${asset.name} $level failed: $it") }
            .getOrNull()
        }
        if (bitmap != null) {
          if (!hdr && Build.VERSION.SDK_INT >= 34 && bitmap.hasGainmap()) bitmap.gainmap = null
          cache.put(key, bitmap)
          if (level != Level.THUMB) {
            val gain = Build.VERSION.SDK_INT >= 34 && bitmap.hasGainmap()
            shellLog("[shell:thumb] ${asset.name} $level ${bitmap.width}x${bitmap.height} gainmap=$gain in ${SystemClock.uptimeMillis() - started}ms")
          }
        }
        inFlight.remove(key)
        bitmap
      }
    }
    waiters[key] = (waiters[key] ?: 0) + 1
    try {
      return job.await()
    } finally {
      val left = (waiters[key] ?: 1) - 1
      if (left <= 0) {
        waiters.remove(key)
        // The last cell that wanted this scrolled away: a fetch not yet started is dropped.
        if (inFlight[key] === job && job.isActive) {
          job.cancel()
          inFlight.remove(key)
        }
      } else {
        waiters[key] = left
      }
    }
  }

  private fun fetch(context: Context, asset: TimelineAsset, sizePx: Int, level: Level, hdr: Boolean): Bitmap? {
    val url = when (level) {
      Level.THUMB -> asset.thumbUrl
      Level.PREVIEW -> asset.previewUrl ?: asset.thumbUrl
      Level.ORIGINAL -> asset.originalUrl ?: asset.previewUrl
    }
    if (url != null) return fetchRemote(url, sizePx, hdr)
    val id = asset.localId?.toLongOrNull() ?: return null
    return fetchLocal(context, id, asset.isVideo, sizePx, level, hdr)
  }

  private fun fetchRemote(url: String, sizePx: Int, hdr: Boolean): Bitmap? {
    val request = Request.Builder().url(url).apply {
      HttpClientManager.getAuthHeaders(url).forEach { (name, value) -> header(name, value) }
    }.build()
    val bytes = HttpClientManager.getClient().newCall(request).execute().use { response ->
      if (!response.isSuccessful) {
        shellLog("[shell:thumb] $url -> ${response.code}")
        return null
      }
      response.body?.bytes() ?: return null
    }
    return decode(bytes, sizePx, hdr)
  }

  private fun fetchLocal(context: Context, id: Long, isVideo: Boolean, sizePx: Int, level: Level, hdr: Boolean): Bitmap? {
    val resolver = context.contentResolver
    val collection = if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    val uri = ContentUris.withAppendedId(collection, id)
    if (isVideo || level == Level.THUMB) {
      // The MediaStore's own thumbnail: cheap, and the only frame there is for a video.
      return when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
          resolver.loadThumbnail(uri, if (sizePx > 0) Size(sizePx, sizePx) else Size(768, 768), null)
        isVideo -> MediaStore.Video.Thumbnails.getThumbnail(resolver, id, MediaStore.Video.Thumbnails.MINI_KIND, null)
        else -> MediaStore.Images.Thumbnails.getThumbnail(resolver, id, MediaStore.Images.Thumbnails.MINI_KIND, null)
      }
    }
    // The file itself, sampled to the target; on 14+ the gain map comes with it.
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      return ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
        configure(decoder, info, sizePx, hdr)
      }
    }
    val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
    return decode(bytes, sizePx, hdr)
  }

  private fun decode(bytes: ByteArray, sizePx: Int, hdr: Boolean): Bitmap? {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      return ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
        configure(decoder, info, sizePx, hdr)
      }
    }
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, sizePx) }
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
  }

  /** Samples so the shorter side still covers [sizePx]: a square cell crops, a page fits. */
  @RequiresApi(Build.VERSION_CODES.P)
  private fun configure(decoder: ImageDecoder, info: ImageDecoder.ImageInfo, sizePx: Int, hdr: Boolean) {
    val sample = sampleSize(info.size.width, info.size.height, sizePx)
    if (sample > 1) decoder.setTargetSampleSize(sample)
    if (hdr) return
    // Nothing skips the map at decode time; it is dropped after (see [load]).
  }

  private fun sampleSize(width: Int, height: Int, sizePx: Int): Int {
    if (sizePx <= 0 || width <= 0 || height <= 0) return 1
    var sample = 1
    while (min(width, height) / (sample * 2) >= sizePx) sample *= 2
    return sample
  }

  private const val CACHE_BYTES = 128 shl 20
}

/** Per-cell load tracing; too chatty to leave on. */
private const val THUMB_TRACE = false


/** A load's outcome: the picture, or that there is none to be had, or neither yet. */
class Thumbnail(val bitmap: Bitmap?, val failed: Boolean) {
  companion object {
    val LOADING = Thumbnail(null, failed = false)
    val FAILED = Thumbnail(null, failed = true)
  }
}

/**
 * The picture for [asset] at [sizePx], from the cache immediately or after a load; null while
 * loading and for a null asset. Keyed on the asset so a reused cell never shows its predecessor.
 */
@Composable
fun rememberThumbnail(
  asset: TimelineAsset?,
  sizePx: Int,
  level: ThumbnailLoader.Level = ThumbnailLoader.Level.THUMB,
  hdr: Boolean = false,
  enabled: Boolean = true,
): Bitmap? = rememberThumbnailState(asset, sizePx, level, hdr, enabled).bitmap

@Composable
fun rememberThumbnailState(
  asset: TimelineAsset?,
  sizePx: Int,
  level: ThumbnailLoader.Level = ThumbnailLoader.Level.THUMB,
  hdr: Boolean = false,
  enabled: Boolean = true,
): Thumbnail {
  val context = LocalContext.current
  val key = asset?.let { ThumbnailLoader.key(it, sizePx, level, hdr) }
  var state by remember(key) {
    mutableStateOf(asset?.let { ThumbnailLoader.cached(it, sizePx, level, hdr) }?.let { Thumbnail(it, failed = false) } ?: Thumbnail.LOADING)
  }
  LaunchedEffect(key, enabled) {
    if (asset == null || sizePx <= 0 || state.bitmap != null || !enabled) return@LaunchedEffect
    if (THUMB_TRACE) shellLog("[shell:thumb] > ${asset.name} $level@$sizePx")
    val loaded = ThumbnailLoader.load(context, asset, sizePx, level, hdr)
    if (THUMB_TRACE) shellLog("[shell:thumb] < ${asset.name} $level@$sizePx ${if (loaded == null) "NULL" else "ok"}")
    state = if (loaded == null) Thumbnail.FAILED else Thumbnail(loaded, failed = false)
  }
  return state
}
