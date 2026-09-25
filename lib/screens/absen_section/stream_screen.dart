import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:light/light.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../services/db/database_service.dart';
import '../../services/db/sync_service.dart';
import '../../services/gps/gps_service.dart';
import '../../services/model/mobilefacenet_service.dart';
import '../../services/model/mtcnn_service.dart';
import '../../services/monotonic_clock.dart';
import '../../services/net-service/sync_watchdog.dart';
import '../../utils/camera_image_utils.dart';

class StreamScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final bool isActive;

  const StreamScreen({
    super.key,
    required this.cameras,
    required this.isActive,
  });

  @override
  State<StreamScreen> createState() => _StreamScreenState();
}

class _AttemptOutcome {
  final GpsResult? fix;
  final double? distance;
  final String result;
  _AttemptOutcome({this.fix, this.distance, required this.result});
}

class _StreamScreenState extends State<StreamScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  DateTime _lastProcessTime = DateTime.now();

  final MTCNNService _mtcnnService = MTCNNService();
  final MobileFaceNetService _mobileFaceNetService = MobileFaceNetService();
  final GpsService _gpsService = GpsService();
  static const _uuid = Uuid();

  Light? _light;
  StreamSubscription? _lightSubscription;
  int _luxValue = 0;

  bool _isCameraActive = false;
  bool _isLoading = false;
  bool _isDetecting = false;
  bool _isProcessingGps = false;

  String _statusMessage = "Kamera Nonaktif\nKetuk kotak kamera di atas untuk mulai";
  Color _statusColor = Colors.white54;
  FaceRecognitionResult? _latestTelemetry;

  String? _currentSessionUuid;
  String? _currentUserId;
  DateTime? _sessionStartedAt;
  DateTime? _cameraReadyAt;
  DateTime? _firstFaceAt;
  DateTime? _faceValidAt;
  DateTime? _gpsStartAt;
  DateTime? _gpsDoneAt;

  int? _mtcnnMsFirst;
  int? _mfnMsFirst;
  int? _matchMsFirst;
  int? _mtcnnMsFinal;
  int? _mfnMsFinal;
  int? _matchMsFinal;

  int _failedCount = 0;
  int _attemptNumber = 0;

  img.Image? _bestFailedPhoto;
  double? _bestFailedDistance;

  img.Image? _matchedPhoto;
  double? _matchedDistance;
  String? _matchedMode;

  bool _sessionLogged = false;

  int? _deviceUptimeMs;
  int? _deviceBootTimeMs;

  StreamSubscription<GpsResult>? _warmupSub;
  GpsResult? _warmupBestFix;
  bool _warmupStarted = false;

  // Lifecycle
  DateTime? _appPausedAt;
  bool _gpsActive = false;
  bool _needsRestartAttempt = false;
  bool _forceCancelGps = false;

  static const int _maxFaceAttempts = 10;

  static const int _jamMasukOnTime = 7;
  static const int _menitMasukOnTime = 30;
  static const int _jamAbsenTutup = 10;
  static const int _menitAbsenTutup = 30;
  static const bool _debugSkipTimeCheck = true;

  bool get _isCameraReady =>
      _isCameraActive && !_isLoading && _controller != null && _controller!.value.isInitialized;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initLightSensor();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _appPausedAt = DateTime.now();
      debugPrint("APP: paused (gpsActive=$_gpsActive)");
    } else if (state == AppLifecycleState.resumed) {
      if (_appPausedAt != null && _gpsActive) {
        final pauseSec = DateTime.now().difference(_appPausedAt!).inSeconds;
        debugPrint("APP: resumed setelah ${pauseSec}s background");
        if (pauseSec >= 5) {
          debugPrint("APP: GPS mungkin mati saat background → restart attempt (sisa waktu)");
          _needsRestartAttempt = true;
          _forceCancelGps = true;
        }
      }
      _appPausedAt = null;
    }
  }

  void _initLightSensor() {
    try {
      _light = Light();
      _lightSubscription = _light?.lightSensorStream.listen(
        (luxValue) {
          if (mounted) setState(() => _luxValue = luxValue);
        },
        onError: (error) => debugPrint("Error sensor cahaya: $error"),
      );
    } catch (e) {
      debugPrint("Sensor cahaya tidak didukung: $e");
    }
  }

  @override
  void didUpdateWidget(covariant StreamScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive && oldWidget.isActive) {
      _stopAndDisposeCamera();
      _stopWarmup();
    }
  }

  bool _isLate(DateTime t) {
    final cutoff = DateTime(t.year, t.month, t.day, _jamMasukOnTime, _menitMasukOnTime);
    return t.isAfter(cutoff);
  }

  bool _isAbsenTutup(DateTime t) {
    final tutup = DateTime(t.year, t.month, t.day, _jamAbsenTutup, _menitAbsenTutup);
    return t.isAfter(tutup);
  }

  // ============================================================
  // WARMUP
  // ============================================================
  Future<void> _startWarmup() async {
    if (_warmupStarted) return;
    _warmupStarted = true;
    _warmupBestFix = null;

    final ready = await _gpsService.isGpsReady();
    if (!ready) {
      debugPrint("GPS: warmup skip, permission/service belum siap");
      return;
    }

    debugPrint("GPS: warmup start (stream Fused di background)");

    _warmupSub = _gpsService.watchPosition(useSatellite: false).listen(
      (fix) {
        if (_warmupBestFix == null || fix.accuracyMeters < _warmupBestFix!.accuracyMeters) {
          _warmupBestFix = fix;
          debugPrint("GPS: warmup update acc=${fix.accuracyMeters.toStringAsFixed(1)}m");
        }
      },
      onError: (e) => debugPrint("GPS: warmup error → $e"),
      cancelOnError: false,
    );
  }

  Future<void> _stopWarmup() async {
    if (!_warmupStarted) return;
    _warmupStarted = false;
    await _warmupSub?.cancel();
    _warmupSub = null;
    debugPrint("GPS: warmup stop");
  }

  // ============================================================
  // SESSION HELPERS
  // ============================================================
  void _resetSession() {
    _currentSessionUuid = null;
    _currentUserId = null;
    _sessionStartedAt = null;
    _cameraReadyAt = null;
    _firstFaceAt = null;
    _faceValidAt = null;
    _gpsStartAt = null;
    _gpsDoneAt = null;

    _mtcnnMsFirst = null;
    _mfnMsFirst = null;
    _matchMsFirst = null;
    _mtcnnMsFinal = null;
    _mfnMsFinal = null;
    _matchMsFinal = null;

    _failedCount = 0;
    _attemptNumber = 0;
    _bestFailedPhoto = null;
    _bestFailedDistance = null;
    _matchedPhoto = null;
    _matchedDistance = null;
    _matchedMode = null;
    _sessionLogged = false;

    _deviceUptimeMs = null;
    _deviceBootTimeMs = null;

    _warmupBestFix = null;
    _forceCancelGps = false;
    _needsRestartAttempt = false;
  }

  Future<String?> _savePhotoToDisk(img.Image image, String sessionUuid, String tag) async {
    try {
      final user = await DatabaseService.instance.getUser();
      if (user == null) return null;

      final dir = await DatabaseService.instance.getPhotoDir();
      final userDir = Directory(p.join(dir.path, user['user_id'] as String));
      if (!await userDir.exists()) await userDir.create(recursive: true);

      final filename = '${sessionUuid}_$tag.jpg';
      final fullPath = p.join(userDir.path, filename);
      final jpg = img.encodeJpg(image, quality: 75);
      await File(fullPath).writeAsBytes(jpg);
      return fullPath;
    } catch (e) {
      debugPrint("STREAM: gagal simpan foto -> $e");
      return null;
    }
  }

  Future<void> _logFaceAttempt({
    required int attemptNumber,
    required String mtcnnStatus,
    int? mtcnnMs,
    String? mfnStatus,
    int? mfnMs,
    double? matchDistance,
  }) async {
    if (_currentSessionUuid == null || _currentUserId == null) return;
    try {
      await DatabaseService.instance.addFaceAttempt(
        sessionUuid: _currentSessionUuid!,
        userId: _currentUserId!,
        attemptNumber: attemptNumber,
        attemptedAt: DateTime.now(),
        mtcnnStatus: mtcnnStatus,
        mtcnnMs: mtcnnMs,
        mfnStatus: mfnStatus,
        mfnMs: mfnMs,
        matchDistance: matchDistance,
        luxValue: _luxValue,
      );
    } catch (e) {
      debugPrint("STREAM: log face attempt gagal -> $e");
    }
  }

  Future<void> _logGpsAttempt({
    required int attemptNumber,
    required DateTime startedAt,
    DateTime? doneAt,
    required String result,
    double? lat,
    double? lng,
    double? accuracyMeters,
    double? distanceToSchool,
    int? durationMs,
  }) async {
    if (_currentSessionUuid == null || _currentUserId == null) return;
    try {
      await DatabaseService.instance.addGpsAttempt(
        sessionUuid: _currentSessionUuid!,
        userId: _currentUserId!,
        attemptNumber: attemptNumber,
        startedAt: startedAt,
        doneAt: doneAt,
        result: result,
        lat: lat,
        lng: lng,
        accuracyMeters: accuracyMeters,
        distanceToSchool: distanceToSchool,
        durationMs: durationMs,
      );
    } catch (e) {
      debugPrint("STREAM: log gps attempt gagal -> $e");
    }
  }

  Future<void> _finishSession({
    required String finalStatus,
    String? gpsResult,
    int? gpsMs,
    String? photoPath,
  }) async {
    if (_sessionLogged || _currentSessionUuid == null || _currentUserId == null) return;
    if (_sessionStartedAt == null) return;

    try {
      await DatabaseService.instance.addSessionLog(
        sessionUuid: _currentSessionUuid!,
        userId: _currentUserId!,
        sessionType: 'attendance',
        startedAt: _sessionStartedAt!,
        cameraReadyAt: _cameraReadyAt,
        firstFaceAt: _firstFaceAt,
        mtcnnMsFirst: _mtcnnMsFirst,
        mfnMsFirst: _mfnMsFirst,
        matchMsFirst: _matchMsFirst,
        mtcnnMsFinal: _mtcnnMsFinal,
        mfnMsFinal: _mfnMsFinal,
        matchMsFinal: _matchMsFinal,
        faceValidAt: _faceValidAt,
        failedCount: _failedCount,
        gpsStartAt: _gpsStartAt,
        gpsDoneAt: _gpsDoneAt,
        gpsResult: gpsResult,
        gpsMs: gpsMs,
        finalStatus: finalStatus,
        finalAt: DateTime.now(),
        photoPath: photoPath,
        deviceUptimeMs: _deviceUptimeMs,
        deviceBootTimeMs: _deviceBootTimeMs,
        luxValue: _luxValue,
      );
      _sessionLogged = true;
      debugPrint("STREAM: session $finalStatus logged (session=${_currentSessionUuid})");

      // Trigger sync ke server (fire and forget).
      // Berlaku untuk semua status: success, failed_verification,
      // failed_no_face, gps_failed, cancelled, expired.
      // Kalau ada sync sedang jalan, akan di-skip oleh _isSyncing
      // flag di SyncService.
      SyncService().syncAll().then((r) {
        debugPrint("STREAM: post-finish sync = $r");
        // Cek pending sisa → aktifkan watchdog kalau ada.
        SyncWatchdog().notify();
      });
    } catch (e) {
      debugPrint("STREAM: log session gagal -> $e");
    }
  }

  // ============================================================
  // CAMERA CONTROL
  // ============================================================
  Future<void> _toggleOrStartCamera() async {
    if (_isLoading || _isProcessingGps) return;

    if (_isCameraActive) {
      await _stopAndDisposeCamera();
      await _stopWarmup();
      await _finishSession(finalStatus: 'cancelled');
      return;
    }

    _resetSession();

    final user = await DatabaseService.instance.getUser();
    if (user == null) {
      setState(() {
        _statusMessage = "User tidak ditemukan. Login ulang.";
        _statusColor = Colors.redAccent;
      });
      return;
    }
    _currentUserId = user['user_id'] as String;
    _currentSessionUuid = _uuid.v4();
    _sessionStartedAt = DateTime.now();

    _deviceUptimeMs = await MonotonicClock.elapsedRealtimeMs();
    _deviceBootTimeMs = await MonotonicClock.bootTimeMs();

    _startWarmup();

    setState(() {
      _isLoading = true;
      _statusMessage = "Menyiapkan MTCNN...";
      _statusColor = Colors.orangeAccent;
    });

    try {
      await _mtcnnService.init();
      if (!_mobileFaceNetService.isModelLoaded) {
        await _mobileFaceNetService.init();
      }

      await _stopAndDisposeCamera();
      await Future.delayed(const Duration(milliseconds: 250));

      final frontCamera = widget.cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => widget.cameras.first,
      );

      final controller = CameraController(
        frontCamera,
        ResolutionPreset.low,
        enableAudio: false,
      );

      await controller.initialize();
      if (!mounted) return;

      _cameraReadyAt = DateTime.now();
      final setupMs = _cameraReadyAt!.difference(_sessionStartedAt!).inMilliseconds;
      debugPrint("TIMING: [1] Kamera siap ${setupMs}ms sejak tombol ditekan");

      await WakelockPlus.enable();
      debugPrint("WAKELOCK: enabled (camera active)");

      setState(() {
        _controller = controller;
        _isCameraActive = true;
        _statusMessage = "Mencari Wajah (MTCNN)...";
        _statusColor = Colors.orangeAccent;
      });

      _lastProcessTime = DateTime.now().subtract(const Duration(seconds: 5));
      _startCameraStream();
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = "Gagal Membuka Kamera.";
          _statusColor = Colors.redAccent;
          _isCameraActive = false;
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _stopAndDisposeCamera() async {
    final oldController = _controller;
    if (oldController == null) return;

    _controller = null;
    _isDetecting = false;

    if (mounted) {
      setState(() {
        _isCameraActive = false;
        if (!_isProcessingGps) {
          _statusMessage = "Kamera Nonaktif\nKetuk kotak kamera di atas untuk mulai";
          _statusColor = Colors.white54;
        }
      });
    }

    try {
      if (oldController.value.isInitialized && oldController.value.isStreamingImages) {
        await oldController.stopImageStream();
      }
    } catch (e) {
      debugPrint("Error stop stream: $e");
    } finally {
      await oldController.dispose();
      if (!_isProcessingGps) {
        await WakelockPlus.disable();
        debugPrint("WAKELOCK: disabled (camera stop, not in GPS)");
      } else {
        debugPrint("WAKELOCK: keep enabled (GPS processing)");
      }
    }
  }

  // ============================================================
  // CAMERA STREAM
  // ============================================================
  void _startCameraStream() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_controller!.value.isStreamingImages) return;

    int frameCount = 0;
    const int framesToSkip = 3;
    bool warmupDone = false;

    _controller!.startImageStream((CameraImage cameraImage) async {
      frameCount++;

      if (!warmupDone) {
        if (frameCount < framesToSkip) return;
        warmupDone = true;
        debugPrint("STREAM_WARMUP: skip $framesToSkip frame pertama");
      }

      if (_isProcessingGps) return;

      final now = DateTime.now();
      if (now.difference(_lastProcessTime).inMilliseconds < 1500) return;

      if (_isDetecting || !_isCameraActive) return;
      _isDetecting = true;
      _lastProcessTime = now;

      try {
        await _processFrame(cameraImage);
      } catch (e) {
        debugPrint("STREAM: error proses frame -> $e");
      } finally {
        _isDetecting = false;
      }
    });
  }

  Future<void> _processFrame(CameraImage cameraImage) async {
    final tFrameStart = DateTime.now();

    final rawRgb = convertCameraImageToRgb(cameraImage);
    if (rawRgb == null) return;

    final oriented = correctLiveStreamRotation(rawRgb, _controller!.description);

    const int targetWidth = 480;
    final working = oriented.width > targetWidth
        ? img.copyResize(oriented, width: targetWidth)
        : oriented;

    final tMtcStart = DateTime.now();
    final faces = await _mtcnnService.detectFaces(working, isGlassesMode: true);
    final mtcnnMs = DateTime.now().difference(tMtcStart).inMilliseconds;
    if (_mtcnnMsFirst == null) _mtcnnMsFirst = mtcnnMs;

    _attemptNumber++;

    if (faces.isEmpty) {
      _failedCount++;
      debugPrint("STREAM: MTCNN 0 wajah (attempt=$_attemptNumber, failed=$_failedCount, ${mtcnnMs}ms)");

      await _logFaceAttempt(
        attemptNumber: _attemptNumber,
        mtcnnStatus: 'no_face',
        mtcnnMs: mtcnnMs,
      );

      if (_failedCount >= _maxFaceAttempts) {
        debugPrint("STREAM: 10x gagal → sesi berakhir failed_no_face");
        await _stopWarmup();
        await _finishSession(finalStatus: 'failed_no_face');
        await _stopAndDisposeCamera();
      }
      return;
    }

    if (_firstFaceAt == null) _firstFaceAt = DateTime.now();

    final bestFace = faces.reduce((a, b) => a.score > b.score ? a : b);
    final aligned = _mtcnnService.alignAndCropFace(working, bestFace);
    final alignedWithLm = _mtcnnService.alignCropAndDrawLandmarks(working, bestFace);

    final tMfnStart = DateTime.now();
    final embedding = _mobileFaceNetService.predict(aligned);
    final mfnMs = DateTime.now().difference(tMfnStart).inMilliseconds;
    if (_mfnMsFirst == null) _mfnMsFirst = mfnMs;

    if (embedding == null) {
      _failedCount++;
      debugPrint("STREAM: MFN null (attempt=$_attemptNumber, failed=$_failedCount, ${mfnMs}ms)");

      await _logFaceAttempt(
        attemptNumber: _attemptNumber,
        mtcnnStatus: 'detected',
        mtcnnMs: mtcnnMs,
        mfnStatus: 'skipped',
        mfnMs: mfnMs,
      );

      if (_failedCount >= _maxFaceAttempts) {
        debugPrint("STREAM: 10x gagal → sesi berakhir failed_verification");
        await _stopWarmup();
        await _finishSession(finalStatus: 'failed_verification');
        await _stopAndDisposeCamera();
      }
      return;
    }

    final tMatchStart = DateTime.now();
    final telemetry = _mobileFaceNetService.evaluateFace(embedding);
    final matchMs = DateTime.now().difference(tMatchStart).inMilliseconds;
    if (_matchMsFirst == null) _matchMsFirst = matchMs;

    final totalFrameMs = DateTime.now().difference(tFrameStart).inMilliseconds;

    debugPrint("STREAM: frame #$_attemptNumber  "
        "MTCNN=${mtcnnMs}ms  MFN=${mfnMs}ms  Match=${matchMs}ms  "
        "Total=${totalFrameMs}ms  "
        "distance=${telemetry.distance.toStringAsFixed(4)}  "
        "mode=${telemetry.matchMode}  "
        "isMatch=${telemetry.isMatch}  "
        "(failed=$_failedCount)");

    _mobileFaceNetService.recordAttempt(faceImage: aligned, telemetry: telemetry);

    if (mounted) setState(() => _latestTelemetry = telemetry);

    if (!telemetry.isMatch) {
      _failedCount++;

      if (_bestFailedDistance == null || telemetry.distance < _bestFailedDistance!) {
        _bestFailedDistance = telemetry.distance;
        _bestFailedPhoto = alignedWithLm;
      }

      await _logFaceAttempt(
        attemptNumber: _attemptNumber,
        mtcnnStatus: 'detected',
        mtcnnMs: mtcnnMs,
        mfnStatus: 'below_threshold',
        mfnMs: mfnMs,
        matchDistance: telemetry.distance,
      );

      if (mounted) {
        setState(() {
          _statusMessage = "Wajah Tidak Dikenali!\nGagal: $_failedCount/$_maxFaceAttempts";
          _statusColor = Colors.redAccent;
        });
      }

      if (_failedCount >= _maxFaceAttempts) {
        debugPrint("STREAM: 10x gagal → sesi berakhir failed_verification");

        String? photoPath;
        if (_bestFailedPhoto != null && _currentSessionUuid != null) {
          photoPath = await _savePhotoToDisk(
            _bestFailedPhoto!,
            _currentSessionUuid!,
            'failed',
          );
        }

        await _stopWarmup();
        await _finishSession(
          finalStatus: 'failed_verification',
          photoPath: photoPath,
        );
        await _stopAndDisposeCamera();
      }
      return;
    }

    // === MATCH ===
    _faceValidAt = DateTime.now();
    _mtcnnMsFinal = mtcnnMs;
    _mfnMsFinal = mfnMs;
    _matchMsFinal = matchMs;

    _matchedPhoto = alignedWithLm;
    _matchedDistance = telemetry.distance;
    _matchedMode = telemetry.matchMode;

    await _logFaceAttempt(
      attemptNumber: _attemptNumber,
      mtcnnStatus: 'detected',
      mtcnnMs: mtcnnMs,
      mfnStatus: 'match',
      mfnMs: mfnMs,
      matchDistance: telemetry.distance,
    );

    debugPrint("STREAM: MATCH! distance=${telemetry.distance.toStringAsFixed(4)} mode=${telemetry.matchMode}");

    if (mounted) {
      setState(() {
        _statusMessage = "Wajah Valid ✅\nMenghentikan kamera...";
        _statusColor = Colors.greenAccent;
      });
    }

    _isDetecting = false;
    await _stopAndDisposeCamera();
    await _processGps();
  }

  // ============================================================
  // GPS PROCESSING
  // ============================================================
  Future<void> _processGps() async {
    _isProcessingGps = true;
    await WakelockPlus.enable();
    debugPrint("WAKELOCK: enabled (GPS start)");
    _gpsActive = true;
    await MonotonicClock.startGpsService();
    debugPrint("FOREGROUND_SERVICE: start");

    if (mounted) {
      setState(() {
        _statusMessage = "Wajah Valid ✅\nCek lokasi GPS...";
        _statusColor = Colors.orangeAccent;
      });
    }

    try {
      final now = DateTime.now();
      if (!_debugSkipTimeCheck && _isAbsenTutup(now)) {
        debugPrint("STREAM: absen tutup");
        await _stopWarmup();
        await _finishSession(finalStatus: 'expired');
        if (mounted) {
          setState(() {
            _statusMessage = "Batas absen sudah lewat.";
            _statusColor = Colors.redAccent;
          });
        }
        return;
      }

      final sekolah = await DatabaseService.instance.getSekolah();
      if (sekolah == null) {
        debugPrint("STREAM: sekolah tidak ada di SQLite");
        await _stopWarmup();
        await _finishSession(finalStatus: 'gps_failed', gpsResult: 'disabled');
        return;
      }

      final sekolahLat = (sekolah['lat'] as num).toDouble();
      final sekolahLng = (sekolah['lng'] as num).toDouble();
      final radius = (sekolah['radius_meters'] as num).toDouble();

      _gpsStartAt = DateTime.now();

      // ============ CEK HASIL WARMUP DULU ============
      final warmupFix = _warmupBestFix;
      await _stopWarmup();

      if (warmupFix != null && warmupFix.isValid) {
        final dist = _gpsService.distanceBetween(
          sekolahLat, sekolahLng, warmupFix.lat, warmupFix.lng,
        );
        debugPrint("GPS: warmup fix dipakai  acc=${warmupFix.accuracyMeters.toStringAsFixed(1)}m, "
            "dist=${dist.toStringAsFixed(0)}m");

        if (dist <= radius) {
          await _handleGpsSuccess(warmupFix, dist, now);
          return;
        } else {
          _gpsDoneAt = DateTime.now();
          final totalGpsMs = _gpsDoneAt!.difference(_gpsStartAt!).inMilliseconds;

          String? photoPath;
          if (_matchedPhoto != null && _currentSessionUuid != null) {
            photoPath = await _savePhotoToDisk(_matchedPhoto!, _currentSessionUuid!, 'gps_failed');
          }

          await _finishSession(
            finalStatus: 'gps_failed',
            gpsResult: 'out_of_radius',
            gpsMs: totalGpsMs,
            photoPath: photoPath,
          );

          debugPrint("STREAM: warmup fix di luar radius → gps_failed (out_of_radius)");

          if (mounted) {
            setState(() {
              _statusMessage = "Anda di luar radius sekolah.\n"
                  "Jarak: ${dist.toStringAsFixed(0)}m (maks ${radius.toStringAsFixed(0)}m)";
              _statusColor = Colors.redAccent;
            });
          }
          return;
        }
      } else if (warmupFix != null) {
        debugPrint("GPS: warmup fix acc=${warmupFix.accuracyMeters.toStringAsFixed(1)}m "
            "(>50m), lanjut attempt 1");
      } else {
        debugPrint("GPS: warmup null, lanjut attempt 1");
      }

      // ============ ATTEMPT 1 (Fused 15s) ============
      bool useSatellite = false;
      bool hasLocked = false;
      GpsResult? bestFix;
      double? bestDistance;
      String lastResult = 'timeout';

      {
        final outcome = await _runAttemptWithRestart(
          number: 1,
          useSatellite: false,
          timeout: const Duration(seconds: 15),
          sekolahLat: sekolahLat,
          sekolahLng: sekolahLng,
          radius: radius,
          statusPrefix: "Cek lokasi GPS",
        );
        lastResult = outcome.result;
        if (outcome.fix != null &&
            (bestFix == null || outcome.fix!.accuracyMeters < bestFix!.accuracyMeters)) {
          bestFix = outcome.fix;
          bestDistance = outcome.distance;
        }
        if (outcome.result == 'success') {
          await _handleGpsSuccess(outcome.fix!, outcome.distance!, now);
          return;
        }
        if (outcome.result == 'timeout') {
          useSatellite = true;
        }
      }

      // ============ ATTEMPT 2 ============
      if (useSatellite) {
        final stageA = await _runAttemptWithRestart(
          number: 2,
          useSatellite: true,
          timeout: const Duration(seconds: 90),
          sekolahLat: sekolahLat,
          sekolahLng: sekolahLng,
          radius: radius,
          statusPrefix: "Menunggu sinyal satelit",
          hintAtSeconds: 60,
          hintText: "Coba pindah ke area lebih terbuka.",
        );
        lastResult = stageA.result;
        if (stageA.fix != null &&
            (bestFix == null || stageA.fix!.accuracyMeters < bestFix!.accuracyMeters)) {
          bestFix = stageA.fix;
          bestDistance = stageA.distance;
        }
        if (stageA.result == 'success') {
          await _handleGpsSuccess(stageA.fix!, stageA.distance!, now);
          return;
        }
        if (stageA.fix != null) {
          hasLocked = true;
          final stageB = await _runAttemptWithRestart(
            number: 2,
            useSatellite: true,
            timeout: const Duration(seconds: 15),
            sekolahLat: sekolahLat,
            sekolahLng: sekolahLng,
            radius: radius,
            statusPrefix: "Kalibrasi GPS satelit",
          );
          lastResult = stageB.result;
          if (stageB.fix != null &&
              (bestFix == null || stageB.fix!.accuracyMeters < bestFix!.accuracyMeters)) {
            bestFix = stageB.fix;
            bestDistance = stageB.distance;
          }
          if (stageB.result == 'success') {
            await _handleGpsSuccess(stageB.fix!, stageB.distance!, now);
            return;
          }
        } else {
          debugPrint("GPS: attempt 2 SAT 0 fix → early exit, tidak lanjut attempt 3");
          await _handleGpsFailed(
            result: 'timeout',
            bestFix: bestFix,
            bestDistance: bestDistance,
            radius: radius,
          );
          return;
        }
      } else {
        final outcome = await _runAttemptWithRestart(
          number: 2,
          useSatellite: false,
          timeout: const Duration(seconds: 15),
          sekolahLat: sekolahLat,
          sekolahLng: sekolahLng,
          radius: radius,
          statusPrefix: "Cek lokasi GPS (2/3)",
        );
        lastResult = outcome.result;
        if (outcome.fix != null &&
            (bestFix == null || outcome.fix!.accuracyMeters < bestFix!.accuracyMeters)) {
          bestFix = outcome.fix;
          bestDistance = outcome.distance;
        }
        if (outcome.result == 'success') {
          await _handleGpsSuccess(outcome.fix!, outcome.distance!, now);
          return;
        }
        useSatellite = true;
      }

      // ============ ATTEMPT 3 ============
      if (hasLocked) {
        final outcome = await _runAttemptWithRestart(
          number: 3,
          useSatellite: true,
          timeout: const Duration(seconds: 15),
          sekolahLat: sekolahLat,
          sekolahLng: sekolahLng,
          radius: radius,
          statusPrefix: "Kalibrasi final",
        );
        lastResult = outcome.result;
        if (outcome.fix != null &&
            (bestFix == null || outcome.fix!.accuracyMeters < bestFix!.accuracyMeters)) {
          bestFix = outcome.fix;
          bestDistance = outcome.distance;
        }
        if (outcome.result == 'success') {
          await _handleGpsSuccess(outcome.fix!, outcome.distance!, now);
          return;
        }
      } else {
        final stageA = await _runAttemptWithRestart(
          number: 3,
          useSatellite: true,
          timeout: const Duration(seconds: 90),
          sekolahLat: sekolahLat,
          sekolahLng: sekolahLng,
          radius: radius,
          statusPrefix: "Menunggu sinyal satelit (extratime)",
        );
        lastResult = stageA.result;
        if (stageA.fix != null &&
            (bestFix == null || stageA.fix!.accuracyMeters < bestFix!.accuracyMeters)) {
          bestFix = stageA.fix;
          bestDistance = stageA.distance;
        }
        if (stageA.result == 'success') {
          await _handleGpsSuccess(stageA.fix!, stageA.distance!, now);
          return;
        }
        if (stageA.fix != null) {
          hasLocked = true;
          final stageB = await _runAttemptWithRestart(
            number: 3,
            useSatellite: true,
            timeout: const Duration(seconds: 15),
            sekolahLat: sekolahLat,
            sekolahLng: sekolahLng,
            radius: radius,
            statusPrefix: "Kalibrasi final",
          );
          lastResult = stageB.result;
          if (stageB.fix != null &&
              (bestFix == null || stageB.fix!.accuracyMeters < bestFix!.accuracyMeters)) {
            bestFix = stageB.fix;
            bestDistance = stageB.distance;
          }
          if (stageB.result == 'success') {
            await _handleGpsSuccess(stageB.fix!, stageB.distance!, now);
            return;
          }
        }
      }

      // ============ SEMUA GAGAL ============
      await _handleGpsFailed(
        result: lastResult,
        bestFix: bestFix,
        bestDistance: bestDistance,
        radius: radius,
      );

    } catch (e) {
      debugPrint("STREAM: GPS processing error → $e");
      await _stopWarmup();
      await _finishSession(finalStatus: 'gps_failed', gpsResult: 'timeout');
      if (mounted) {
        setState(() {
          _statusMessage = "Error GPS: $e";
          _statusColor = Colors.redAccent;
        });
      }
    } finally {
      _isProcessingGps = false;
      _gpsActive = false;
      await MonotonicClock.stopGpsService();
      debugPrint("FOREGROUND_SERVICE: stop");
      await WakelockPlus.disable();
      debugPrint("WAKELOCK: disabled (GPS done)");
    }
  }

  Future<void> _handleGpsFailed({
    required String result,
    GpsResult? bestFix,
    double? bestDistance,
    required double radius,
  }) async {
    _gpsDoneAt = DateTime.now();
    final totalGpsMs = _gpsDoneAt!.difference(_gpsStartAt!).inMilliseconds;

    String? photoPath;
    if (_matchedPhoto != null && _currentSessionUuid != null) {
      photoPath = await _savePhotoToDisk(_matchedPhoto!, _currentSessionUuid!, 'gps_failed');
    }

    await _finishSession(
      finalStatus: 'gps_failed',
      gpsResult: result,
      gpsMs: totalGpsMs,
      photoPath: photoPath,
    );

    debugPrint("STREAM: GPS gagal → sesi berakhir gps_failed ($result)");

    if (mounted) {
      String userMsg;
      if (result == 'timeout') {
        userMsg = "GPS tidak mendapat sinyal.\nCoba lagi di area lebih terbuka.";
      } else if (result == 'out_of_radius') {
        final d = bestDistance?.toStringAsFixed(0) ?? '?';
        userMsg = "Anda di luar radius sekolah.\nJarak: ${d}m (maks ${radius.toStringAsFixed(0)}m)";
      } else {
        userMsg = "GPS tidak akurat setelah semua percobaan.\nCoba lagi di area terbuka.";
      }
      setState(() {
        _statusMessage = userMsg;
        _statusColor = Colors.redAccent;
      });
    }
  }

  /// Wrapper: jalankan attempt, ulang kalau app resume dari background.
  /// Waktu total attempt tetap (timeout), tapi kalau di-background,
  /// waktu yang terbuang dipotong dari timeout iterasi berikutnya.
  Future<_AttemptOutcome> _runAttemptWithRestart({
    required int number,
    required bool useSatellite,
    required Duration timeout,
    required double sekolahLat,
    required double sekolahLng,
    required double radius,
    required String statusPrefix,
    int? hintAtSeconds,
    String? hintText,
  }) async {
    final tStart = DateTime.now();
    while (true) {
      _needsRestartAttempt = false;
      _forceCancelGps = false;

      final elapsedMs = DateTime.now().difference(tStart).inMilliseconds;
      final remainingMs = timeout.inMilliseconds - elapsedMs;

      if (remainingMs <= 0) {
        debugPrint("GPS: attempt $number habis waktu sebelum restart "
            "(elapsed=${elapsedMs}ms, timeout=${timeout.inMilliseconds}ms)");
        return _AttemptOutcome(fix: null, distance: null, result: 'timeout');
      }

      final outcome = await _runAttempt(
        number: number,
        useSatellite: useSatellite,
        timeout: Duration(milliseconds: remainingMs),
        sekolahLat: sekolahLat,
        sekolahLng: sekolahLng,
        radius: radius,
        statusPrefix: statusPrefix,
        hintAtSeconds: hintAtSeconds,
        hintText: hintText,
      );

      if (!_needsRestartAttempt) return outcome;

      final usedMs = DateTime.now().difference(tStart).inMilliseconds;
      final leftMs = timeout.inMilliseconds - usedMs;
      debugPrint("GPS: attempt $number diulang "
          "(sudah pakai ${usedMs}ms, sisa ${leftMs}ms)");

      if (mounted) {
        setState(() {
          _statusMessage = "Wajah Valid ✅\nRestart GPS setelah background...";
          _statusColor = Colors.orangeAccent;
        });
      }
    }
  }

  /// Satu attempt GPS — stream kalibrasi.
  /// [hintAtSeconds] & [hintText] opsional: UI tambah hint setelah detik tertentu.
  Future<_AttemptOutcome> _runAttempt({
    required int number,
    required bool useSatellite,
    required Duration timeout,
    required double sekolahLat,
    required double sekolahLng,
    required double radius,
    required String statusPrefix,
    int? hintAtSeconds,
    String? hintText,
  }) async {
    if (mounted) {
      setState(() {
        _statusMessage = "Wajah Valid ✅\n$statusPrefix...";
        _statusColor = Colors.orangeAccent;
      });
    }

    final tStart = DateTime.now();
    final mode = useSatellite ? 'SAT' : 'FUSED';
    debugPrint("GPS: attempt $number [$mode] ($statusPrefix) — start, timeout=${timeout.inSeconds}s");

    final gps = await _gpsService.getPositionStreamCalibrate(
      timeout: timeout,
      useSatellite: useSatellite,
      isCancelled: () => _forceCancelGps,
      onProgress: (elapsed, total) {
        if (!mounted) return;
        String msg = "Wajah Valid ✅\n$statusPrefix ($elapsed/$total detik)";
        if (hintAtSeconds != null && hintText != null && elapsed >= hintAtSeconds) {
          msg += "\n$hintText";
        }
        setState(() {
          _statusMessage = msg;
          _statusColor = Colors.orangeAccent;
        });
      },
    );

    final durationMs = DateTime.now().difference(tStart).inMilliseconds;

    String result;
    double? distance;

    if (gps == null) {
      result = 'timeout';
    } else {
      distance = _gpsService.distanceBetween(sekolahLat, sekolahLng, gps.lat, gps.lng);
      if (gps.isValid && distance <= radius) {
        result = 'success';
      } else if (gps.isValid) {
        result = 'out_of_radius';
      } else {
        result = 'invalid_accuracy';
      }

      if (mounted) {
        setState(() {
          _statusMessage = "Wajah Valid ✅\n$statusPrefix...\n(acc: ${gps.accuracyMeters.toStringAsFixed(1)}m)";
        });
      }
    }

    debugPrint("GPS: attempt $number [$mode] ($statusPrefix) → $result (${durationMs}ms)");

    await _logGpsAttempt(
      attemptNumber: number,
      startedAt: tStart,
      doneAt: DateTime.now(),
      result: result,
      lat: gps?.lat,
      lng: gps?.lng,
      accuracyMeters: gps?.accuracyMeters,
      distanceToSchool: distance,
      durationMs: durationMs,
    );

    return _AttemptOutcome(fix: gps, distance: distance, result: result);
  }

  Future<void> _handleGpsSuccess(GpsResult fix, double distance, DateTime now) async {
    _gpsDoneAt = DateTime.now();
    final totalGpsMs = _gpsDoneAt!.difference(_gpsStartAt!).inMilliseconds;
    final late = _isLate(now);

    String? photoPath;
    if (_matchedPhoto != null && _currentSessionUuid != null) {
      photoPath = await _savePhotoToDisk(_matchedPhoto!, _currentSessionUuid!, 'success');
    }

    // Cek server benar-benar reachable (bukan cuma WiFi nyala).
    final isOnline = await SyncService().isServerReachable();

    await DatabaseService.instance.addAttendance(
      userId: _currentUserId!,
      recordedAt: now,
      lat: fix.lat,
      lng: fix.lng,
      distanceMeters: distance,
      matchDistance: _matchedDistance!,
      matchMode: _matchedMode!,
      connectivityMode: 'online',
      isLate: late,
      sessionUuid: _currentSessionUuid,
      photoPath: photoPath,
    );

    await _finishSession(
      finalStatus: 'success',
      gpsResult: 'success',
      gpsMs: totalGpsMs,
      photoPath: photoPath,
    );

    debugPrint("STREAM: absen VALID. jarak=${distance.toStringAsFixed(1)}m, "
        "acc=${fix.accuracyMeters.toStringAsFixed(1)}m, late=$late");

    if (mounted) {
      setState(() {
        _statusMessage = "Absensi Berhasil! ✅\n"
            "Jarak: ${distance.toStringAsFixed(1)}m\n"
            "Accuracy: ${fix.accuracyMeters.toStringAsFixed(1)}m\n"
            "Status: ${late ? 'Terlambat' : 'Tepat Waktu'}";
        _statusColor = Colors.greenAccent;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lightSubscription?.cancel();
    _stopWarmup();
    if (!_sessionLogged && _currentSessionUuid != null) {
      _finishSession(finalStatus: 'cancelled');
    }
    _stopAndDisposeCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Menu Absen Wajah")),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Center(
                child: GestureDetector(
                  onTap: _toggleOrStartCamera,
                  child: Container(
                    width: 300,
                    height: 400,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _isCameraActive ? Colors.green : Colors.grey.shade700,
                        width: 3,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(13),
                      child: _isLoading
                          ? const Center(child: CircularProgressIndicator(color: Colors.white))
                          : _isCameraReady
                              ? Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    FittedBox(
                                      fit: BoxFit.cover,
                                      child: SizedBox(
                                        width: _controller!.value.previewSize!.height,
                                        height: _controller!.value.previewSize!.width,
                                        child: CameraPreview(_controller!),
                                      ),
                                    ),
                                    Positioned(
                                      bottom: 16, left: 16, right: 16,
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          _statusMessage,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: _statusColor,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Text(
                                      _statusMessage,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _statusColor,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (_latestTelemetry != null) ...[
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      children: [
                        Text(
                          "Status Matching",
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey.shade700),
                        ),
                        const SizedBox(height: 4),
                        Text("Euclidean Distance: ${_latestTelemetry!.distance.toStringAsFixed(4)}"),
                        Text("Kemiripan: ${(_latestTelemetry!.similarity * 100).toStringAsFixed(1)}%"),
                        Text("Mode Match: ${_latestTelemetry!.matchMode}"),
                        Text("Total Terdaftar: ${_latestTelemetry!.totalRegisteredCount}"),
                        Text("Cahaya (AUX): $_luxValue lux"),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}