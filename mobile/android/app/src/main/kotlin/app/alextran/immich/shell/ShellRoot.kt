package app.alextran.immich.shell

import android.app.Activity
import android.os.Build
import androidx.compose.animation.AnimatedContent
import androidx.compose.runtime.key
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.material3.ShortNavigationBar
import androidx.compose.material3.ShortNavigationBarItem
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntOffset
import kotlin.math.roundToInt
import androidx.compose.material3.ColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.navigationsuite.ExperimentalMaterial3AdaptiveNavigationSuiteApi
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteItem
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.material3.adaptive.navigationsuite.rememberNavigationSuiteScaffoldState
import androidx.compose.runtime.SideEffect
import kotlinx.coroutines.CancellationException
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.ui.platform.LocalContext

/**
 * Swaps between the launch surface and the shell as Dart's `auth` dictates. Unlike UIKit there
 * is no root-only container to respect, so this is a plain composable.
 */
@Composable
fun ShellRoot() {
  ShellTheme {
    val auth = ShellBridge.authState
    val tabs = ShellBridge.tabs
    when {
      auth == ShellBridge.AuthState.SIGNED_IN && tabs.isNotEmpty() -> ShellScaffold(tabs)
      else -> {
        if (auth == ShellBridge.AuthState.SIGNED_IN) {
          // `ready` carries the tabs and precedes `auth`, so this is a bug, not a race.
          shellLog("[shell] signed in before dart declared any tabs; staying on launch")
        }
        LaunchSurface()
      }
    }
  }
}

/** Flutter's palette when Dart has sent one; Material You until then. */
@Composable
private fun ShellTheme(content: @Composable () -> Unit) {
  val palette = ShellBridge.palette
  val dark = palette?.dark ?: isSystemInDarkTheme()
  val context = LocalContext.current
  val base = when {
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
      if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    dark -> darkColorScheme()
    else -> lightColorScheme()
  }
  val scheme = palette?.let { base.withPalette(it) } ?: base

  // Status bar icons follow the app's brightness, which need not be the system's.
  val view = LocalView.current
  SideEffect {
    (view.context as? Activity)?.window?.let { window ->
      WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !dark
    }
  }

  MaterialTheme(colorScheme = scheme) { Surface(color = MaterialTheme.colorScheme.background, content = content) }
}

private fun ColorScheme.withPalette(p: ShellPalette): ColorScheme {
  fun c(key: String, fallback: Color) = p[key]?.let { Color(it) } ?: fallback
  return copy(
    primary = c("primary", primary),
    onPrimary = c("onPrimary", onPrimary),
    primaryContainer = c("primaryContainer", primaryContainer),
    onPrimaryContainer = c("onPrimaryContainer", onPrimaryContainer),
    secondary = c("secondary", secondary),
    onSecondary = c("onSecondary", onSecondary),
    secondaryContainer = c("secondaryContainer", secondaryContainer),
    onSecondaryContainer = c("onSecondaryContainer", onSecondaryContainer),
    surface = c("surface", surface),
    onSurface = c("onSurface", onSurface),
    background = c("surface", background),
    onBackground = c("onSurface", onBackground),
    surfaceContainer = c("surfaceContainer", surfaceContainer),
    surfaceContainerHigh = c("surfaceContainerHigh", surfaceContainerHigh),
    surfaceContainerHighest = c("surfaceContainerHighest", surfaceContainerHighest),
    onSurfaceVariant = c("onSurfaceVariant", onSurfaceVariant),
    outline = c("outline", outline),
    outlineVariant = c("outlineVariant", outlineVariant),
    error = c("error", error),
    onError = c("onError", onError),
  )
}

@Composable
private fun LaunchSurface() {
  val host = remember { FlutterHost(shellRoute = "", shellLabel = "launch") }
  FlutterSurface(host)
}

@OptIn(ExperimentalMaterial3AdaptiveNavigationSuiteApi::class)
@Composable
private fun ShellScaffold(tabs: List<ShellTab>) {
  if (ShellBridge.selectedTab !in tabs.map { it.id }) ShellBridge.selectedTab = tabs.first().id
  val selected = ShellBridge.selectedTab
  val stack = NavStacks[selected] ?: return

  // Dart's stack predates this one, so its first `sync` was dropped.
  LaunchedEffect(Unit) {
    shellLog("[shell] root -> shell")
    ShellBridge.requestSync()
  }

  // Material: the navigation bar belongs to top-level destinations and leaves on a push — or
  // under a full-screen Flutter overlay such as the viewer, which is not a frame of ours.
  val overlay = ShellEngine.overlayPresent
  val covered = stack.frames.isNotEmpty() || overlay || stack.viewer != null
  val scope = rememberCoroutineScope()

  val suiteType = NavigationSuiteScaffoldDefaults.navigationSuiteType(currentWindowAdaptiveInfo())
  val barAtBottom = suiteType == NavigationSuiteType.NavigationBar ||
    suiteType == NavigationSuiteType.ShortNavigationBarCompact ||
    suiteType == NavigationSuiteType.ShortNavigationBarMedium

  fun select(tab: ShellTab) {
    if (tab.id == selected) {
      val viewer = stack.viewer
      when {
        viewer != null -> viewer.close()
        stack.isTimeline && stack.frames.isEmpty() -> scope.launch { stack.grid.scrollToTop?.invoke() }
        else -> ShellBridge.popToRoot(tab.id)
      }
    } else {
      shellLog("[shell] tab bar selected ${tab.id}")
      // The outgoing tab leaves the window with its composition; keep its picture while it is here.
      ShellEngine.tabSelectedNatively(tab.id)
      ShellBridge.selectedTab = tab.id
    }
  }

  // One handler decides: a pushed frame pops with a scrub, anything else is Flutter's to answer.
  // Always enabled — with nothing registered the dispatcher would finish the activity.
  PredictiveBackHandler(enabled = true) { events ->
    val active = NavStacks.active
    val viewer = active?.viewer
    if (viewer != null) {
      try {
        events.collect { viewer.scrub(it) }
        viewer.close()
      } catch (_: CancellationException) {
        viewer.cancelBack()
      }
      return@PredictiveBackHandler
    }
    if (overlay || active == null || active.frames.isEmpty()) {
      try {
        events.collect {}
        ShellEngine.fragment?.onBackPressed()
      } catch (_: CancellationException) {
      }
      return@PredictiveBackHandler
    }
    try {
      events.collect { active.scrub(it) }
      active.commitBackAndVerify()
    } catch (_: CancellationException) {
      shellLog("[shell:nav] back gesture on ${active.frames.last().name} cancelled, dart untouched")
      active.cancelBack()
    }
  }

  if (barAtBottom) {
    // Overlaid on a full-height surface, not stacked under it: hiding a stacked bar resizes the
    // Flutter view on every frame of the animation, and Flutter re-lays out each time. Overlaid,
    // the bar slides over a surface that never moves, and the root pads for it via its insets.
    var barHeight by remember { mutableIntStateOf(0) }
    val hidden by animateFloatAsState(
      targetValue = if (covered) 1f else 0f,
      animationSpec = tween(if (covered) BAR_HIDE_MS else BAR_SHOW_MS, easing = FastOutSlowInEasing),
      label = "navigationBar",
    )
    SideEffect { tabs.forEach { NavStacks[it.id]?.root?.bottomChromePx = barHeight } }
    Box(Modifier.fillMaxSize()) {
      // Material's fade-through between top-level destinations. The outgoing tab stays composed
      // for its fade and draws the still `select` froze, so the live surface can already be
      // painting the new tab underneath without anyone seeing it.
      AnimatedContent(
        targetState = selected,
        transitionSpec = {
          (fadeIn(tween(TAB_IN_MS, delayMillis = TAB_OUT_MS)) + scaleIn(tween(TAB_IN_MS, delayMillis = TAB_OUT_MS), initialScale = 0.92f))
            .togetherWith(fadeOut(tween(TAB_OUT_MS)))
            .using(SizeTransform(clip = false))
        },
        label = "tabs",
      ) { tabId ->
        NavStacks[tabId]?.let { TabStackView(it) }
      }
      ShortNavigationBar(
        modifier = Modifier
          .align(Alignment.BottomCenter)
          .onSizeChanged { barHeight = it.height }
          .offset { IntOffset(0, (barHeight * hidden).roundToInt()) },
      ) {
        tabs.forEach { tab ->
          val isSelected = tab.id == selected
          ShortNavigationBarItem(
            selected = isSelected,
            onClick = { select(tab) },
            icon = { tab.icon?.let { Icon(if (isSelected) it.filled else it.image, contentDescription = null) } },
            label = { Text(tab.label) },
          )
        }
      }
    }
    return
  }

  // A rail or drawer sits beside the surface; width changes there are rare and untested.
  SideEffect { tabs.forEach { NavStacks[it.id]?.root?.bottomChromePx = 0 } }
  val suiteState = rememberNavigationSuiteScaffoldState()
  LaunchedEffect(covered) { if (covered) suiteState.hide() else suiteState.show() }
  NavigationSuiteScaffold(
    navigationItems = {
      tabs.forEach { tab ->
        val isSelected = tab.id == selected
        NavigationSuiteItem(
          selected = isSelected,
          onClick = { select(tab) },
          icon = { tab.icon?.let { Icon(if (isSelected) it.filled else it.image, contentDescription = null) } },
          label = { Text(tab.label) },
        )
      }
    },
    navigationSuiteType = suiteType,
    state = suiteState,
  ) {
    key(selected) { TabStackView(stack) }
  }
}

private const val BAR_HIDE_MS = 200
private const val BAR_SHOW_MS = 300
private const val TAB_OUT_MS = 90
private const val TAB_IN_MS = 210
