package app.alextran.immich.shell

import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.os.Build
import android.provider.MediaStore
import android.view.View
import androidx.activity.BackEventCompat
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.MutatorMutex
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.center
import androidx.compose.ui.geometry.lerp
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import app.alextran.immich.core.HttpClientManager
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * A native viewer over one timeline session. Its own layer in the tab's stack, not a mirrored
 * frame: Dart declined its route, so there is nothing for `sync` to carry.
 */
class ViewerState(
  val session: Int,
  val source: TimelineSource,
  startIndex: Int,
  /** The grid this opened from, when it did; drives the zoom in and out. */
  val grid: TimelineGridState?,
) {
  var index by mutableIntStateOf(startIndex)
  var zoomed by mutableStateOf(false)
  var chrome by mutableStateOf(true)

  /** The picture each composed page is currently showing, for the flying image and the HDR badge. */
  val pageBitmaps = mutableStateMapOf<Int, Bitmap>()

  /** Predictive back in flight: 0 untouched, 1 fully drawn back. */
  var backProgress by mutableFloatStateOf(0f)
    private set
  var backEdge by mutableStateOf(BackEventCompat.EDGE_LEFT)
  private val motion = MutatorMutex()

  /** Set once; the layer runs the exit and then reports itself closed. */
  var closing by mutableStateOf(false)
    private set

  suspend fun scrub(event: BackEventCompat) {
    backEdge = event.swipeEdge
    motion.mutate { backProgress = event.progress }
  }

  suspend fun cancelBack() = motion.mutate {
    animate(backProgress, 0f, animationSpec = tween(TabStack.CANCEL_MS)) { value, _ -> backProgress = value }
  }

  fun close() {
    closing = true
  }
}

@Composable
fun AssetViewerLayer(viewer: ViewerState, onClosed: () -> Unit) {
  val source = viewer.source
  val context = LocalContext.current

  // Willing to draw above SDR white while this is up, or the gain map is flattened at the last step.
  DisposableEffect(Unit) {
    val window = context.findActivity()?.window
    val previous = window?.colorMode ?: ActivityInfo.COLOR_MODE_DEFAULT
    if (window != null) {
      window.colorMode = ActivityInfo.COLOR_MODE_HDR
      shellLog("[shell:hdr] window colorMode=hdr (wide gamut ${window.isWideColorGamut})")
    }
    onDispose { window?.colorMode = previous }
  }

  var layerOrigin by remember { mutableStateOf(Offset.Zero) }
  BoxWithConstraints(Modifier.fillMaxSize().onGloballyPositioned { layerOrigin = it.positionInRoot() }) {
    val viewport = IntSize(constraints.maxWidth, constraints.maxHeight)
    val open = remember { Animatable(0f) }
    var flying by remember { mutableStateOf(true) }
    var dragY by remember { mutableFloatStateOf(0f) }
    val scope = rememberCoroutineScope()
    val dismiss = (dragY / (viewport.height * 0.4f)).coerceIn(0f, 1f)
    val back = viewer.backProgress
    val shrink = max(dismiss * 0.25f, back * 0.1f)
    val direction = if (viewer.backEdge == BackEventCompat.EDGE_RIGHT) -1f else 1f

    val bitmap = viewer.pageBitmaps[viewer.index]
      ?: source.asset(viewer.index)?.let { ThumbnailLoader.bestCached(it, listOf(viewport.width, viewer.grid?.tilePx ?: 0)) }

    LaunchedEffect(Unit) {
      viewer.grid?.hiddenIndex = viewer.index
      open.animateTo(1f, tween(ENTER_MS, easing = FastOutSlowInEasing))
      flying = false
    }
    LaunchedEffect(viewer.closing) {
      if (!viewer.closing) return@LaunchedEffect
      viewer.chrome = false
      viewer.grid?.let { grid ->
        grid.reveal?.invoke(viewer.index)
        grid.hiddenIndex = viewer.index
      }
      flying = true
      open.animateTo(0f, tween(EXIT_MS, easing = FastOutSlowInEasing))
      viewer.grid?.hiddenIndex = -1
      onClosed()
    }

    // Backdrop: black is where HDR reads best, and it fades with any gesture that would leave.
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = open.value * (1f - dismiss) * (1f - 0.3f * back))))

    val content = Modifier
      .fillMaxSize()
      .graphicsLayer {
        val scale = 1f - shrink
        scaleX = scale
        scaleY = scale
        translationY = dragY
        translationX = direction * size.width * 0.08f * back
        alpha = if (flying) 0f else 1f
        val radius = 28.dp * max(dismiss, back)
        shape = RoundedCornerShape(radius)
        clip = shrink > 0f
      }
      .draggable(
        orientation = Orientation.Vertical,
        enabled = !viewer.zoomed && !flying,
        state = rememberDraggableState { delta -> dragY = max(0f, dragY + delta) },
        onDragStopped = { velocity ->
          if (dismiss > 0.3f || velocity > 1500f) {
            viewer.close()
          } else {
            animate(dragY, 0f, animationSpec = tween(TabStack.CANCEL_MS)) { value, _ -> dragY = value }
          }
        },
      )

    val pagerState = rememberPagerState(initialPage = viewer.index) { source.total }
    LaunchedEffect(pagerState) {
      snapshotFlow { pagerState.settledPage }.collect { page ->
        viewer.index = page
        viewer.zoomed = false
        source.prefetch(page - 1)
        source.prefetch(page + 1)
      }
    }
    HorizontalPager(
      state = pagerState,
      modifier = content,
      beyondViewportPageCount = 1,
      pageSpacing = 16.dp,
      userScrollEnabled = !viewer.zoomed && dragY == 0f,
      key = { it },
    ) { page ->
      val asset = source.asset(page)
      val current = page == pagerState.settledPage
      AssetPage(
        viewer = viewer,
        page = page,
        asset = asset,
        viewport = viewport,
        current = current,
        onTap = { viewer.chrome = !viewer.chrome },
        onZoom = { zoomed -> if (current) viewer.zoomed = zoomed },
      )
    }

    // The flight: the tile's picture grows into the page's frame, or shrinks back into the tile.
    if (flying && bitmap != null) {
      val fit = fitRect(Size(bitmap.width.toFloat(), bitmap.height.toFloat()), viewport)
      val scaled = fit.scaledAbout(fit.center, 1f - shrink).translate(0f, dragY)
      val tile = viewer.grid?.tileBounds?.get(viewer.index)?.translate(-layerOrigin)
      val from = tile ?: scaled.scaledAbout(scaled.center, 0.85f)
      val rect = lerp(from, scaled, open.value)
      val image = remember(bitmap) { bitmap.asImageBitmap() }
      Image(
        image,
        contentDescription = null,
        contentScale = ContentScale.Crop,
        modifier = Modifier
          .offset { IntOffset(rect.left.roundToInt(), rect.top.roundToInt()) }
          .size(with(LocalDensity.current) { rect.width.toDp() }, with(LocalDensity.current) { rect.height.toDp() })
          .graphicsLayer { if (tile == null) alpha = open.value },
      )
    }

    ViewerChrome(viewer, bitmap, visible = viewer.chrome && !flying && dragY == 0f && back == 0f, onBack = viewer::close)
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ViewerChrome(viewer: ViewerState, bitmap: Bitmap?, visible: Boolean, onBack: () -> Unit) {
  val asset = viewer.source.asset(viewer.index)
  AnimatedVisibility(visible, enter = fadeIn(tween(150)), exit = fadeOut(tween(150))) {
    Box(
      Modifier
        .fillMaxWidth()
        .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.6f), Color.Transparent))),
    ) {
      TopAppBar(
        title = {
          Column {
            Text(asset?.let { dateTitle(it.createdAt) } ?: "", style = MaterialTheme.typography.titleMedium)
            Text(asset?.let { timeTitle(it.createdAt) } ?: "", style = MaterialTheme.typography.bodySmall)
          }
        },
        navigationIcon = {
          IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "Back") }
        },
        actions = {
          if (Build.VERSION.SDK_INT >= 34 && bitmap?.hasGainmap() == true) {
            Text(
              "HDR",
              style = MaterialTheme.typography.labelMedium,
              color = Color.White,
              modifier = Modifier
                .padding(end = 12.dp)
                .background(Color.White.copy(alpha = 0.2f), RoundedCornerShape(6.dp))
                .padding(horizontal = 6.dp, vertical = 2.dp),
            )
          }
        },
        colors = TopAppBarDefaults.topAppBarColors(
          containerColor = Color.Transparent,
          titleContentColor = Color.White,
          navigationIconContentColor = Color.White,
          actionIconContentColor = Color.White,
        ),
      )
    }
  }
}

@Composable
private fun AssetPage(
  viewer: ViewerState,
  page: Int,
  asset: TimelineAsset?,
  viewport: IntSize,
  current: Boolean,
  onTap: () -> Unit,
  onZoom: (Boolean) -> Unit,
) {
  if (asset == null) {
    Box(Modifier.fillMaxSize()) { CircularProgressIndicator(Modifier.align(Alignment.Center)) }
    return
  }
  val tilePx = viewer.grid?.tilePx?.takeIf { it > 0 } ?: 256
  val thumb = rememberThumbnail(asset, tilePx)
  val preview = rememberThumbnail(asset, viewport.width, ThumbnailLoader.Level.PREVIEW)
  // The original — and with it the gain map — only for the page that is actually up.
  val original = rememberThumbnail(
    asset, max(viewport.width, viewport.height), ThumbnailLoader.Level.ORIGINAL, hdr = true,
    enabled = current && !asset.isVideo,
  )
  val shown = original ?: preview ?: thumb
  SideEffect { if (shown != null) viewer.pageBitmaps[page] = shown }
  DisposableEffect(page) { onDispose { viewer.pageBitmaps.remove(page) } }

  if (asset.isVideo) {
    VideoPage(asset, current, placeholder = shown, onChrome = { viewer.chrome = it })
    return
  }
  if (shown == null) {
    Box(Modifier.fillMaxSize()) { CircularProgressIndicator(Modifier.align(Alignment.Center)) }
    return
  }
  ZoomableImage(shown, onTap = onTap, onZoom = onZoom)
}

@Composable
private fun ZoomableImage(bitmap: Bitmap, onTap: () -> Unit, onZoom: (Boolean) -> Unit) {
  var scale by remember { mutableFloatStateOf(1f) }
  var offset by remember { mutableStateOf(Offset.Zero) }
  val scope = rememberCoroutineScope()
  val image = remember(bitmap) { bitmap.asImageBitmap() }
  val zoomMutex = remember { MutatorMutex() }

  BoxWithConstraints(Modifier.fillMaxSize()) {
    val box = Size(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
    val fit = fitRect(Size(bitmap.width.toFloat(), bitmap.height.toFloat()), IntSize(constraints.maxWidth, constraints.maxHeight)).size

    fun clamp(target: Offset, at: Float): Offset {
      val maxX = max(0f, (fit.width * at - box.width) / 2f)
      val maxY = max(0f, (fit.height * at - box.height) / 2f)
      return Offset(target.x.coerceIn(-maxX, maxX), target.y.coerceIn(-maxY, maxY))
    }

    fun zoomTo(targetScale: Float, focus: Offset) {
      val startScale = scale
      val startOffset = offset
      val c = focus - box.center
      val endOffset = clamp((startOffset - c) * (targetScale / startScale) + c, targetScale)
      scope.launch {
        zoomMutex.mutate {
          animate(0f, 1f, animationSpec = tween(250, easing = FastOutSlowInEasing)) { t, _ ->
            scale = startScale + (targetScale - startScale) * t
            offset = lerp(startOffset, endOffset, t)
          }
          onZoom(scale > 1.01f)
        }
      }
    }

    Image(
      image,
      contentDescription = null,
      contentScale = ContentScale.Fit,
      modifier = Modifier
        .fillMaxSize()
        .pointerInput(fit) {
          detectTapGestures(
            onTap = { onTap() },
            onDoubleTap = { tap -> zoomTo(if (scale > 1.01f) 1f else 2.5f, tap) },
          )
        }
        .pointerInput(fit) {
          awaitEachGesture {
            awaitFirstDown(requireUnconsumed = false)
            do {
              val event = awaitPointerEvent()
              val pinch = event.changes.size > 1
              if (!pinch && scale <= 1.01f) continue
              val zoomChange = event.calculateZoom()
              val pan = event.calculatePan()
              if (zoomChange == 1f && pan == Offset.Zero) continue
              val next = (scale * zoomChange).coerceIn(1f, 6f)
              val c = event.calculateCentroid() - box.center
              offset = clamp((offset - c) * (next / scale) + c + pan, next)
              scale = next
              event.changes.forEach { if (it.positionChanged()) it.consume() }
            } while (event.changes.any { it.pressed })
            if (scale < 1.05f && scale != 1f) {
              scale = 1f
              offset = Offset.Zero
            }
            onZoom(scale > 1.01f)
          }
        }
        .graphicsLayer {
          scaleX = scale
          scaleY = scale
          translationX = offset.x
          translationY = offset.y
        },
    )
  }
}

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun VideoPage(asset: TimelineAsset, current: Boolean, placeholder: Bitmap?, onChrome: (Boolean) -> Unit) {
  val context = LocalContext.current
  var firstFrame by remember(asset.id) { mutableStateOf(false) }
  val player = remember(asset.id) {
    val (uri, factory) = videoSource(context, asset)
    ExoPlayer.Builder(context)
      .setMediaSourceFactory(DefaultMediaSourceFactory(factory))
      .build()
      .apply {
        setMediaItem(MediaItem.fromUri(uri))
        prepare()
        addListener(object : androidx.media3.common.Player.Listener {
          override fun onRenderedFirstFrame() {
            firstFrame = true
          }
        })
      }
  }
  DisposableEffect(player) { onDispose { player.release() } }
  LaunchedEffect(current) {
    player.playWhenReady = current
    if (!current) player.seekTo(0)
  }
  // The controller sits at the bottom edge, so that edge must clear the system bars.
  Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.navigationBars)) {
    // A `SurfaceView` for HDR passthrough: the display gets the frames as decoded.
    AndroidView(
      modifier = Modifier.fillMaxSize(),
      factory = { ctx ->
        PlayerView(ctx).apply {
          this.player = player
          useController = true
          setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
          controllerAutoShow = false
          setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { onChrome(it == View.VISIBLE) })
        }
      },
      update = { it.player = player },
    )
    if (!firstFrame && placeholder != null) {
      val image = remember(placeholder) { placeholder.asImageBitmap() }
      Image(image, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
    }
  }
}

@androidx.annotation.OptIn(UnstableApi::class)
private fun videoSource(context: Context, asset: TimelineAsset): Pair<android.net.Uri, DataSource.Factory> {
  val remote = asset.playbackUrl ?: asset.originalUrl
  if (remote != null) {
    return android.net.Uri.parse(remote) to HttpClientManager.createDataSourceFactory(HttpClientManager.getAuthHeaders(remote))
  }
  val id = asset.localId?.toLongOrNull() ?: 0L
  return ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id) to DefaultDataSource.Factory(context)
}

/** The largest rect of [size]'s aspect that fits centred in [viewport]. */
private fun fitRect(size: Size, viewport: IntSize): Rect {
  if (size.width <= 0f || size.height <= 0f) return Rect(0f, 0f, viewport.width.toFloat(), viewport.height.toFloat())
  val scale = min(viewport.width / size.width, viewport.height / size.height)
  val w = size.width * scale
  val h = size.height * scale
  val left = (viewport.width - w) / 2f
  val top = (viewport.height - h) / 2f
  return Rect(left, top, left + w, top + h)
}

private fun Rect.scaledAbout(pivot: Offset, factor: Float): Rect {
  val w = width * factor
  val h = height * factor
  return Rect(pivot.x - w / 2f, pivot.y - h / 2f, pivot.x + w / 2f, pivot.y + h / 2f)
}

private fun Rect.translate(dx: Float, dy: Float) = Rect(left + dx, top + dy, right + dx, bottom + dy)
private fun Rect.translate(by: Offset) = translate(by.x, by.y)

private fun Context.findActivity(): Activity? {
  var current: Context? = this
  while (current is ContextWrapper) {
    if (current is Activity) return current
    current = current.baseContext
  }
  return null
}

private val dateFormat = DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG)
private val timeFormat = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)

private fun dateTitle(epochMs: Long) = dateFormat.format(Instant.ofEpochMilli(epochMs).atZone(ZoneId.systemDefault()))
private fun timeTitle(epochMs: Long) = timeFormat.format(Instant.ofEpochMilli(epochMs).atZone(ZoneId.systemDefault()))

private const val ENTER_MS = 350
private const val EXIT_MS = 250
