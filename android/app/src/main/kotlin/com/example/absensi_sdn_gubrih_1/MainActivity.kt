package id.ac.umj.rikoputra.absensiwajah

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var monotonicClockPlugin: MonotonicClockPlugin? = null
    private var gpsServicePlugin: GpsServicePlugin? = null
    private var mockLocationPlugin: MockLocationPlugin? = null
    private var networkMonitorPlugin: NetworkMonitorPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        monotonicClockPlugin = MonotonicClockPlugin(messenger)
        gpsServicePlugin = GpsServicePlugin(this, messenger)
        mockLocationPlugin = MockLocationPlugin(applicationContext, messenger)
        networkMonitorPlugin = NetworkMonitorPlugin(applicationContext, messenger)
    }

    override fun onDestroy() {
        monotonicClockPlugin?.dispose()
        monotonicClockPlugin = null
        gpsServicePlugin?.dispose()
        gpsServicePlugin = null
        mockLocationPlugin?.dispose()
        mockLocationPlugin = null
        networkMonitorPlugin?.dispose()
        networkMonitorPlugin = null
        super.onDestroy()
    }
}