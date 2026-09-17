package app.alextran.immich.shell

import androidx.activity.BackEventCompat
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.MutatorMutex
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** A mirrored Dart route: what `sync` said about it, and the host its Flutter surface visits. */
class StackFrame(val name: String) {
  var title by mutableStateOf<String?>(null)
    private set
  var actions by mutableStateOf<List<Map<String, Any?>>>(emptyList())
    private set
  var hero by mutableStateOf(false)
    private set
  var collapsed by mutableStateOf(false)

  /** 0 over the cover, 1 fully solid; the continuous form of [collapsed]. */
  var heroProgress by mutableStateOf(0f)

  val host = FlutterHost(shellRoute = "", shellLabel = name, surfaceToken = name)

  /** Dart draws its own bar when it could not translate one; the frame then shows none. */
  val showsNativeBar get() = title != null

  fun apply(frame: ShellBridge.MirrorFrame) {
    if (frame.hero != hero) {
      hero = frame.hero
      collapsed = false
      heroProgress = 0f
    }
    title = frame.title
    if (frame.actions != actions) {
      shellLog("[shell:nav] $name bar -> [${frame.actions.joinToString(",") { describe(it) }}]")
      actions = frame.actions
    }
    // A cover photo already draws to the top edge; the bar must not inset it.
    host.hasNativeTopBar = showsNativeBar && !hero
  }

  private fun describe(raw: Map<String, Any?>): String {
    val head = raw["icon"] as? String ?: raw["label"] as? String ?: "?"
    val rows = raw["menu"] as? List<*> ?: return head
    return "$head{${rows.joinToString("/") { (it as? Map<*, *>)?.get("label") as? String ?: "?" }}}"
  }
}

/** One tab's navigation stack: the root the tab draws itself, and the frames Dart pushed over it. */
class TabStack(val tab: ShellTab) {
  // The search tab's field is native, so its root always has chrome on top.
  val root = FlutterHost(shellRoute = tab.id, shellLabel = tab.label).apply { hasNativeTopBar = tab.isSearch }

  /** A tab root can publish a bar too, without being a stack frame. */
  var rootBar by mutableStateOf<ShellBridge.MirrorFrame?>(null)

  val frames = mutableStateListOf<StackFrame>()

  // MARK: motion — 0 is settled, 1 is the top frame fully off screen.

  /** Plain state, not an `Animatable`: `apply` must be able to snap it without suspending. */
  var progress by mutableFloatStateOf(0f)
    private set
  private val motion = MutatorMutex()
  var swipeEdge by mutableStateOf(BackEventCompat.EDGE_LEFT)

  /** Cancels whatever was animating, so a back press mid-enter continues from where it is. */
  suspend fun animateProgress(target: Float, durationMs: Int, easing: Easing = FastOutSlowInEasing) = motion.mutate {
    animate(progress, target, animationSpec = tween(durationMs, easing = easing)) { value, _ -> progress = value }
  }

  fun snapProgress(value: Float) {
    progress = value
  }

  /** A frame Dart has already dropped that is still animating out. */
  var exiting by mutableStateOf<StackFrame?>(null)

  /** A frame Dart just pushed whose enter animation has not started; drawn off screen until it does. */
  var entering by mutableStateOf<StackFrame?>(null)

  /** The frame a committed back gesture asked Dart to pop; its removal needs no second animation. */
  var pendingPop: String? = null

  /** The first tab's root is the native grid, as it is on iOS; every other root is Flutter's. */
  val isTimeline get() = ShellBridge.tabs.firstOrNull()?.id == tab.id
  val grid = TimelineGridState()

  /** The native viewer over this stack, if one is up. Its own layer: Dart's stack has nothing to mirror. */
  var viewer by mutableStateOf<ViewerState?>(null)
    private set

  fun openViewer(session: Int, index: Int) {
    val source = TimelineSessions.source(session) ?: return
    // Only a viewer opened over the visible grid can fly out of a tile.
    val fromGrid = isTimeline && frames.isEmpty() && session == TimelineSessions.MAIN
    shellLog("[shell:nav] native viewer at $index on session $session over ${tab.id}${if (fromGrid) " (from grid)" else ""}")
    viewer = ViewerState(session, source, index, grid.takeIf { fromGrid })
  }

  fun viewerClosed(closed: ViewerState) {
    if (viewer === closed) viewer = null
    TimelineSessions.close(closed.session)
  }

  /**
   * Decided here, in the same snapshot as the frame list, so the first composition already draws
   * a push off screen and a pop still in place. Decided after composition, as a diff of the last
   * frame, each showed one frame of the settled state before the animation began.
   */
  fun apply(frames: List<ShellBridge.MirrorFrame>) {
    val existing = this.frames
    var shared = 0
    while (shared < existing.size && shared < frames.size && existing[shared].name == frames[shared].name) {
      existing[shared].apply(frames[shared])
      shared += 1
    }
    if (shared == existing.size && shared == frames.size) return

    val target = existing.take(shared) + frames.drop(shared).map { StackFrame(it.name).apply { apply(it) } }
    shellLog("[shell:nav] sync ${tab.id} [${existing.joinToString(",") { it.name }}] -> [${target.joinToString(",") { it.name }}]")
    val gone = existing.lastOrNull()
    when {
      shared == existing.size && target.size == existing.size + 1 -> {
        exiting = null
        entering = target.last()
      }
      shared == target.size && gone != null -> {
        entering = null
        if (pendingPop == gone.name) {
          // The gesture already carried it off; Dart merely confirmed.
          pendingPop = null
          progress = 0f
        } else {
          exiting = gone
        }
      }
      else -> {
        entering = null
        exiting = null
      }
    }
    existing.clear()
    existing.addAll(target)
  }

  fun frame(named: String) = frames.firstOrNull { it.name == named }

  // Gesture scrub occupies the first part of the range; a commit finishes the rest.
  suspend fun scrub(event: BackEventCompat) {
    swipeEdge = event.swipeEdge
    motion.mutate { progress = event.progress * GESTURE_RANGE }
  }

  suspend fun commitBack() {
    val top = frames.lastOrNull() ?: return
    pendingPop = top.name
    animateProgress(1f, EXIT_MS)
    shellLog("[shell:nav] native pop of ${top.name} -> dart (back committed)")
    ShellBridge.requestDartPop(top.name)
  }

  suspend fun cancelBack() {
    animateProgress(0f, CANCEL_MS)
  }

  companion object {
    const val GESTURE_RANGE = 0.35f
    const val EXIT_MS = 200
    const val ENTER_MS = 300
    const val CANCEL_MS = 150
  }
}

/** All tabs' stacks, reconciled from `sync`. Tabs are created lazily by id. */
object NavStacks {
  private val stacks = mutableStateMapOf<String, TabStack>()

  fun reset(tabs: List<ShellTab>) {
    stacks.clear()
    tabs.forEach { stacks[it.id] = TabStack(it) }
  }

  operator fun get(tab: String): TabStack? = stacks[tab]

  val active: TabStack? get() = stacks[ShellBridge.selectedTab]

  fun onSync(frames: List<ShellBridge.MirrorFrame>, tabBars: Map<String, ShellBridge.MirrorFrame>, tab: String) {
    val stack = stacks[tab]
    if (stack == null) {
      shellLog("[shell:nav] sync [${frames.joinToString(",") { it.name }}] with no native stack to put it in")
      return
    }
    for ((id, bar) in tabBars) {
      stacks[id]?.let {
        it.rootBar = bar
        it.root.hasNativeTopBar = bar.title != null && !bar.hero
      }
    }
    stack.apply(frames)
  }

  /** Dart declined its viewer route and asks for ours, over whichever tab is up. */
  fun openViewer(session: Int, index: Int) {
    val stack = active ?: run {
      shellLog("[shell:nav] viewer at $index with no native stack to put it in")
      return
    }
    stack.openViewer(session, index)
  }

  fun onBarCollapsed(route: String, collapsed: Boolean) {
    stacks.values.firstNotNullOfOrNull { it.frame(route) }?.let { if (it.hero) it.collapsed = collapsed }
  }

  fun onBarScroll(route: String, progress: Float) {
    stacks.values.firstNotNullOfOrNull { it.frame(route) }?.let { if (it.hero) it.heroProgress = progress }
  }
}
