package app.alextran.immich.shell

import androidx.activity.BackEventCompat
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.movableContentOf
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * One tab's stack on screen: the current top over the layer beneath it, with the top layer
 * moving for a push, a pop, or a back gesture in flight. Deeper layers stay composed but
 * invisible; the layer beneath draws its still, or lives if Dart has already moved the surface.
 */
@Composable
fun TabStackView(stack: TabStack, modifier: Modifier = Modifier) {
  val frames = stack.frames
  val top = frames.lastOrNull()
  val exiting = stack.exiting
  val entering = stack.entering

  // `apply` decided the motion in the same snapshot as the frame list; these only run it.
  // Keyed on the frame, not on `entering`: clearing that below would cancel this very effect.
  LaunchedEffect(stack, top) {
    if (stack.entering !== top || top == null) return@LaunchedEffect
    // One write batch: the layer must never see the frame settled with nothing pending.
    stack.snapProgress(1f)
    stack.entering = null
    stack.animateProgress(0f, TabStack.ENTER_MS)
  }
  LaunchedEffect(stack, exiting) {
    if (exiting == null) return@LaunchedEffect
    stack.animateProgress(1f, TabStack.EXIT_MS)
    stack.exiting = null
    stack.snapProgress(0f)
  }

  val moving: StackFrame? = exiting ?: top
  val beneath: StackFrame? = when {
    exiting != null -> top
    frames.size >= 2 -> frames[frames.size - 2]
    else -> null
  }
  fun roleOf(frame: StackFrame?): LayerRole = when {
    moving == null -> if (frame == null) LayerRole.RESTING else LayerRole.HIDDEN
    frame === moving -> LayerRole.MOVING
    frame === beneath -> LayerRole.RESTING
    else -> LayerRole.HIDDEN
  }

  // Every layer keeps one slot for as long as it exists. Moving one between slots re-attaches
  // its Android view, and a `TextureView` loses its surface on the way.
  Box(modifier.fillMaxSize()) {
    StackLayer(stack, moving, roleOf(null)) { RootLayer(stack) }
    for (frame in frames) key(frame) { StackLayer(stack, moving, roleOf(frame)) { FrameLayer(stack, frame) } }
    if (exiting != null) key(exiting) { StackLayer(stack, moving, roleOf(exiting)) { FrameLayer(stack, exiting) } }
    // Above everything: it draws its own backdrop and runs its own zoom, so it is not a stack layer.
    stack.viewer?.let { viewer -> key(viewer) { AssetViewerLayer(viewer) { stack.viewerClosed(viewer) } } }
  }
}

private enum class LayerRole { HIDDEN, RESTING, MOVING }

@Composable
private fun StackLayer(stack: TabStack, moving: StackFrame?, role: LayerRole, content: @Composable () -> Unit) {
  val direction = if (stack.swipeEdge == BackEventCompat.EDGE_RIGHT) -1f else 1f
  Box(
    Modifier
      .fillMaxSize()
      .graphicsLayer {
        when (role) {
          LayerRole.HIDDEN -> alpha = 0f
          LayerRole.RESTING -> {}
          LayerRole.MOVING -> {
            // Off screen from its very first draw, before the enter effect has run.
            val p = if (stack.entering === moving) 1f else stack.progress
            val gesture = (p / TabStack.GESTURE_RANGE).coerceIn(0f, 1f)
            val exit = ((p - TabStack.GESTURE_RANGE) / (1f - TabStack.GESTURE_RANGE)).coerceIn(0f, 1f)
            scaleX = 1f - 0.1f * gesture
            scaleY = scaleX
            translationX = direction * size.width * (0.08f * gesture + 0.25f * exit)
            alpha = 1f - exit
            shape = RoundedCornerShape(28.dp * gesture)
            clip = gesture > 0f
          }
        }
      }
  ) {
    content()
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RootLayer(stack: TabStack) {
  if (stack.isTimeline) {
    val source = TimelineSessions.source(TimelineSessions.MAIN)
    if (source != null) {
      NativeTimelineRoot(stack, source)
      return
    }
    shellLog("[shell:timeline] no main session yet; photos root draws flutter's")
  }
  val bar = stack.rootBar
  Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
    val title = bar?.title
    if (stack.tab.isSearch) {
      // The field is native; the bar Dart publishes for this root is only its actions.
      Row(
        Modifier
          .fillMaxWidth()
          .statusBarsPadding()
          .padding(start = 16.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
      ) {
        ShellSearchBar(Modifier.weight(1f))
        if (bar != null) BarActions(bar.name, bar.actions)
      }
    } else if (bar != null && title != null) {
      ShellTopBar(route = bar.name, title = title, actions = bar.actions)
    }
    FlutterSurface(stack.root)
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FrameLayer(stack: TabStack, frame: StackFrame) {
  val scope = rememberCoroutineScope()
  val onBack: () -> Unit = {
    scope.launch {
      if (stack.frames.lastOrNull() === frame) stack.commitBackAndVerify()
    }
  }
  val title = frame.title
  // Not hidden under a Flutter overlay: the viewer is a frame of its own here, and hiding this
  // bar would only resize the surface beneath it.
  val showBar = title != null
  val bar: @Composable () -> Unit = {
    if (showBar) {
      ShellTopBar(
        route = frame.name,
        title = title ?: "",
        actions = frame.actions,
        hero = frame.hero,
        collapsed = frame.collapsed,
        heroProgress = frame.heroProgress,
        onBack = onBack,
      )
    }
  }
  val background = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)
  // `hero` is in the first sync now, but a bar can still republish; the surface survives the swap.
  val surface = remember(frame) { movableContentOf { FlutterSurface(frame.host) } }
  if (frame.hero) {
    // Transparent over the cover photo, so the surface runs under the bar.
    Box(background) {
      surface()
      Box(Modifier.align(Alignment.TopCenter)) { bar() }
    }
  } else {
    Column(background) {
      bar()
      surface()
    }
  }
}

/** Committed, then confirmed by Dart; if Dart declines, the frame comes back. */
suspend fun TabStack.commitBackAndVerify() {
  commitBack()
  val name = pendingPop ?: return
  delay(500)
  if (pendingPop == name && frames.lastOrNull()?.name == name) {
    shellLog("[shell:nav] dart kept $name after a native pop; restoring")
    pendingPop = null
    animateProgress(0f, TabStack.CANCEL_MS)
  }
}
