package app.alextran.immich.shell

import android.graphics.Bitmap
import android.widget.FrameLayout
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.viewinterop.AndroidView

/**
 * A place the Flutter surface can live. One per tab root and, later, one per mirrored stack
 * frame. The surface itself is [ShellEngine]'s and visits whichever host Dart says it is showing.
 */
class FlutterHost(
  /** Tab id for a tab root; empty for a stack frame, which never asks Dart to move. */
  val shellRoute: String,
  val shellLabel: String,
  /** What `sync.surface` / `show`'s reply must equal for this host to hold the surface. */
  val surfaceToken: String = shellRoute,
) {
  /** Where the shared surface container is parented while this host holds it. */
  var container: FrameLayout? = null

  /** A native bar sits above the Flutter view; its top inset is then zero. */
  var hasNativeTopBar by mutableStateOf(false)

  /**
   * Height in px of native chrome overlaying the bottom of the Flutter view — the navigation
   * bar on a tab root. Overlaid, not stacked: the bar animates out over a stable surface
   * instead of resizing it frame by frame.
   */
  var bottomChromePx by mutableIntStateOf(0)

  /** Last frame Flutter showed here, drawn over the container while the surface re-attaches. */
  var still by mutableStateOf<ImageBitmap?>(null)

  /** Reused between captures; a full-screen bitmap per navigation would churn the heap. */
  var stillBuffer: Bitmap? = null

  /** True from attach until Dart confirms it has rendered this host's surface. */
  var isWaitingForDart by mutableStateOf(false)
    private set

  var insets: ShellInsets? = null

  fun installStill() {
    if (still == null) shellLog("[shell] no still for $shellLabel yet")
    isWaitingForDart = true
  }

  fun clearStill() {
    isWaitingForDart = false
  }

  fun reveal() {
    isWaitingForDart = false
  }

  fun reportInsets() {
    if (ShellEngine.holds(this)) reportSettledInsets()
  }

  fun reportSettledInsets() {
    // Null until the window insets have arrived: a search root with a native bar above and the
    // navigation bar below legitimately has all-zero insets, so zero cannot mean "unmeasured".
    ShellBridge.report(insets ?: return)
  }
}

@Composable
fun FlutterSurface(host: FlutterHost, modifier: Modifier = Modifier) {
  val density = LocalDensity.current
  val direction = LocalLayoutDirection.current
  val statusBars = WindowInsets.statusBars
  val navigationBars = WindowInsets.navigationBars
  val cutout = WindowInsets.displayCutout
  val insets = ShellInsets(
    top = if (host.hasNativeTopBar) 0f else statusBars.getTop(density) / density.density,
    bottom = maxOf(host.bottomChromePx, navigationBars.getBottom(density)) / density.density,
    left = cutout.getLeft(density, direction) / density.density,
    right = cutout.getRight(density, direction) / density.density,
  )
  // Before the first insets pass everything reads zero, including the status bar.
  val measured = statusBars.getTop(density) > 0
  if (measured) host.insets = insets
  LaunchedEffect(insets, measured) { if (measured) host.reportInsets() }

  DisposableEffect(host) {
    ShellEngine.hostBecameVisible(host)
    onDispose { ShellEngine.hostDisappeared(host) }
  }

  Box(modifier.fillMaxSize()) {
    AndroidView(
      factory = { context -> FrameLayout(context).also { host.container = it } },
      modifier = Modifier.fillMaxSize(),
      onRelease = { if (host.container === it) host.container = null },
    )
    // Covered while the surface is elsewhere or not yet confirmed here: the still if there is
    // one, plain background if not. Flutter's first frames after a move are laid out for the
    // host it left and must not be seen. The cover snaps on and fades off.
    val covered = host.isWaitingForDart || !ShellEngine.holds(host)
    val fade = remember { Animatable(if (covered) 1f else 0f) }
    LaunchedEffect(covered) { if (covered) fade.snapTo(1f) else fade.animateTo(0f, tween(COVER_FADE_MS)) }
    // Read `covered` directly for the first frame: an animation, even a zero-length one, lags it.
    if (covered || fade.value > 0f) {
      val still = host.still
      val cover = Modifier.fillMaxSize().graphicsLayer { alpha = if (covered) 1f else fade.value }
      if (still != null) {
        Image(still, contentDescription = null, modifier = cover, contentScale = ContentScale.Crop)
      } else {
        Box(cover.background(MaterialTheme.colorScheme.background))
      }
    }
  }
}

private const val COVER_FADE_MS = 120
