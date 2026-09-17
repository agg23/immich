package app.alextran.immich.shell

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** The native half of `immich/shell`. See `hybrid-shell-protocol.md`. */
object ShellBridge {
  enum class AuthState { UNKNOWN, SIGNED_OUT, SIGNED_IN }

  /** Compose state, so the root swaps itself when these change. */
  var authState by mutableStateOf(AuthState.UNKNOWN)
    private set

  /** Declared by Dart: order is identity across the channel, and labels are localised. */
  var tabs by mutableStateOf<List<ShellTab>>(emptyList())
    private set

  /** The tab the native bar shows. Written by a tap here or by a `claimTab` sync from Dart. */
  var selectedTab by mutableStateOf("")

  var searchPlaceholder by mutableStateOf<String?>(null)
    private set

  /** Dart may set the field's text (a suggestion picked, a cleared query); the field owns edits. */
  var searchText by mutableStateOf("")

  /** The palette Flutter is wearing, so the chrome above it matches; null until Dart says. */
  var palette by mutableStateOf<ShellPalette?>(null)
    private set

  data class MirrorFrame(
    val name: String,
    val title: String?,
    val actions: List<Map<String, Any?>>,
    val hero: Boolean,
  )

  /** Stack reconciliation lives with whoever owns the stacks; the bridge only parses. */
  var onSync: ((frames: List<MirrorFrame>, tabBars: Map<String, MirrorFrame>, tab: String) -> Unit)? = null
  var onBarCollapsed: ((route: String, collapsed: Boolean) -> Unit)? = null
  var onBarScroll: ((route: String, progress: Float) -> Unit)? = null
  /** Dart is about to paint a different route; whatever the surface shows now is about to go. */
  var onWillChange: (() -> Unit)? = null
  var onTabsDeclared: ((List<ShellTab>) -> Unit)? = null
  var onOpenViewer: ((session: Int, index: Int) -> Unit)? = null

  private var channel: MethodChannel? = null
  var isReady = false
    private set
  private var pendingRoute: String? = null
  private var pendingSettle: ((String) -> Unit)? = null

  fun attach(engine: FlutterEngine) {
    val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "immich/shell")
    channel.setMethodCallHandler { call, result -> result.success(handle(call)) }
    this.channel = channel
  }

  /** The tabs whose root this shell draws itself: the first one, the native grid. */
  val nativeRoots: List<String> get() = listOfNotNull(tabs.firstOrNull()?.id)

  /** Most calls have no reply; `ready` answers with what Dart must not draw. */
  @Suppress("UNCHECKED_CAST")
  private fun handle(call: MethodCall): Any? {
    val args = call.arguments as? Map<String, Any?> ?: emptyMap()
    when (call.method) {
      "ready" -> {
        isReady = true
        tabs = (args["tabs"] as? List<Map<*, *>> ?: emptyList()).mapNotNull(ShellTab::from)
        shellLog("[shell] dart ready, tabs=[${tabs.joinToString(",") { it.id }}] nativeRoots=[${nativeRoots.joinToString(",")}]")
        onTabsDeclared?.invoke(tabs)
        pendingRoute?.let { route ->
          pendingRoute = null
          val settle = pendingSettle ?: {}
          pendingSettle = null
          send(route, settle)
        }
        return mapOf("nativeRoots" to nativeRoots)
      }
      "auth" -> {
        val next = if (args["signedIn"] == true) AuthState.SIGNED_IN else AuthState.SIGNED_OUT
        if (next == authState) return null
        authState = next
        shellLog("[shell] auth signedIn=${next == AuthState.SIGNED_IN}")
      }
      "openViewer" -> onOpenViewer?.invoke(args["session"] as? Int ?: 0, args["index"] as? Int ?: 0)
      "log" -> shellLog("[shell:dart] ${args["text"] ?: "?"}")
      "search" -> {
        (args["placeholder"] as? String)?.let { searchPlaceholder = it }
        (args["text"] as? String)?.let { searchText = it }
      }
      "theme" -> {
        palette = ShellPalette.from(args)
        shellLog("[shell] theme dark=${palette?.dark}")
      }
      "barScroll" -> onBarScroll?.invoke(args["route"] as? String ?: "", (args["progress"] as? Number)?.toFloat() ?: 0f)
      "barCollapsed" -> onBarCollapsed?.invoke(args["route"] as? String ?: "", args["collapsed"] == true)
      "willChange" -> onWillChange?.invoke()
      "sync" -> {
        val frames = (args["routes"] as? List<Map<String, Any?>> ?: emptyList()).map(::frame)
        val tabBars = (args["tabBars"] as? Map<String, Map<String, Any?>> ?: emptyMap()).mapValues { frame(it.value) }
        val tab = args["tab"] as? String ?: ""
        if (args["claimTab"] == true && tab.isNotEmpty() && tab != selectedTab) {
          shellLog("[shell:nav] dart moved to $tab")
          selectedTab = tab
        }
        onSync?.invoke(frames, tabBars, tab)
        ShellEngine.dartIsShowing(args["surface"] as? String ?: "", overlay = args["overlay"] == true)
      }
      else -> shellLog("[shell] unhandled dart call ${call.method}")
    }
    return null
  }

  @Suppress("UNCHECKED_CAST")
  private fun frame(raw: Map<String, Any?>) = MirrorFrame(
    name = raw["name"] as? String ?: "?",
    title = raw["title"] as? String,
    actions = raw["actions"] as? List<Map<String, Any?>> ?: emptyList(),
    hero = raw["hero"] == true,
  )

  // MARK: native → Dart

  fun requestSync() {
    channel?.invokeMethod("resync", null)
  }

  fun requestDartPop(route: String) {
    channel?.invokeMethod("popFromNative", mapOf("name" to route))
  }

  fun barAction(route: String, index: Int, item: Int) {
    channel?.invokeMethod("barAction", mapOf("route" to route, "index" to index, "item" to item))
  }

  fun submitSearch(text: String) {
    shellLog("[shell] search submit ${text.ifEmpty { "(cleared)" }}")
    channel?.invokeMethod("searchSubmitted", mapOf("text" to text))
  }

  fun popToRoot(tab: String) {
    channel?.invokeMethod("popToRoot", mapOf("tab" to tab))
  }

  private var reportedInsets: ShellInsets? = null

  fun report(insets: ShellInsets) {
    if (insets == reportedInsets) return
    reportedInsets = insets
    channel?.invokeMethod(
      "insets",
      mapOf(
        "top" to insets.top.toDouble(),
        "bottom" to insets.bottom.toDouble(),
        "left" to insets.left.toDouble(),
        "right" to insets.right.toDouble(),
      ),
    )
    shellLog("[shell] insets top=${insets.top} bottom=${insets.bottom}")
  }

  fun show(route: String, whenSettled: (String) -> Unit) {
    if (!isReady) {
      pendingRoute = route
      pendingSettle = whenSettled
      return
    }
    send(route, whenSettled)
  }

  private fun send(route: String, whenSettled: (String) -> Unit) {
    shellLog("[shell] show route=$route")
    val channel = channel ?: return whenSettled("")
    channel.invokeMethod("show", mapOf("route" to route), object : MethodChannel.Result {
      override fun success(result: Any?) = whenSettled((result as? Map<*, *>)?.get("surface") as? String ?: "")
      override fun error(code: String, message: String?, details: Any?) = whenSettled("")
      override fun notImplemented() = whenSettled("")
    })
  }
}

/** Flutter's resolved `ColorScheme`, as ARGB ints; missing keys fall back to the Material default. */
class ShellPalette(val dark: Boolean, private val colors: Map<String, Int>) {
  operator fun get(key: String): Int? = colors[key]

  companion object {
    fun from(args: Map<String, Any?>) = ShellPalette(
      dark = args["dark"] == true,
      colors = args.filterKeys { it != "dark" }.mapNotNull { (k, v) -> (v as? Number)?.let { k to it.toInt() } }.toMap(),
    )
  }
}

/** Logical pixels, as Flutter's `MediaQuery` wants them. */
data class ShellInsets(val top: Float, val bottom: Float, val left: Float, val right: Float) {
  val isZero get() = top == 0f && bottom == 0f && left == 0f && right == 0f
}
