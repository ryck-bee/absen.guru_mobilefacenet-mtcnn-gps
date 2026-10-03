package id.ac.umj.rikoputra.absensiwajah

import android.content.Context
import android.location.LocationManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin deteksi mock location (Fake GPS).
 *
 * Cek native Location.isMock di 3 provider (GPS, Network, Fused).
 * Lebih andal dari Position.isMocked milik Geolocator — bisa nangkep
 * mock yang aktif sebelum aplikasi dibuka.
 */
class MockLocationPlugin(
    private val context: Context,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "id.ac.umj.rikoputra.absensiwajah/mock_location"
    }

    private val channel = MethodChannel(messenger, CHANNEL).apply {
        setMethodCallHandler(this@MockLocationPlugin)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "check" -> result.success(isMockActive())
            else -> result.notImplemented()
        }
    }

    private fun isMockActive(): Boolean {
        return try {
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val providers = listOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER,
                "fused"
            )
            providers.any { provider ->
                try {
                    val loc = lm.getLastKnownLocation(provider) ?: return@any false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        loc.isMock
                    } else {
                        @Suppress("DEPRECATION")
                        loc.isFromMockProvider
                    }
                } catch (_: Exception) {
                    false
                }
            }
        } catch (_: Exception) {
            false
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}