package com.example.absensi_wajah

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var monotonicClockPlugin: MonotonicClockPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        monotonicClockPlugin = MonotonicClockPlugin(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onDestroy() {
        monotonicClockPlugin?.dispose()
        monotonicClockPlugin = null
        super.onDestroy()
    }
}