package app.alextran.immich.shell

import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The native half of `immich/timeline`. Timelines are numbered sessions; `0` is the main one and
 * the rest are opened by Dart when a screen with its own timeline hands one over.
 */
object TimelineSessions {
  const val MAIN = 0

  private var channel: MethodChannel? = null
  private val sources = HashMap<Int, TimelineSource>()

  fun attach(engine: FlutterEngine) {
    val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "immich/timeline")
    channel.setMethodCallHandler { call, result ->
      @Suppress("UNCHECKED_CAST")
      val args = call.arguments as? Map<String, Any?> ?: emptyMap()
      when (call.method) {
        "invalidate" -> source((args["session"] as? Number)?.toInt() ?: MAIN)?.apply(args)
        else -> shellLog("[shell:timeline] unhandled dart call ${call.method}")
      }
      result.success(null)
    }
    this.channel = channel
  }

  fun source(session: Int): TimelineSource? {
    sources[session]?.let { return it }
    val channel = channel ?: run {
      shellLog("[shell:timeline] session $session before the engine; dropped")
      return null
    }
    return TimelineSource(session, channel).also { sources[session] = it }
  }

  fun close(session: Int) {
    if (session == MAIN || sources.remove(session) == null) return
    shellLog("[shell:timeline] session $session closed")
    channel?.invokeMethod("closeSession", mapOf("session" to session))
  }
}

/** One asset as Dart described it. URLs are present only for assets with a `remoteId`. */
class TimelineAsset(
  val name: String,
  val localId: String?,
  val remoteId: String?,
  val isVideo: Boolean,
  val durationMs: Long?,
  /** Epoch millis. */
  val createdAt: Long,
  val isFavorite: Boolean,
  val thumbUrl: String?,
  val previewUrl: String?,
  val originalUrl: String?,
  val playbackUrl: String?,
) {
  /** Stable across sessions and sizes; what caches key on. */
  val id: String get() = remoteId ?: localId ?: name

  companion object {
    fun from(raw: Map<*, *>): TimelineAsset? {
      val name = raw["name"] as? String ?: return null
      return TimelineAsset(
        name = name,
        localId = raw["localId"] as? String,
        remoteId = raw["remoteId"] as? String,
        isVideo = raw["isVideo"] == true,
        durationMs = (raw["durationMs"] as? Number)?.toLong(),
        createdAt = (raw["createdAt"] as? Number)?.toLong() ?: 0L,
        isFavorite = raw["isFavorite"] == true,
        thumbUrl = raw["thumbUrl"] as? String,
        previewUrl = raw["previewUrl"] as? String,
        originalUrl = raw["originalUrl"] as? String,
        playbackUrl = raw["playbackUrl"] as? String,
      )
    }
  }
}

/**
 * A window onto one Dart timeline. Offsets, page size and window completeness are Dart's; what
 * is left here is what a grid needs synchronously, as Compose state so cells redraw when a page
 * lands.
 */
class TimelineSource(val session: Int, private val channel: MethodChannel) {
  class Section(val date: Long?, val count: Int, val offset: Int)

  var sections by mutableStateOf<List<Section>>(emptyList())
    private set
  var total by mutableIntStateOf(0)
    private set

  /** A window from an older generation describes indices that have since moved. */
  var generation by mutableIntStateOf(-1)
    private set

  var pageSize = 120
    private set

  private val pages = mutableStateMapOf<Int, List<TimelineAsset>>()
  private val inFlight = HashSet<Int>()

  /**
   * The previous generation's pages, served until their replacements land. Dart invalidates on
   * every bucket emission — every ten seconds on a syncing library — and a grid that dropped to
   * placeholders each time would flash. Kept only while the timeline's shape is unchanged; if the
   * total moved, these indices mean something else now.
   */
  private val stale = HashMap<Int, List<TimelineAsset>>()

  /** A signal, not a query: Dart answers with an `invalidate`. */
  fun open() {
    channel.invokeMethod("open", mapOf("session" to session))
  }

  fun apply(args: Map<String, Any?>) {
    val next = (args["sections"] as? List<*> ?: emptyList<Any>()).mapNotNull { raw ->
      val map = raw as? Map<*, *> ?: return@mapNotNull null
      Section(
        date = (map["date"] as? Number)?.toLong(),
        count = (map["count"] as? Number)?.toInt() ?: 0,
        offset = (map["offset"] as? Number)?.toInt() ?: 0,
      )
    }
    val nextTotal = (args["total"] as? Number)?.toInt() ?: next.sumOf { it.count }
    val nextPageSize = (args["pageSize"] as? Number)?.toInt() ?: pageSize
    if (nextTotal == total && next.size == sections.size && nextPageSize == pageSize) {
      stale.putAll(pages)
    } else {
      stale.clear()
    }
    sections = next
    total = nextTotal
    pageSize = nextPageSize
    generation = (args["generation"] as? Number)?.toInt() ?: generation
    pages.clear()
    inFlight.clear()
    shellLog("[shell:timeline] session=$session gen=$generation sections=${sections.size} total=$total")
  }

  /** The asset at a flat index, requesting its page if it is not here; null until it is. */
  fun asset(flatIndex: Int): TimelineAsset? {
    if (flatIndex < 0 || flatIndex >= total) return null
    val page = flatIndex / pageSize
    val loaded = pages[page] ?: run {
      request(page)
      stale[page] ?: return null
    }
    return loaded.getOrNull(flatIndex - page * pageSize)
  }

  fun prefetch(flatIndex: Int) {
    if (flatIndex in 0 until total) request(flatIndex / pageSize)
  }

  /** The section holding a flat index: the last one whose offset is not past it. */
  fun sectionIndex(flatIndex: Int): Int {
    val sections = sections
    var lo = 0
    var hi = sections.size - 1
    var found = 0
    while (lo <= hi) {
      val mid = (lo + hi) ushr 1
      if (sections[mid].offset <= flatIndex) {
        found = mid
        lo = mid + 1
      } else {
        hi = mid - 1
      }
    }
    return found
  }

  private fun request(page: Int) {
    if (page in inFlight || pages.containsKey(page)) return
    inFlight.add(page)
    val asked = generation
    val started = SystemClock.uptimeMillis()
    shellLog("[shell:timeline] session=$session page=$page requested (gen $asked)")
    channel.invokeMethod(
      "window",
      mapOf("session" to session, "start" to page * pageSize, "count" to pageSize),
      object : MethodChannel.Result {
        override fun success(result: Any?) {
          inFlight.remove(page)
          val reply = result as? Map<*, *> ?: return
          val raw = reply["assets"] as? List<*> ?: return
          val served = (reply["generation"] as? Number)?.toInt() ?: -1
          if (served != asked || served != generation) {
            shellLog("[shell:timeline] session=$session page=$page from gen $served, now $generation: dropped")
            return
          }
          pages[page] = raw.mapNotNull { (it as? Map<*, *>)?.let(TimelineAsset::from) }
          stale.remove(page)
          shellLog("[shell:timeline] session=$session page=$page assets=${raw.size} in ${SystemClock.uptimeMillis() - started}ms")
        }

        override fun error(code: String, message: String?, details: Any?) {
          inFlight.remove(page)
          shellLog("[shell:timeline] session=$session page=$page failed: $code $message")
        }

        override fun notImplemented() {
          inFlight.remove(page)
        }
      },
    )
  }
}
