package app.alextran.immich.shell

import io.flutter.embedding.android.FlutterFragment

/**
 * A stock fragment reports `paused` on stop and `detached` on detach, which Dart takes at face
 * value — `handleAppDetached`, the locked folder navigating home. Moving the surface between hosts
 * is neither, so the activity dispatches app lifecycle for the engine instead.
 */
class ShellFlutterFragment : FlutterFragment() {
  override fun shouldDispatchAppLifecycleState() = false
}
