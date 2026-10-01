import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge ke plugin GPS foreground service + notification permission.
class GpsServicePlugin {
  GpsServicePlugin._();
  static const _channel =
      MethodChannel('com.example.absensi_wajah/gps_service');

  static Future<bool> startGpsService() async {
    try {
      final v = await _channel.invokeMethod<bool>('startGpsService');
      return v ?? false;
    } catch (e) {
      debugPrint("GpsServicePlugin.startGpsService error: $e");
      return false;
    }
  }

  static Future<bool> stopGpsService() async {
    try {
      final v = await _channel.invokeMethod<bool>('stopGpsService');
      return v ?? false;
    } catch (e) {
      debugPrint("GpsServicePlugin.stopGpsService error: $e");
      return false;
    }
  }

  static Future<bool> requestNotificationPermission() async {
    try {
      final v = await _channel.invokeMethod<bool>('requestNotificationPermission');
      return v ?? false;
    } catch (e) {
      debugPrint("GpsServicePlugin.requestNotificationPermission error: $e");
      return false;
    }
  }
}