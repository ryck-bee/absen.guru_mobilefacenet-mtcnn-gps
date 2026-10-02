import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:light/light.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../config/app_colors.dart';
import '../../config/app_spacing.dart';
import '../../services/db/database_service.dart';
import '../../services/db/sync_service.dart';
import '../../services/model/mobilefacenet_service.dart';
import '../../services/model/mtcnn_service.dart';
import '../../utils/camera_image_utils.dart';
import '../../widgets/loading_overlay.dart';
import '../../widgets/app_spinner.dart';

enum _CaptureStatus { none, success, failed }

class FaceEntryScreen extends StatefulWidget {
  final VoidCallback? onFinished;

  const FaceEntryScreen({super.key, this.onFinished});

  @override
  State<FaceEntryScreen> createState() => _FaceEntryScreenState();
}

class _FaceEntryScreenState extends State<FaceEntryScreen> {
  String? _userId;
  bool _alreadyRegistered = false;

  bool _useGlasses = false;
  bool _importing = false;
  bool _importAvailable = false;
  int _savedNormalCount = 0;
  int _savedGlassesCount = 0;
  bool _glassesStage = false;
  _CaptureStatus _lastStatus = _CaptureStatus.none;

  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;

  Light? _light;
  StreamSubscription? _lightSubscription;
  int _luxValue = 0;

  static const _uuid = Uuid();

  int get _totalRequired => _useGlasses ? 6 : 3;
  int get _savedCount => _savedNormalCount + _savedGlassesCount;

  bool get _isCameraReady =>
      _isCameraInitialized &&
      _controller != null &&
      _controller!.value.isInitialized;

  @override
  void initState() {
    super.initState();
    _initLightSensor();
    _init();
  }

  @override
  void dispose() {
    _lightSubscription?.cancel();
    _stopAndDisposeCamera();
    super.dispose();
  }

  void _initLightSensor() {
    try {
      _light = Light();
      _lightSubscription = _light?.lightSensorStream.listen(
        (luxValue) {
          if (mounted) _luxValue = luxValue;
        },
        onError: (e) => debugPrint("FACE ENTRY: light sensor error -> $e"),
      );
    } catch (e) {
      debugPrint("FACE ENTRY: light sensor tidak didukung -> $e");
    }
  }

  Future<void> _init() async {
    final user = await DatabaseService.instance.getUser();
    if (user == null) return;
    _userId = user['user_id'] as String;

    await MTCNNService().init();
    if (!MobileFaceNetService().isModelLoaded) {
      await MobileFaceNetService().init();
    }

    _refreshCount();

    if (MobileFaceNetService().hasUser(_userId!)) {
      if (mounted) {
        setState(() {
          _alreadyRegistered = true;
        });
      }
      return;
    }

    await _initCamera();
    await _checkServer();
    if (mounted) setState(() {});
  }

  void _refreshCount() {
    if (_userId == null) return;
    final svc = MobileFaceNetService();
    _savedNormalCount = svc.nonGlassesCountFor(_userId!);
    _savedGlassesCount = svc.glassesCountFor(_userId!);
  }

  Future<void> _checkServer() async {
    if (_userId == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('face_embeddings')
          .select('id')
          .eq('user_id', _userId!)
          .limit(1)
          .timeout(const Duration(seconds: 5));
      if (mounted) {
        setState(() => _importAvailable = rows.isNotEmpty);
      }
    } catch (e) {
      debugPrint("FACE ENTRY: server check error -> $e");
      if (mounted) setState(() => _importAvailable = false);
    }
  }

  Future<void> _initCamera() async {
    await _stopAndDisposeCamera();
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;

    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        front,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;

      setState(() {
        _controller = controller;
        _isCameraInitialized = true;
      });
    } catch (e) {
      debugPrint("FACE ENTRY: init kamera gagal -> $e");
    }
  }

  Future<void> _stopAndDisposeCamera() async {
    final old = _controller;
    if (old == null) return;
    _controller = null;
    _isCameraInitialized = false;
    if (mounted) setState(() {});
    try {
      await old.dispose();
    } catch (_) {}
  }

  Future<void> _capturePhoto() async {
    if (_isProcessing || !_isCameraReady) return;
    if (_userId == null) {
      _showSnack('User tidak ditemukan. Login ulang.');
      return;
    }

    final sessionUuid = _uuid.v4();
    final sessionStarted = DateTime.now();

    setState(() => _isProcessing = true);

    img.Image? alignedForPhoto;
    String? photoPath;
    int? mtcnnMs, mfnMs;
    String mtcnnStatus = 'no_face';
    String? mfnStatus;
    final mode = _glassesStage ? 'glasses' : 'non_glasses';

    try {
      final XFile file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      final captured = img.decodeImage(bytes);

      if (captured == null) {
        _setFailed('Gagal membaca gambar.');
        await _logSession(sessionUuid, sessionStarted, 'failed_no_face');
        return;
      }

      img.Image oriented =
          correctCameraRotation(captured, _controller!.description);
      if (oriented.width > 640) {
        oriented = img.copyResize(oriented, width: 640);
      }

      final tMtc = DateTime.now();
      final faces =
          await MTCNNService().detectFaces(oriented, isGlassesMode: true);
      mtcnnMs = DateTime.now().difference(tMtc).inMilliseconds;

      if (faces.isEmpty) {
        _setFailed('Wajah tidak terdeteksi. Coba lagi.');
        await _logSession(sessionUuid, sessionStarted, 'failed_no_face',
            mtcnnMs: mtcnnMs, mtcnnStatus: 'no_face');
        return;
      }
      mtcnnStatus = 'detected';

      final bestFace = faces.reduce((a, b) => a.score > b.score ? a : b);
      final aligned = MTCNNService().alignAndCropFace(oriented, bestFace);
      alignedForPhoto =
          MTCNNService().alignCropAndDrawLandmarks(oriented, bestFace);

      final tMfn = DateTime.now();
      final emb = MobileFaceNetService().predict(aligned);
      mfnMs = DateTime.now().difference(tMfn).inMilliseconds;

      if (emb == null) {
        _setFailed('Gagal proses embedding. Coba lagi.');
        await _logSession(sessionUuid, sessionStarted, 'failed_embedding',
            mtcnnMs: mtcnnMs,
            mtcnnStatus: 'detected',
            mfnMs: mfnMs,
            mfnStatus: 'skipped');
        return;
      }
      mfnStatus = 'match';

      photoPath = await _savePhotoToDisk(alignedForPhoto, sessionUuid, mode);

      await DatabaseService.instance.addEmbedding(
        userId: _userId!,
        mode: mode,
        embedding: emb,
      );
      await MobileFaceNetService().registerUser(
        _userId!,
        emb,
        sampleImage: aligned,
        mode: mode,
      );

      await _logSession(sessionUuid, sessionStarted, 'success',
          mtcnnMs: mtcnnMs,
          mtcnnStatus: 'detected',
          mfnMs: mfnMs,
          mfnStatus: 'match',
          photoPath: photoPath);

      if (mounted) {
        setState(() {
          if (_glassesStage) {
            _savedGlassesCount++;
          } else {
            _savedNormalCount++;
          }
          _lastStatus = _CaptureStatus.success;
          _isProcessing = false;
        });
      }

      await _checkProgress();
    } catch (e) {
      debugPrint("FACE ENTRY: capture error -> $e");
      _setFailed('Terjadi kesalahan. Coba lagi.');
      try {
        await _logSession(sessionUuid, sessionStarted, 'cancelled',
            mtcnnMs: mtcnnMs,
            mtcnnStatus: mtcnnStatus,
            mfnMs: mfnMs,
            mfnStatus: mfnStatus,
            photoPath: photoPath);
      } catch (_) {}
    }
  }

  void _setFailed(String msg) {
    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      _lastStatus = _CaptureStatus.failed;
    });
    _showSnack(msg);
  }

  Future<void> _checkProgress() async {
    final doneNormal = _savedNormalCount >= 3;
    final doneGlasses = _savedGlassesCount >= 3;

    if (!_useGlasses && doneNormal) {
      _finish();
      return;
    }
    if (_useGlasses && doneNormal && doneGlasses) {
      _finish();
      return;
    }
    if (_useGlasses && doneNormal && !_glassesStage) {
      await _showGlassesDialog();
    }
  }

  Future<void> _showGlassesDialog() async {
    await _stopAndDisposeCamera();
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Kenakan Kacamata'),
        content: const Text(
          '3 foto tanpa kacamata selesai. Sekarang kenakan kacamata Anda, lalu tap Lanjut.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Lanjut'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    setState(() {
      _glassesStage = true;
      _lastStatus = _CaptureStatus.none;
    });
    await _initCamera();
  }

  void _finish() async {
    await _stopAndDisposeCamera();
    SyncService().syncAll().then((r) {
      debugPrint("FACE ENTRY: post-registration sync = $r");
    });
    if (mounted) widget.onFinished?.call();
  }

  Future<String?> _savePhotoToDisk(
    img.Image image,
    String sessionUuid,
    String tag,
  ) async {
    try {
      final dir = await DatabaseService.instance.getPhotoDir();
      final userDir = Directory(p.join(dir.path, _userId!));
      if (!await userDir.exists()) await userDir.create(recursive: true);

      final filename = '${sessionUuid}_$tag.jpg';
      final fullPath = p.join(userDir.path, filename);
      final jpg = img.encodeJpg(image, quality: 75);
      await File(fullPath).writeAsBytes(jpg);
      return fullPath;
    } catch (e) {
      debugPrint("FACE ENTRY: gagal simpan foto -> $e");
      return null;
    }
  }

  Future<void> _logSession(
    String sessionUuid,
    DateTime startedAt,
    String finalStatus, {
    int? mtcnnMs,
    String? mtcnnStatus,
    int? mfnMs,
    String? mfnStatus,
    String? photoPath,
  }) async {
    if (_userId == null) return;
    try {
      await DatabaseService.instance.addSessionLog(
        sessionUuid: sessionUuid,
        userId: _userId!,
        sessionType: 'registration',
        startedAt: startedAt,
        mtcnnMsFinal: mtcnnMs,
        mfnMsFinal: mfnMs,
        finalStatus: finalStatus,
        finalAt: DateTime.now(),
        photoPath: photoPath,
        failedCount: mtcnnStatus == 'no_face' ? 1 : 0,
        luxValue: _luxValue,
      );
      if (mtcnnStatus != null) {
        await DatabaseService.instance.addFaceAttempt(
          sessionUuid: sessionUuid,
          userId: _userId!,
          attemptNumber: 1,
          attemptedAt: DateTime.now(),
          mtcnnStatus: mtcnnStatus,
          mtcnnMs: mtcnnMs,
          mfnStatus: mfnStatus,
          mfnMs: mfnMs,
          luxValue: _luxValue,
        );
      }
    } catch (e) {
      debugPrint("FACE ENTRY: gagal log session -> $e");
    }
  }

  Future<void> _importFromServer() async {
    if (_userId == null || _importing) return;

    await _stopAndDisposeCamera();
    setState(() => _importing = true);
    loadingController.show();

    try {
      final rows = await Supabase.instance.client
          .from('face_embeddings')
          .select()
          .eq('user_id', _userId!);

      if (rows.isEmpty) {
        if (mounted) {
          setState(() => _importing = false);
          await loadingController.hide();
          _showSnack('Tidak ada data wajah di server.');
          await _initCamera();
        }
        return;
      }

      await DatabaseService.instance.deleteEmbeddingsByUser(_userId!);
      MobileFaceNetService().deleteUser(_userId!);

      int ok = 0;
      for (final row in rows) {
        final mode = row['mode'] as String;
        final embRaw = row['embedding'];
        final List<double> emb;

        if (embRaw is List) {
          emb = embRaw.map((v) => (v as num).toDouble()).toList();
        } else if (embRaw is String) {
          emb = embRaw
              .replaceAll('[', '')
              .replaceAll(']', '')
              .split(',')
              .map((s) => double.tryParse(s.trim()) ?? 0.0)
              .toList();
        } else {
          continue;
        }

        final newId = await DatabaseService.instance.addEmbedding(
          userId: _userId!,
          mode: mode,
          embedding: emb,
        );
        await DatabaseService.instance.markEmbeddingSynced(newId);
        await MobileFaceNetService().registerUser(
          _userId!,
          emb,
          mode: mode,
        );
        ok++;
      }

      debugPrint("FACE ENTRY: import sukses, $ok embedding");
      if (mounted) widget.onFinished?.call();
    } catch (e) {
      debugPrint("FACE ENTRY: import error -> $e");
      if (mounted) {
        setState(() => _importing = false);
        await loadingController.hide();
        _showSnack('Gagal import. Cek koneksi lalu coba lagi.');
        await _initCamera();
      }
    }
  }

  Future<void> _confirmAndDelete() async {
    if (_userId == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus Data Wajah'),
        content: const Text(
          'Data wajah akan dihapus seluruhnya. Lanjutkan?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hapus', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    MobileFaceNetService().deleteUser(_userId!);
    await DatabaseService.instance.deleteEmbeddingsByUser(_userId!);
    MobileFaceNetService().clearMatchHistory();

    if (!mounted) return;
    setState(() {
      _alreadyRegistered = false;
      _savedNormalCount = 0;
      _savedGlassesCount = 0;
      _glassesStage = false;
      _lastStatus = _CaptureStatus.none;
    });
    await _initCamera();
    await _checkServer();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final gutter = AppSpacing.horizontal(context);
    final compact = AppSpacing.isCompact(context);
    final circleSize = compact ? 190.0 : 220.0;
    final gapTop = compact ? 12.0 : 32.0;
    final gapMid = compact ? 12.0 : 32.0;
    final gapBetween = compact ? 24.0 : 48.0;
    final gapBottom = compact ? 24.0 : 80.0;

    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: AppColors.darkSlate,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
          child: _alreadyRegistered
              ? _buildPhase2(gapBottom)
              : _buildPhase1(
                  gapTop,
                  gapMid,
                  gapBetween,
                  gapBottom,
                  circleSize,
                ),
        ),
      ),
    );
  }

  Widget _buildPhase1(
    double gapTop,
    double gapMid,
    double gapBetween,
    double gapBottom,
    double circleSize,
  ) {
    return Column(
      children: [
        Text(
          'Wajah Tersimpan $_savedCount/$_totalRequired',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.hurufSecondary,
          ),
        ),
        SizedBox(height: gapTop),
        _buildCircle(circleSize),
        SizedBox(height: gapMid),
        _buildGlassesToggle(),
        const Spacer(),
        _buildCaptureButton(),
        SizedBox(height: gapBetween),
        _buildImportButton(),
        SizedBox(height: gapBottom),
      ],
    );
  }

  Widget _buildPhase2(double gapBottom) {
    return Column(
      children: [
        const SizedBox(height: 12),
        const Icon(Icons.verified_user, size: 64, color: AppColors.tealMedium),
        const SizedBox(height: 12),
        const Text(
          'Wajah sudah terdaftar',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.darkSlate,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Hapus data terlebih dahulu untuk mendaftar ulang.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: AppColors.hurufSecondary,
          ),
        ),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton.icon(
            onPressed: _confirmAndDelete,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: const BorderSide(color: AppColors.error, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.delete_outline, size: 20),
            label: const Text(
              'Hapus Data Wajah & Ulangi',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        SizedBox(height: gapBottom),
      ],
    );
  }

  Widget _buildCircle(double size) {
    Color borderColor;
    switch (_lastStatus) {
      case _CaptureStatus.success:
        borderColor = AppColors.tealMedium;
        break;
      case _CaptureStatus.failed:
        borderColor = AppColors.maroon;
        break;
      case _CaptureStatus.none:
        borderColor = const Color(0xFF9E9E9E);
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFD9D9D9),
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: 4),
      ),
      child: ClipOval(
        child: _isCameraReady
            ? FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller!.value.previewSize!.height,
                  height: _controller!.value.previewSize!.width,
                  child: CameraPreview(_controller!),
                ),
              )
            : const Icon(Icons.videocam_off, color: Colors.white70, size: 40),
      ),
    );
  }

  Widget _buildGlassesToggle() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Expanded(
          child: Text(
            'Hidupkan Saklar Jika\nMenggunakan Kacamata',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.darkSlate,
              height: 1.3,
            ),
          ),
        ),
        Switch(
          value: _useGlasses,
          activeThumbColor: AppColors.tealMedium,
          onChanged: (_importing || _isProcessing)
              ? null
              : (val) {
                  setState(() => _useGlasses = val);
                },
        ),
      ],
    );
  }

  Widget _buildCaptureButton() {
    final enabled = _isCameraReady && !_isProcessing && !_importing;
    final label = _isProcessing ? 'Memproses...' : 'Tangkap Foto';

    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: enabled ? _capturePhoto : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.tealMedium,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.tealMedium.withValues(alpha: 0.5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.camera_alt, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildImportButton() {
    final enabled = _importAvailable && !_importing && !_isProcessing;

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton(
            onPressed: enabled ? _importFromServer : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.tealMedium,
              side: BorderSide(
                color: enabled
                    ? AppColors.tealMedium
                    : const Color(0xFFB0B0B0),
                width: 1.5,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              backgroundColor: enabled
                  ? Colors.transparent
                  : const Color(0xFFE0E0E0).withValues(alpha: 0.5),
            ),
            child: _importing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: AppSpinner(
                      size: 26,
                      color: AppColors.tealMedium,
                    ),
                  )
                : Text(
                    'Import Foto Dari Database',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? AppColors.tealMedium
                          : AppColors.hurufSecondary,
                    ),
                  ),
          ),
        ),
        if (!_importAvailable && !_importing) ...[
          const SizedBox(height: 6),
          const Text(
            'Belum ada data di server',
            style: TextStyle(fontSize: 12, color: AppColors.hurufSecondary),
          ),
        ],
      ],
    );
  }
}