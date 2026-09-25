package com.example.absensi_wajah

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var monotonicClockPlugin: MonotonicClockPlugin? = null
    private var networkMonitorPlugin: NetworkMonitorPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        monotonicClockPlugin = MonotonicClockPlugin(
            this,
            flutterEngine.dartExecutor.binaryMessenger
        )
        networkMonitorPlugin = NetworkMonitorPlugin(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger
        )
    }

    override fun onDestroy() {
        monotonicClockPlugin?.dispose()
        monotonicClockPlugin = null
        networkMonitorPlugin?.dispose()
        networkMonitorPlugin = null
        super.onDestroy()
    }
}