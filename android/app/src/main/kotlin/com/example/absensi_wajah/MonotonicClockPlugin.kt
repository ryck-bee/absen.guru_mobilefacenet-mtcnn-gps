package com.example.absensi_wajah

import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin sederhana untuk akses SystemClock.elapsedRealtime() dari Dart.
 *
 * elapsedRealtime() = waktu sejak HP menyala (termasuk saat deep sleep),
 * tidak bisa diubah user, tidak reset meski user ubah jam sistem.
 * Ini yang jadi dasar deteksi time-tampering.
 */
class MonotonicClockPlugin(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.example.absensi_wajah/monotonic_clock"
    }

    private val channel = MethodChannel(messenger, CHANNEL).apply {
        setMethodCallHandler(this@MonotonicClockPlugin)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getElapsedRealtime" -> {
                // Uptime HP dalam milidetik sejak boot
                result.success(SystemClock.elapsedRealtime())
            }
            "getBootTimeMillis" -> {
                // Wall-clock time saat HP menyala (perkiraan)
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