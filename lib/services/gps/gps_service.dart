import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../db/sync_service.dart';

/// Hasil pembacaan GPS dengan info lengkap
class GpsResult {
  final double lat;
  final double lng;
  final double accuracyMeters;
  final double? distanceToSchool;

  GpsResult({
    required this.lat,
    required this.lng,
    required this.accuracyMeters,
    this.distanceToSchool,
  });

  bool get isValid => accuracyMeters <= GpsService.maxAccuracyMeters;
}

class GpsService {
  static const double maxAccuracyMeters = 50.0;

  // Timeout dinamis: online (A-GPS bantu) vs offline (satelit murni)
  static const Duration timeoutOnline = Duration(seconds: 45);
  static const Duration timeoutOffline = Duration(seconds: 180);

  static const Duration pollInterval = Duration(seconds: 1);

  /// Cek apakah server reachable (real ping via Supabase).
  /// Return true kalau bisa akses server dalam 3 detik.
  Future<bool> isOnline() async {
    return await SyncService().isServerReachable();
  }

  /// Timeout default berdasarkan kondisi koneksi saat ini
  Future<Duration> getDynamicTimeout() async {
    final online = await isOnline();
    final t = online ? timeoutOnline : timeoutOffline;
    debugPrint("GPS: mode ${online ? "ONLINE" : "OFFLINE"} (server ping), timeout=${t.inSeconds}s");
    return t;
  }

  /// Cek GPS tersedia di device & sudah dinyalakan user
  Future<bool> isGpsReady() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint("GPS: service disabled");
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint("GPS: permission denied");
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint("GPS: permission denied forever");
      return false;
    }

    return true;
  }

  /// Ambil posisi GPS dengan filter accuracy.
  Future<GpsResult?> getPosition({
    Duration? timeout,
    void Function(double accuracy)? onProgress,
  }) async {
    final effectiveTimeout = timeout ?? await getDynamicTimeout();
    final ready = await isGpsReady();
    if (!ready) return null;

    final startTime = DateTime.now();
    GpsResult? lastValid;

    while (DateTime.now().difference(startTime) < effectiveTimeout) {
      final elapsed = DateTime.now().difference(startTime);
      final remaining = effectiveTimeout - elapsed;

      if (remaining.inSeconds < 5) {
        debugPrint("GPS: sisa waktu ${remaining.inSeconds}s, stop loop");
        break;
      }

      final attemptSeconds = remaining.inSeconds > 32 ? 30 : remaining.inSeconds - 2;

      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: LocationSettings(
            accuracy: LocationAccuracy.best,
            timeLimit: Duration(seconds: attemptSeconds),
          ),
        ).timeout(Duration(seconds: attemptSeconds + 2));

        final result = GpsResult(
          lat: pos.latitude,
          lng: pos.longitude,
          accuracyMeters: pos.accuracy,
        );

        final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
        debugPrint("GPS: [+${elapsedMs}ms] lat=${pos.latitude.toStringAsFixed(6)}, lng=${pos.longitude.toStringAsFixed(6)}, acc=${pos.accuracy.toStringAsFixed(1)}m");
        onProgress?.call(pos.accuracy);

        if (result.isValid) {
          return result;
        } else {
          lastValid = result;
        }
      } catch (e) {
        debugPrint("GPS: error/timeout -> $e");
      }

      await Future.delayed(pollInterval);
    }

    debugPrint("GPS: timeout ${effectiveTimeout.inSeconds}s. Terakhir acc=${lastValid?.accuracyMeters.toStringAsFixed(1) ?? '-'}m");
    return lastValid;
  }

  /// Hitung jarak Haversine antara 2 titik (meter)
  double distanceBetween(
    double lat1, double lng1,
    double lat2, double lng2,
  ) {
    return Geolocator.distanceBetween(lat1, lng1, lat2, lng2);
  }
}