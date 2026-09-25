package com.example.absensi_wajah

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Plugin alarm koneksi: memberi tahu Dart saat network baru tersedia.
 * Tidak cek internet; cek hanya bahwa WiFi/data aktif.
 */
class NetworkMonitorPlugin(
    private val context: Context,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.example.absensi_wajah/network_monitor"
    }

    private val channel = MethodChannel(messenger, CHANNEL).apply {
        setMethodCallHandler(this@NetworkMonitorPlugin)
    }

    private val connectivityManager: ConnectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val mainHandler = Handler(Looper.getMainLooper())

    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                startMonitoring()
                result.success(true)
            }
            "stop" -> {
                stopMonitoring()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun startMonitoring() {
        if (networkCallback != null) return

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // onAvailable jalan di ConnectivityThread, bukan main thread.
                // MethodChannel wajib main thread. Pindah dulu.
                mainHandler.post {
                    try {
                        channel.invokeMethod("onNetworkAvailable", null)
                    } catch (_: Exception) {
                    }
                }
            }
        }

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        try {
            connectivityManager.registerNetworkCallback(request, callback)
            networkCallback = callback
        } catch (_: Exception) {
        }
    }

    private fun stopMonitoring() {
        networkCallback?.let {
            try {
                connectivityManager.unregisterNetworkCallback(it)
            } catch (_: Exception) {}
        }
        networkCallback = null
    }

    fun dispose() {
        stopMonitoring()
        channel.setMethodCallHandler(null)
    }
}