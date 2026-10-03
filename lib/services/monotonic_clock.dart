import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge ke plugin monotonic clock.
/// Hanya untuk elapsedRealtime & boot time.
class MonotonicClock {
  MonotonicClock._();
  static const _channel =
      MethodChannel('id.ac.umj.rikoputra.absensiwajah/monotonic_clock');

  static Future<int?> elapsedRealtimeMs() async {
    try {
      return await _channel.invokeMethod<int>('getElapsedRealtime');
    } catch (e) {
      debugPrint("MonotonicClock.elapsedRealtimeMs error: $e");
      return null;
    }
  }

  static Future<int?> bootTimeMs() async {
    try {
      return await _channel.invokeMethod<int>('getBootTimeMillis');
    } catch (e) {
      debugPrint("MonotonicClock.bootTimeMs error: $e");
      return null;
    }
  }
}