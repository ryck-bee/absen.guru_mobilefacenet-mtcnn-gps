import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge ke plugin alarm koneksi Android.
/// Memberi tahu Dart saat network baru tersedia (WiFi/data nyala).
/// Tidak cek internet; itu tugas Dart (ping Supabase).
class NetworkMonitor {
  NetworkMonitor._();
  static const _channel = MethodChannel('id.ac.umj.rikoputra.absensiwajah/network_monitor');

  static Future<void> start() async {
    try {
      await _channel.invokeMethod('start');
      debugPrint("NETMON: monitoring started");
    } catch (e) {
      debugPrint("NETMON: start error → $e");
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
      debugPrint("NETMON: monitoring stopped");
    } catch (e) {
      debugPrint("NETMON: stop error → $e");
    }
  }

  static void registerHandler(void Function() onNetworkAvailable) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNetworkAvailable') {
        debugPrint("NETMON: network available event");
        onNetworkAvailable();
      }
    });
  }
}