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

class _StreamScreenState extends State<StreamScreen> {
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

  // ==================== SESSION STATE ====================
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

  // Kandidat foto gagal terbaik (distance terkecil)
  img.Image? _bestFailedPhoto;
  double? _bestFailedDistance;

  // Foto & telemetry saat match (untuk simpan foto sukses)
  img.Image? _matchedPhoto;
  double? _matchedDistance;
  String? _matchedMode;

  bool _sessionLogged = false;

  // Monotonic clock
  int? _deviceUptimeMs;
  int? _deviceBootTimeMs;

  // ==================== CONFIG ====================
  static const int _maxFaceAttempts = 10;
  static const int _maxGpsAttempts = 3;

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
    _initLightSensor();
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
      );
      _sessionLogged = true;
      debugPrint("STREAM: session $finalStatus logged (session=${_currentSessionUuid})");
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
      // Stop manual → log sebagai cancelled kalau belum selesai
      await _stopAndDisposeCamera();
      await _finishSession(finalStatus: 'cancelled');
      return;
    }

    _resetSession();

    // Ambil user & id sesi
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

    // Monotonic clock
    _deviceUptimeMs = await MonotonicClock.elapsedRealtimeMs();
    _deviceBootTimeMs = await MonotonicClock.bootTimeMs();

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

    // ===== MTCNN =====
    final tMtcStart = DateTime.now();
    final faces = await _mtcnnService.detectFaces(working, isGlassesMode: true);
    final mtcnnMs = DateTime.now().difference(tMtcStart).inMilliseconds;
    if (_mtcnnMsFirst == null) _mtcnnMsFirst = mtcnnMs;

    _attemptNumber++;

    // === MTCNN GAGAL ===
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
        await _finishSession(finalStatus: 'failed_no_face');
        await _stopAndDisposeCamera();
      }
      return;
    }

    // Wajah terdeteksi
    if (_firstFaceAt == null) _firstFaceAt = DateTime.now();

    final bestFace = faces.reduce((a, b) => a.score > b.score ? a : b);
    final aligned = _mtcnnService.alignAndCropFace(working, bestFace);
    final alignedWithLm = _mtcnnService.alignCropAndDrawLandmarks(working, bestFace);

    // ===== MFN =====
    final tMfnStart = DateTime.now();
    final embedding = _mobileFaceNetService.predict(aligned);
    final mfnMs = DateTime.now().difference(tMfnStart).inMilliseconds;
    if (_mfnMsFirst == null) _mfnMsFirst = mfnMs;

    // === MFN GAGAL (null) ===
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
        // Simpan kandidat terbaik (meski tanpa distance, tidak ada foto)
        await _finishSession(finalStatus: 'failed_verification');
        await _stopAndDisposeCamera();
      }
      return;
    }

    // ===== MATCHING =====
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

    // === MFN GAGAL (distance > threshold) ===
    if (!telemetry.isMatch) {
      _failedCount++;

      // Simpan kandidat terbaik
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

        // Simpan foto gagal terbaik
        String? photoPath;
        if (_bestFailedPhoto != null && _currentSessionUuid != null) {
          photoPath = await _savePhotoToDisk(
            _bestFailedPhoto!,
            _currentSessionUuid!,
            'failed',
          );
        }

        await _finishSession(
          finalStatus: 'failed_verification',
          photoPath: photoPath,
        );
        await _stopAndDisposeCamera();
      }
      return;
    }

    // === MATCH! ===
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

    // Stop camera, lanjut GPS
    _isDetecting = false;
    await _stopAndDisposeCamera();
    await _processGps();
  }

  // ============================================================
  // GPS PROCESSING (setelah wajah match)
  // ============================================================
  Future<void> _processGps() async {
    _isProcessingGps = true;

    // Wakelock tetap nyala selama GPS
    await WakelockPlus.enable();
    debugPrint("WAKELOCK: enabled (GPS start)");

    if (mounted) {
      setState(() {
        _statusMessage = "Wajah Valid ✅\nMencari GPS...";
        _statusColor = Colors.orangeAccent;
      });
    }

    try {
      final now = DateTime.now();
      if (!_debugSkipTimeCheck && _isAbsenTutup(now)) {
        debugPrint("STREAM: absen tutup (jam ${_jamAbsenTutup}:${_menitAbsenTutup})");
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
        await _finishSession(finalStatus: 'gps_failed', gpsResult: 'disabled');
        return;
      }

      final sekolahLat = (sekolah['lat'] as num).toDouble();
      final sekolahLng = (sekolah['lng'] as num).toDouble();
      final radius = (sekolah['radius_meters'] as num).toDouble();

      _gpsStartAt = DateTime.now();

      GpsResult? successGps;
      double? successDistance;
      String lastResult = 'timeout';
      int totalGpsMs = 0;

      // 3x percobaan GPS
      for (int i = 1; i <= _maxGpsAttempts; i++) {
        if (mounted) {
          setState(() {
            _statusMessage = "Wajah Valid ✅\nGPS attempt $i/$_maxGpsAttempts...";
          });
        }

        final tGpsStart = DateTime.now();
        final gps = await _gpsService.getPosition(
          onProgress: (acc) {
            if (mounted) {
              setState(() {
                _statusMessage = "Wajah Valid ✅\nGPS $i/$_maxGpsAttempts  (acc: ${acc.toStringAsFixed(1)}m)";
              });
            }
          },
        );
        final durationMs = DateTime.now().difference(tGpsStart).inMilliseconds;
        totalGpsMs += durationMs;

        String result;
        double? distance;

        if (gps == null) {
          result = 'timeout';
          debugPrint("GPS: attempt $i → timeout (${durationMs}ms)");
        } else if (!gps.isValid) {
          result = 'invalid_accuracy';
          distance = _gpsService.distanceBetween(sekolahLat, sekolahLng, gps.lat, gps.lng);
          debugPrint("GPS: attempt $i → invalid_accuracy (${gps.accuracyMeters.toStringAsFixed(1)}m, jarak=${distance.toStringAsFixed(1)}m)");
        } else {
          distance = _gpsService.distanceBetween(sekolahLat, sekolahLng, gps.lat, gps.lng);
          if (distance > radius) {
            result = 'out_of_radius';
            debugPrint("GPS: attempt $i → out_of_radius (jarak=${distance.toStringAsFixed(1)}m, radius=${radius.toStringAsFixed(0)}m)");
          } else {
            result = 'success';
            successGps = gps;
            successDistance = distance;
            debugPrint("GPS: attempt $i → SUCCESS (jarak=${distance.toStringAsFixed(1)}m, acc=${gps.accuracyMeters.toStringAsFixed(1)}m)");
          }
        }

        await _logGpsAttempt(
          attemptNumber: i,
          startedAt: tGpsStart,
          doneAt: DateTime.now(),
          result: result,
          lat: gps?.lat,
          lng: gps?.lng,
          accuracyMeters: gps?.accuracyMeters,
          distanceToSchool: distance,
          durationMs: durationMs,
        );

        lastResult = result;
        if (result == 'success') break;
      }

      _gpsDoneAt = DateTime.now();

      if (successGps != null && successDistance != null) {
        // ===== ABSEN SUKSES =====
        final late = _isLate(now);

        // Simpan foto sukses
        String? photoPath;
        if (_matchedPhoto != null && _currentSessionUuid != null) {
          photoPath = await _savePhotoToDisk(_matchedPhoto!, _currentSessionUuid!, 'success');
        }

        await DatabaseService.instance.addAttendance(
          userId: _currentUserId!,
          recordedAt: now,
          lat: successGps.lat,
          lng: successGps.lng,
          distanceMeters: successDistance,
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

        debugPrint("STREAM: absen VALID. jarak=${successDistance.toStringAsFixed(1)}m, late=$late");

        if (mounted) {
          setState(() {
            _statusMessage = "Absensi Berhasil! ✅\n"
                "Jarak: ${successDistance!.toStringAsFixed(1)}m\n"
                "Status: ${late ? 'Terlambat' : 'Tepat Waktu'}";
            _statusColor = Colors.greenAccent;
          });
        }

        // Trigger sync di background
        SyncService().syncAll().then((r) => debugPrint("STREAM: sync = $r"));
      } else {
        // ===== GPS GAGAL SEMUA =====
        String? photoPath;
        if (_matchedPhoto != null && _currentSessionUuid != null) {
          photoPath = await _savePhotoToDisk(_matchedPhoto!, _currentSessionUuid!, 'gps_failed');
        }

        await _finishSession(
          finalStatus: 'gps_failed',
          gpsResult: lastResult,
          gpsMs: totalGpsMs,
          photoPath: photoPath,
        );

        debugPrint("STREAM: GPS 3x gagal → sesi berakhir gps_failed ($lastResult)");

        if (mounted) {
          setState(() {
            _statusMessage = "GPS gagal 3x.\n"
                "Terakhir: $lastResult\n"
                "Tekan kamera lagi untuk coba dari awal.";
            _statusColor = Colors.redAccent;
          });
        }
      }
    } catch (e) {
      debugPrint("STREAM: GPS processing error -> $e");
      await _finishSession(finalStatus: 'gps_failed', gpsResult: 'timeout');
      if (mounted) {
        setState(() {
          _statusMessage = "Error GPS: $e";
          _statusColor = Colors.redAccent;
        });
      }
    } finally {
      _isProcessingGps = false;
      await WakelockPlus.disable();
      debugPrint("WAKELOCK: disabled (GPS done)");
    }
  }

  @override
  void dispose() {
    _lightSubscription?.cancel();
    // Log sesi kalau belum selesai (best-effort, tidak bisa await di dispose)
    if (!_sessionLogged && _currentSessionUuid != null) {
      _finishSession(finalStatus: 'cancelled');
    }
    _stopAndDisposeCamera();
    super.dispose();
  }

  // ============================================================
  // BUILD
  // ============================================================
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