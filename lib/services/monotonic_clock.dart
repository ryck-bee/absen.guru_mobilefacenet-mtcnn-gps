import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MonotonicClock {
  MonotonicClock._();
  static const _channel = MethodChannel('com.example.absensi_wajah/monotonic_clock');

  static Future<int?> elapsedRealtimeMs() async {
    try {
      final v = await _channel.invokeMethod<int>('getElapsedRealtime');
      return v;
    } catch (e) {
      debugPrint("MonotonicClock.elapsedRealtimeMs error: $e");
      return null;
    }
  }

  static Future<int?> bootTimeMs() async {
    try {
      final v = await _channel.invokeMethod<int>('getBootTimeMillis');
      return v;
    } catch (e) {
      debugPrint("MonotonicClock.bootTimeMs error: $e");
      return null;
    }
  }

  /// Nyalakan foreground service supaya GPS tetap hidup saat app di-background.
  static Future<bool> startGpsService() async {
    try {
      final v = await _channel.invokeMethod<bool>('startGpsService');
      return v ?? false;
    } catch (e) {
      debugPrint("MonotonicClock.startGpsService error: $e");
      return false;
    }
  }

  /// Matikan foreground service.
  static Future<bool> stopGpsService() async {
    try {
      final v = await _channel.invokeMethod<bool>('stopGpsService');
      return v ?? false;
    } catch (e) {
      debugPrint("MonotonicClock.stopGpsService error: $e");
      return false;
    }
  }

  /// Minta izin notifikasi (Android 13+).
  /// Return: true kalau sudah/belum perlu, false kalau ditolak.
  static Future<bool> requestNotificationPermission() async {
    try {
      final v = await _channel.invokeMethod<bool>('requestNotificationPermission');
      return v ?? false;
    } catch (e) {
      debugPrint("MonotonicClock.requestNotificationPermission error: $e");
      return false;
    }
  }
}