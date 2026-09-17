package app.alextran.immich

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.ui.platform.ComposeView
import androidx.fragment.app.FragmentActivity
import app.alextran.immich.shell.ShellEngine
import app.alextran.immich.shell.ShellRoot
import android.os.ext.SdkExtensions
import app.alextran.immich.background.BackgroundEngineLock
import app.alextran.immich.background.BackgroundWorkerApiImpl
import app.alextran.immich.background.BackgroundWorkerFgHostApi
import app.alextran.immich.background.BackgroundWorkerLockApi
import app.alextran.immich.connectivity.ConnectivityApi
import app.alextran.immich.connectivity.ConnectivityApiImpl
import app.alextran.immich.core.HttpClientManager
import app.alextran.immich.core.ImmichPlugin
import app.alextran.immich.core.NetworkApiPlugin
import me.albemala.native_video_player.NativeVideoPlayerPlugin
import app.alextran.immich.images.LocalImageApi
import app.alextran.immich.images.LocalImagesImpl
import app.alextran.immich.images.RemoteImageApi
import app.alextran.immich.images.RemoteImagesImpl
import app.alextran.immich.permission.PermissionApi
import app.alextran.immich.permission.PermissionApiImpl
import app.alextran.immich.sync.NativeSyncApi
import app.alextran.immich.sync.NativeSyncApiImpl26
import app.alextran.immich.sync.NativeSyncApiImpl30
import app.alextran.immich.viewintent.ViewIntentPlugin
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.engine.FlutterEngine

/**
 * Hosts the native shell. The Flutter surface is a [FlutterFragment] that [ShellEngine] moves
 * between Compose-owned containers, so this is a plain [FragmentActivity] and everything
 * `FlutterFragmentActivity` used to forward to its fragment is forwarded here by hand.
 */
class MainActivity : FragmentActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    // `FlutterActivity` makes this switch itself once Flutter draws; nothing does it for us.
    setTheme(R.style.NormalTheme)
    super.onCreate(savedInstanceState)
    enableEdgeToEdge()
    window.isStatusBarContrastEnforced = false
    window.isNavigationBarContrastEnforced = false
    // A restored fragment would look for a container id Compose has since regenerated.
    val stale = supportFragmentManager.fragments.filterIsInstance<FlutterFragment>()
    if (stale.isNotEmpty()) {
      supportFragmentManager.beginTransaction().apply { stale.forEach(::remove) }.commitNow()
    }
    ShellEngine.start(this)
    ShellEngine.bind(this)
    setContentView(
      ComposeView(this).apply {
        // Left unconsumed so the Flutter view still sees the IME and system bars itself.
        consumeWindowInsets = false
        setContent { ShellRoot() }
      }
    )
  }

  // App lifecycle follows the activity, not the fragment: see [ShellFlutterFragment].
  override fun onResume() {
    super.onResume()
    ShellEngine.engine.lifecycleChannel.appIsResumed()
  }

  override fun onPause() {
    super.onPause()
    ShellEngine.engine.lifecycleChannel.appIsInactive()
  }

  override fun onStop() {
    super.onStop()
    ShellEngine.engine.lifecycleChannel.appIsPaused()
  }

  override fun onDestroy() {
    ShellEngine.engine.lifecycleChannel.appIsDetached()
    ShellEngine.unbind(this)
    super.onDestroy()
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    ShellEngine.fragment?.onNewIntent(intent)
  }

  override fun onUserLeaveHint() {
    super.onUserLeaveHint()
    ShellEngine.fragment?.onUserLeaveHint()
  }

  override fun onTrimMemory(level: Int) {
    super.onTrimMemory(level)
    ShellEngine.fragment?.onTrimMemory(level)
  }

  @Deprecated("Deprecated in Java")
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    ShellEngine.fragment?.onActivityResult(requestCode, resultCode, data)
  }

  @Deprecated("Deprecated in Java")
  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    ShellEngine.fragment?.onRequestPermissionsResult(requestCode, permissions, grantResults)
  }

  companion object {
    fun registerPlugins(ctx: Context, flutterEngine: FlutterEngine) {
      HttpClientManager.initialize(ctx)
      NativeVideoPlayerPlugin.dataSourceFactory = HttpClientManager::createDataSourceFactory
      flutterEngine.plugins.add(NetworkApiPlugin())

      val messenger = flutterEngine.dartExecutor.binaryMessenger
      val backgroundEngineLockImpl = BackgroundEngineLock(ctx)
      BackgroundWorkerLockApi.setUp(messenger, backgroundEngineLockImpl)
      val nativeSyncApiImpl =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) < 1) {
          NativeSyncApiImpl26(ctx)
        } else {
          NativeSyncApiImpl30(ctx)
        }
      val permissionApiImpl = PermissionApiImpl(ctx)
      NativeSyncApi.setUp(messenger, nativeSyncApiImpl)
      PermissionApi.setUp(messenger, permissionApiImpl)
      LocalImageApi.setUp(messenger, LocalImagesImpl(ctx))
      RemoteImageApi.setUp(messenger, RemoteImagesImpl(ctx))

      BackgroundWorkerFgHostApi.setUp(messenger, BackgroundWorkerApiImpl(ctx))
      ConnectivityApi.setUp(messenger, ConnectivityApiImpl(ctx))

      flutterEngine.plugins.add(ViewIntentPlugin())
      flutterEngine.plugins.add(backgroundEngineLockImpl)
      flutterEngine.plugins.add(nativeSyncApiImpl)
      flutterEngine.plugins.add(permissionApiImpl)
    }

    fun cancelPlugins(flutterEngine: FlutterEngine) {
      val nativeApi =
        flutterEngine.plugins.get(NativeSyncApiImpl26::class.java) as ImmichPlugin?
          ?: flutterEngine.plugins.get(NativeSyncApiImpl30::class.java) as ImmichPlugin?
      nativeApi?.detachFromEngine()
      val permissionApi = flutterEngine.plugins.get(PermissionApiImpl::class.java) as ImmichPlugin?
      permissionApi?.detachFromEngine()
    }
  }
}
