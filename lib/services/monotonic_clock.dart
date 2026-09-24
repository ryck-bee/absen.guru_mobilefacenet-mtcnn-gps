import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Akses Monotonic Clock Android via native plugin.
///
/// `elapsedRealtime` = uptime HP sejak boot (ms), tidak bisa diubah user,
/// tidak reset walau user ubah jam sistem.
///
/// Dipakai untuk deteksi time-tampering: bandingkan wall-clock dengan
/// estimasi waktu dari anchor (server_time + delta uptime).
class MonotonicClock {
  MonotonicClock._();
  static const _channel = MethodChannel('com.example.absensi_wajah/monotonic_clock');

  /// Uptime HP dalam milidetik sejak boot.
  /// Return null kalau plugin tidak tersedia (misal di iOS atau test).
  static Future<int?> elapsedRealtimeMs() async {
    try {
      final v = await _channel.invokeMethod<int>('getElapsedRealtime');
      return v;
    } catch (e) {
      debugPrint("MonotonicClock.elapsedRealtimeMs error: $e");
      return null;
    }
  }

  /// Wall-clock time saat HP menyala (perkiraan).
  /// Return null kalau plugin tidak tersedia.
  static Future<int?> bootTimeMs() async {
    try {
      final v = await _channel.invokeMethod<int>('getBootTimeMillis');
      return v;
    } catch (e) {
      debugPrint("MonotonicClock.bootTimeMs error: $e");
      return null;
    }
  }
}