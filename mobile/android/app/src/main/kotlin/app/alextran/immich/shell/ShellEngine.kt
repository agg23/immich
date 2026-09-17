package app.alextran.immich.shell

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.TextureView
import android.view.ViewGroup
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.view.children
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentContainerView
import app.alextran.immich.MainActivity
import app.alextran.immich.R
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * One engine for the process, and the one place that decides which [FlutterHost] its surface
 * is attached to. The surface follows Dart: a host never claims it on the way in.
 */
object ShellEngine {
  private const val ENGINE_ID = "immich-shell"
  private const val SETTLE_DEADLINE_MS = 700L

  lateinit var engine: FlutterEngine
    private set

  private var activity: FragmentActivity? = null
  private val main = Handler(Looper.getMainLooper())

  /** Observable: a host that does not hold the surface draws its still instead. */
  private var holder by mutableStateOf<FlutterHost?>(null)
  var fragment: FlutterFragment? = null
    private set
  private var surfaceContainer: FragmentContainerView? = null
  private var attachCount = 0

  private val visible = mutableListOf<FlutterHost>()
  private var dartSurface = ""
  private var settling = false

  var overlayPresent by mutableStateOf(false)
    private set

  /**
   * A tab the native bar selected and Dart has not yet reported showing. Dart announces the change
   * with `willChange` like any other, but the shell already froze the outgoing tab at the tap and
   * the surface has since moved on: a still taken now would be of whatever the texture holds — the
   * old tab, as often as not — and it would cover the new tab that was just revealed.
   */
  private var pendingTab: String? = null

  fun tabSelectedNatively(tab: String) {
    freeze()
    pendingTab = tab
  }

  fun start(context: Context) {
    if (::engine.isInitialized) return
    val app = context.applicationContext
    // Flutter 3.47 runs Dart's UI thread *on* the platform thread on Android, and refuses the
    // flag that would separate them. Every Dart frame therefore competes with Compose for the
    // main thread; the shell's job is to keep its own work off that thread's critical path and
    // to hide Dart's first frames behind stills. Debug builds exaggerate this badly (JIT).
    engine = FlutterEngine(app)
    engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    shellLog("[shell] engine started")
    ShellWatchdog.start()
    // A cached engine skips `configureFlutterEngine`, so both registrations are explicit.
    GeneratedPluginRegistrant.registerWith(engine)
    MainActivity.registerPlugins(app, engine)
    FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    ShellBridge.attach(engine)
    TimelineSessions.attach(engine)
    ShellBridge.onOpenViewer = NavStacks::openViewer
    ShellBridge.onTabsDeclared = NavStacks::reset
    ShellBridge.onSync = NavStacks::onSync
    ShellBridge.onBarCollapsed = NavStacks::onBarCollapsed
    ShellBridge.onBarScroll = NavStacks::onBarScroll
    ShellBridge.onWillChange = ::onWillChange
  }

  fun bind(activity: FragmentActivity) {
    this.activity = activity
  }

  fun unbind(activity: FragmentActivity) {
    if (this.activity === activity) {
      this.activity = null
      fragment = null
      surfaceContainer = null
      keptSurface?.release()
      keptSurface = null
      holder = null
      visible.clear()
    }
  }

  fun hostBecameVisible(host: FlutterHost) {
    if (visible.none { it === host }) visible.add(host)
    if (host.shellRoute.isNotEmpty()) {
      ShellBridge.show(host.shellRoute) { surface -> dartIsShowing(surface) }
    }
    updatePlacement()
  }

  /**
   * A tab whose root is native has no host to become visible, but Dart still follows the tab:
   * its stack is the one this tab's frames mirror, and the bar actions it publishes for the root
   * resolve against the page that is current there.
   */
  fun nativeRootBecameVisible(tab: String) {
    ShellBridge.show(tab) { surface -> dartIsShowing(surface) }
  }

  fun hostDisappeared(host: FlutterHost) {
    visible.removeAll { it === host }
    updatePlacement()
  }

  fun dartIsShowing(surface: String, overlay: Boolean = false) {
    dartSurface = surface
    if (surface == pendingTab) pendingTab = null
    if (overlayPresent != overlay) {
      overlayPresent = overlay
      shellLog("[shell] flutter overlay ${if (overlay) "opened" else "closed"}")
    }
    updatePlacement()
  }

  fun holds(host: FlutterHost) = holder === host

  private fun updatePlacement() {
    val desired = visible.lastOrNull { it.surfaceToken == dartSurface }
    if (desired != null) {
      // The third case is a container Compose recreated under the view that was in it.
      if (holder !== desired || fragment == null || surfaceContainer?.parent !== desired.container) attachSurface(desired)
      confirmFrame(desired)
      return
    }

    val holder = holder
    if (holder != null && visible.any { it === holder }) {
      shellLog("[shell] dart is showing ${dartSurface.ifEmpty { "(nothing)" }}; surface stays with ${holder.shellLabel} until dart moves")
      return
    }

    val front = visible.lastOrNull() ?: return
    shellLog("[shell] nothing live on screen; surface goes to ${front.shellLabel} ahead of dart")
    attachSurface(front)
    confirmFrame(front)
  }

  /**
   * One fragment for the life of the activity, in a container view that moves between hosts.
   * A fragment per host cost a remove and an add on every navigation — plugins detached and
   * re-attached, the accessibility bridge rebuilt — and froze the main thread for the length
   * of the transition it was meant to be part of. Moving the view costs the texture its surface
   * for a frame, which the leaving host's still covers.
   */
  private fun attachSurface(host: FlutterHost) {
    val activity = activity ?: return
    val target = host.container
    if (target == null || !target.isAttachedToWindow) {
      // Compose has created the container but not yet placed it; one frame is enough.
      main.post { if (visible.any { it === host }) updatePlacement() }
      return
    }
    attachCount += 1
    val attach = attachCount
    val startedAt = SystemClock.uptimeMillis()

    // Its still was taken at `willChange`, before Dart painted the route this move is for.
    holder?.takeIf { it !== host }?.installStill()

    // Before the move: sent after, the first frames are laid out for the old host.
    host.reportSettledInsets()

    val container = surfaceContainer ?: FragmentContainerView(activity).apply {
      id = R.id.shell_surface
      layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
      surfaceContainer = this
    }
    (container.parent as? ViewGroup)?.removeView(container)
    target.addView(container)
    restoreSurface()
    holder = host

    if (fragment == null) {
      val next = FlutterFragment.CachedEngineFragmentBuilder(ShellFlutterFragment::class.java, ENGINE_ID)
        .shouldAttachEngineToActivity(true)
        // Back is the shell's: see `PredictiveBackHandler` in `ShellScaffold`.
        .shouldAutomaticallyHandleOnBackPressed(false)
        // A `SurfaceView` neither transforms nor fades; every stack transition needs both.
        .renderMode(RenderMode.texture)
        .build<FlutterFragment>()
      activity.supportFragmentManager.beginTransaction().add(R.id.shell_surface, next).commitNowAllowingStateLoss()
      fragment = next
      textureView?.let(::keepSurfaceAcrossMoves)
      (next.view as? FlutterView)?.addOnFirstFrameRenderedListener(object : FlutterUiDisplayListener {
        override fun onFlutterUiDisplayed() {
          shellLog("[shell] flutter first frame=${SystemClock.uptimeMillis() - startedAt}ms")
          // After the callback: Flutter is iterating its listener set when it calls us.
          main.post { (next.view as? FlutterView)?.removeOnFirstFrameRenderedListener(this) }
        }
        override fun onFlutterUiNoLongerDisplayed() {}
      })
    }

    shellLog("[shell] attach#$attach host=${host.shellLabel} token=${host.surfaceToken} in ${SystemClock.uptimeMillis() - startedAt}ms")

    if (!ShellBridge.isReady) {
      host.clearStill()
      return
    }

    host.installStill()
    main.postDelayed({
      if (holder === host && host.isWaitingForDart) {
        shellLog("[shell] attach#$attach settle deadline expired")
        host.reveal()
      }
    }, SETTLE_DEADLINE_MS)
  }

  private val textureView: TextureView?
    get() = (fragment?.view as? FlutterView)?.children?.firstOrNull { it is TextureView } as? TextureView

  private var keptSurface: SurfaceTexture? = null

  /**
   * A `TextureView` releases its `SurfaceTexture` when it leaves the window, and Flutter's
   * listener then tears the surface down and rebuilds it on the next attach — a rebuild that
   * blocks the platform thread until the Dart UI thread is idle, which mid-navigation it is
   * not. Answering "keep it" instead, and handing the same texture back after the move, means
   * Flutter never sees the move at all: the surface only changes size.
   */
  private fun keepSurfaceAcrossMoves(texture: TextureView) {
    val flutter = texture.surfaceTextureListener ?: return
    texture.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
      override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) =
        flutter.onSurfaceTextureAvailable(surface, width, height)
      override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) =
        flutter.onSurfaceTextureSizeChanged(surface, width, height)
      override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = flutter.onSurfaceTextureUpdated(surface)
      override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        keptSurface = surface
        return false
      }
    }
  }

  private fun restoreSurface() {
    val kept = keptSurface ?: return
    val texture = textureView
    if (texture != null && texture.surfaceTexture == null && !kept.isReleased) {
      texture.setSurfaceTexture(kept)
    } else {
      shellLog("[shell] kept surface could not be restored; flutter will rebuild one")
      kept.release()
    }
    keptSurface = null
  }

  private fun confirmFrame(host: FlutterHost) {
    if (!host.isWaitingForDart || settling) return
    settling = true
    val startedAt = SystemClock.uptimeMillis()
    ShellBridge.show("") { surface ->
      settling = false
      dartSurface = surface
      val holder = holder
      if (holder == null || holder.surfaceToken != surface) {
        updatePlacement() // Dart moved on while we were asking.
        return@show
      }
      shellLog("[shell] ${holder.shellLabel} revealed in ${SystemClock.uptimeMillis() - startedAt}ms")
      holder.reveal()
    }
  }

  private fun onWillChange() = freeze()

  /**
   * Keeps what the surface shows *now* as its host's still and covers the host with it. Called
   * on Dart's `willChange`, before the frame that paints the new route, and on a native tab tap:
   * any later — from Dart post-frame, or from here on `sync` — the texture already holds the
   * new route, and the still would be a picture of the wrong page.
   */
  fun freeze() {
    val host = holder ?: return
    if (pendingTab != null) {
      shellLog("[shell] willChange during tab change to $pendingTab; ${host.shellLabel} keeps its picture")
      return
    }
    snapshot(host)?.let { host.still = it }
    host.installStill()
  }

  /** The texture's current pixels, into the host's reused buffer when it still fits. */
  private fun snapshot(host: FlutterHost): ImageBitmap? {
    val texture = textureView ?: return null
    if (!texture.isAvailable || texture.width == 0 || texture.height == 0) return null
    val startedAt = SystemClock.uptimeMillis()
    val buffer = host.stillBuffer?.takeIf { it.width == texture.width && it.height == texture.height }
      ?: Bitmap.createBitmap(texture.width, texture.height, Bitmap.Config.ARGB_8888).also { host.stillBuffer = it }
    val bitmap = texture.getBitmap(buffer) ?: return null
    shellLog("[shell] still of ${host.shellLabel} in ${SystemClock.uptimeMillis() - startedAt}ms")
    return bitmap.asImageBitmap()
  }
}
