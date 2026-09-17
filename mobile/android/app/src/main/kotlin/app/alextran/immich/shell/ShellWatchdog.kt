package app.alextran.immich.shell

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import app.alextran.immich.BuildConfig

/**
 * Debug only: samples the main thread's stack whenever it fails to turn its loop for a while.
 * The shell animates on that thread, so anything Flutter's platform side blocks it with is
 * a frozen transition; this says what.
 */
object ShellWatchdog {
  private const val STALL_MS = 30L
  private val main = Handler(Looper.getMainLooper())
  @Volatile private var lastTick = 0L
  private var started = false

  fun start() {
    // Debug builds, or any build with `log.tag.immich.shell` set to DEBUG — profile runs need it too.
    if (started || !(BuildConfig.DEBUG || Log.isLoggable("immich.shell", Log.DEBUG))) return
    started = true
    val thread = Thread({
      var reported = 0L
      while (true) {
        val sent = SystemClock.uptimeMillis()
        main.post { lastTick = SystemClock.uptimeMillis() }
        Thread.sleep(STALL_MS)
        if (lastTick < sent && reported != sent) {
          reported = sent
          val stack = Looper.getMainLooper().thread.stackTrace
          val lines = stack.take(14).joinToString("\n    ") { "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}" }
          shellLog("[shell:perf] main thread stalled >${STALL_MS}ms at\n    $lines")
        }
        Thread.sleep(20)
      }
    }, "shell-watchdog")
    thread.isDaemon = true
    thread.start()
  }
}
