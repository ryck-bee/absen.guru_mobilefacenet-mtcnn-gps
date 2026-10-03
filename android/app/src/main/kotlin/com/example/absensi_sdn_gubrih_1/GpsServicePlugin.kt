package id.ac.umj.rikoputra.absensiwajah

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin GPS foreground service + notification permission.
 */
class GpsServicePlugin(
    private val context: Context,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "id.ac.umj.rikoputra.absensiwajah/gps_service"
        const val NOTIF_PERM_CODE = 9001
    }

    private val channel = MethodChannel(messenger, CHANNEL).apply {
        setMethodCallHandler(this@GpsServicePlugin)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startGpsService" -> {
                val intent = Intent(context, GpsForegroundService::class.java).apply {
                    action = GpsForegroundService.ACTION_START
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                result.success(true)
            }

            "stopGpsService" -> {
                val intent = Intent(context, GpsForegroundService::class.java).apply {
                    action = GpsForegroundService.ACTION_STOP
                }
                context.startService(intent)
                result.success(true)
            }

            "requestNotificationPermission" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val granted = context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                            PackageManager.PERMISSION_GRANTED
                    if (!granted) {
                        val activity = context as? Activity
                        activity?.requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            NOTIF_PERM_CODE
                        )
                    }
                    result.success(granted)
                } else {
                    result.success(true)
                }
            }

            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}