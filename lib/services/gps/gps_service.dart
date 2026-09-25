import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../db/sync_service.dart';

class GpsResult {
  final double lat;
  final double lng;
  final double accuracyMeters;

  GpsResult({
    required this.lat,
    required this.lng,
    required this.accuracyMeters,
  });

  bool get isValid => accuracyMeters <= GpsService.maxAccuracyMeters;
}

class GpsService {
  static const double maxAccuracyMeters = 50.0;

  Future<bool> isOnline() async {
    return await SyncService().isServerReachable();
  }

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

  /// Stream mentah posisi GPS. Tanpa logic valid/timeout.
  /// Dipakai untuk warmup (jalan di background).
  Stream<GpsResult> watchPosition({required bool useSatellite}) {
    final AndroidSettings settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
      forceLocationManager: useSatellite,
    );

    return Geolocator.getPositionStream(locationSettings: settings).map(
      (pos) => GpsResult(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyMeters: pos.accuracy,
      ),
    );
  }

  /// One-shot. Fallback.
  Future<GpsResult?> getPositionSingle({
    required Duration timeout,
    required bool useSatellite,
  }) async {
    final ready = await isGpsReady();
    if (!ready) return null;

    final AndroidSettings settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
      forceLocationManager: useSatellite,
    );

    final label = useSatellite ? 'SAT' : 'FUSED';
    final tStart = DateTime.now();

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: settings,
      ).timeout(timeout);

      final elapsedMs = DateTime.now().difference(tStart).inMilliseconds;
      debugPrint("GPS: [$label] +${elapsedMs}ms  "
          "lat=${pos.latitude.toStringAsFixed(6)}, "
          "lng=${pos.longitude.toStringAsFixed(6)}, "
          "acc=${pos.accuracy.toStringAsFixed(1)}m");

      return GpsResult(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyMeters: pos.accuracy,
      );

    } on TimeoutException {
      final elapsedMs = DateTime.now().difference(tStart).inMilliseconds;
      debugPrint("GPS: [$label] TIMEOUT setelah ${elapsedMs}ms (0 data)");
      return null;

    } catch (e) {
      final elapsedMs = DateTime.now().difference(tStart).inMilliseconds;
      debugPrint("GPS: [$label] ERROR +${elapsedMs}ms → $e");
      return null;
    }
  }

  /// Stream kalibrasi — terima update berkelanjutan, break begitu
  /// accuracy ≤ maxAccuracyMeters.
  ///
  /// [onProgress] dipanggil tiap ~1 detik dengan (elapsed, total) detik.
  /// Timer pakai Timer.periodic + cek DateTime.now(), tahan idle.
  /// [isCancelled] dipanggil tiap tick — kalau return true, stream stop.
  Future<GpsResult?> getPositionStreamCalibrate({
    required Duration timeout,
    required bool useSatellite,
    void Function(int elapsedSeconds, int totalSeconds)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final ready = await isGpsReady();
    if (!ready) return null;

    final AndroidSettings settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
      forceLocationManager: useSatellite,
    );

    final label = useSatellite ? 'SAT-STREAM' : 'FUSED-STREAM';
    debugPrint("GPS: [$label] mulai kalibrasi (max ${timeout.inSeconds}s)");

    final completer = Completer<GpsResult?>();
    StreamSubscription<Position>? sub;
    Timer? periodicTimer;
    GpsResult? bestFix;
    final tStart = DateTime.now();
    bool finished = false;

    void finish(GpsResult? result, {String reason = ''}) {
      if (finished) return;
      finished = true;
      periodicTimer?.cancel();
      sub?.cancel();
      final ms = DateTime.now().difference(tStart).inMilliseconds;
      if (result == null) {
        debugPrint("GPS: [$label] selesai tanpa fix (${ms}ms) $reason");
      } else {
        debugPrint("GPS: [$label] selesai dengan acc=${result.accuracyMeters.toStringAsFixed(1)}m (${ms}ms) $reason");
      }
      if (!completer.isCompleted) completer.complete(result);
    }

    try {
      sub = Geolocator.getPositionStream(locationSettings: settings).listen(
        (pos) {
          if (finished) return;
          final elapsedMs = DateTime.now().difference(tStart).inMilliseconds;
          debugPrint("GPS: [$label] +${elapsedMs}ms acc=${pos.accuracy.toStringAsFixed(1)}m");

          final fix = GpsResult(
            lat: pos.latitude,
            lng: pos.longitude,
            accuracyMeters: pos.accuracy,
          );

          if (bestFix == null || fix.accuracyMeters < bestFix!.accuracyMeters) {
            bestFix = fix;
          }

          if (fix.isValid) {
            finish(fix, reason: 'break_valid');
          }
        },
        onError: (e) {
          debugPrint("GPS: [$label] stream error → $e");
        },
        cancelOnError: false,
      );

      periodicTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (finished) return;

        // Cek cancel dari luar (misal app resume dari background)
        if (isCancelled != null && isCancelled()) {
          finish(bestFix, reason: 'cancel_external');
          return;
        }

        final elapsedMs = DateTime.now().difference(tStart).inMilliseconds;
        final elapsedSec = elapsedMs ~/ 1000;
        onProgress?.call(elapsedSec, timeout.inSeconds);
        if (elapsedMs >= timeout.inMilliseconds) {
          finish(bestFix, reason: 'timeout');
        }
      });

      return await completer.future;

    } catch (e) {
      finish(bestFix, reason: 'error');
      debugPrint("GPS: [$label] error → $e");
      return bestFix;
    }
  }

  double distanceBetween(double lat1, double lng1, double lat2, double lng2) {
    return Geolocator.distanceBetween(lat1, lng1, lat2, lng2);
  }
}