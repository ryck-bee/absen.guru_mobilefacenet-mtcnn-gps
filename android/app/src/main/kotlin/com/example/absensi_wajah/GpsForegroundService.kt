package com.example.absensi_wajah

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder

/**
 * Foreground service minimal untuk menjaga GPS tetap hidup
 * saat aplikasi di-background (minimize / tekan home).
 *
 * Tidak handle GPS sendiri. GPS tetap di Dart (geolocator).
 * Service ini hanya tampilkan notifikasi permanen + tipe "location"
 * supaya Android tidak matikan proses aplikasi.
 */
class GpsForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "absensi_gps_channel"
        const val NOTIF_ID = 1001
        const val ACTION_START = "START"
        const val ACTION_STOP = "STOP"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIF_ID, buildNotification())
        return START_STICKY
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Absensi GPS",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Notifikasi selama proses absensi berjalan"
            setShowBadge(false)
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Absensi wajah berjalan")
            .setContentText("Sedang memproses GPS. Jangan tutup aplikasi.")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .build()
    }
}