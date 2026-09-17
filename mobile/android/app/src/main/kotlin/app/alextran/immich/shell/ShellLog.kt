package app.alextran.immich.shell

import android.util.Log
import app.alextran.immich.BuildConfig

private const val TAG = "immich.shell"

/// Debug builds always log; a profile build (where the shell runs at speed) opts in with
/// `adb shell setprop log.tag.immich.shell DEBUG`.
fun shellLog(message: String) {
  if (BuildConfig.DEBUG || Log.isLoggable(TAG, Log.DEBUG)) {
    Log.d(TAG, message)
  }
}
