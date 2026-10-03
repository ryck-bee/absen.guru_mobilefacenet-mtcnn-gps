package id.ac.umj.rikoputra.absensiwajah

import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin monotonic clock.
 * Hanya untuk verifikasi anti-fake-clock (elapsedRealtime & boot time).
 */
class MonotonicClockPlugin(
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "id.ac.umj.rikoputra.absensiwajah/monotonic_clock"
    }

    private val channel = MethodChannel(messenger, CHANNEL).apply {
        setMethodCallHandler(this@MonotonicClockPlugin)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getElapsedRealtime" -> result.success(SystemClock.elapsedRealtime())
            "getBootTimeMillis" -> {
                val boot = System.currentTimeMillis() - SystemClock.elapsedRealtime()
                result.success(boot)
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}