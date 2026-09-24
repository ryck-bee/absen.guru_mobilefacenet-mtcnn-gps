import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../services/db/database_service.dart';
import '../../services/db/sync_service.dart';
import '../../services/model/mobilefacenet_service.dart';
import '../../services/model/mtcnn_service.dart';
import '../../utils/camera_image_utils.dart';

class FaceListScreen extends StatefulWidget {
  final bool isActive;
  final VoidCallback? onFinished;

  const FaceListScreen({
    super.key,
    required this.isActive,
    this.onFinished,
  });

  @override
  State<FaceListScreen> createState() => _FaceListScreenState();
}

enum RegistrationStage { normalSession, glassesSession, completed }

class _FaceListScreenState extends State<FaceListScreen> {
  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  bool _alreadyRegistered = false;

  bool _useGlasses = false;
  RegistrationStage _currentStage = RegistrationStage.normalSession;

  int _savedNormalCount = 0;
  int _savedGlassesCount = 0;

  String _hintMessage = "Bersiap...";
  String? _userId;

  static const _uuid = Uuid();

  bool get _isCameraReady =>
      _isCameraInitialized &&
      _controller != null &&
      _controller!.value.isInitialized;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) {
      _loadAndInit();
    }
  }

  Future<void> _loadAndInit() async {
    final user = await DatabaseService.instance.getUser();
    if (user == null) {
      setState(() {
        _hintMessage = "User tidak ditemukan. Silakan login ulang.";
      });
      return;
    }

    _userId = user['user_id'] as String;

    if (MobileFaceNetService().hasUser(_userId!)) {
      setState(() {
        _alreadyRegistered = true;
        _hintMessage = "Wajah sudah terdaftar. Hapus data untuk mendaftar ulang.";
      });
      return;
    }

    setState(() {
      _alreadyRegistered = false;
      _hintMessage = "Memuat model...";
    });
    await MTCNNService().init();
    if (!MobileFaceNetService().isModelLoaded) {
      await MobileFaceNetService().init();
    }
    await _initCamera();
  }

  @override
  void didUpdateWidget(covariant FaceListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _loadAndInit();
    } else if (!widget.isActive && oldWidget.isActive) {
      _stopAndDisposeCamera();
    }
  }

  /// Simpan foto ke folder app. Return path lengkap atau null.
  Future<String?> _savePhotoToDisk(img.Image image, String sessionUuid, String tag) async {
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
      debugPrint("REG: gagal simpan foto -> $e");
      return null;
    }
  }

  Future<void> _takePhoto() async {
    if (_isProcessing || _controller == null || !_controller!.value.isInitialized) return;
    if (_userId == null) {
      _showError("User tidak ditemukan. Silakan login ulang.");
      return;
    }

    final DateTime sessionStarted = DateTime.now();
    final String sessionUuid = _uuid.v4();

    setState(() {
      _isProcessing = true;
      _hintMessage = "Mengambil foto...";
    });

    int? mtcnnMs;
    int? mfnMs;
    DateTime? mtcnnDoneAt;
    DateTime? mfnDoneAt;
    String mtcnnStatus = 'no_face';
    String? mfnStatus;
    double? matchDistance;
    String finalStatus = 'failed_no_face';
    String? photoPath;
    img.Image? alignedForPhoto;

    try {
      // ===== Capture =====
      final XFile file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      img.Image? capturedImage = img.decodeImage(bytes);

      if (capturedImage == null) {
        _showError("Gagal membaca gambar dari kamera.");
        await _logSession(
          sessionUuid: sessionUuid,
          startedAt: sessionStarted,
          finalStatus: 'failed_no_face',
          mtcnnStatus: 'no_face',
        );
        return;
      }

      img.Image orientedImage = correctCameraRotation(capturedImage, _controller!.description);

      img.Image rgbImage = orientedImage.width > 640
          ? img.copyResize(orientedImage, width: 640)
          : orientedImage;

      bool isGlassesMode = (_currentStage == RegistrationStage.glassesSession);
      String stageName = isGlassesMode ? "Kacamata" : "Biasa (Tanpa Kacamata)";
      String mode = isGlassesMode ? 'glasses' : 'non_glasses';

      // ===== MTCNN =====
      setState(() => _hintMessage = "Mendeteksi wajah...");
      final DateTime tMtcStart = DateTime.now();
      final faces = await MTCNNService().detectFaces(
        rgbImage,
        isGlassesMode: true,
      );
      mtcnnMs = DateTime.now().difference(tMtcStart).inMilliseconds;
      mtcnnDoneAt = DateTime.now();

      if (faces.isEmpty) {
        debugPrint("REG: MTCNN tidak mendeteksi wajah (${mtcnnMs}ms)");
        await _logSession(
          sessionUuid: sessionUuid,
          startedAt: sessionStarted,
          mtcnnDoneAt: mtcnnDoneAt,
          mtcnnMs: mtcnnMs,
          mtcnnStatus: 'no_face',
          finalStatus: 'failed_no_face',
        );
        _showError("Wajah tidak terdeteksi. Posisikan wajah di lingkaran dan coba lagi.");
        return;
      }

      mtcnnStatus = 'detected';

      final bestFace = faces.reduce((a, b) => a.score > b.score ? a : b);

      setState(() => _hintMessage = "Memproses wajah...");
      img.Image aligned = MTCNNService().alignAndCropFace(rgbImage, bestFace);
      alignedForPhoto = MTCNNService().alignCropAndDrawLandmarks(rgbImage, bestFace);

      // ===== MobileFaceNet =====
      final DateTime tMfn = DateTime.now();
      List<double>? emb = MobileFaceNetService().predict(aligned);
      mfnMs = DateTime.now().difference(tMfn).inMilliseconds;
      mfnDoneAt = DateTime.now();

      if (emb == null) {
        debugPrint("REG: MFN gagal prediksi (${mfnMs}ms)");
        await _logSession(
          sessionUuid: sessionUuid,
          startedAt: sessionStarted,
          mtcnnDoneAt: mtcnnDoneAt,
          mtcnnMs: mtcnnMs,
          mtcnnStatus: 'detected',
          mfnDoneAt: mfnDoneAt,
          mfnMs: mfnMs,
          mfnStatus: 'skipped',
          finalStatus: 'failed_embedding',
        );
        _showError("Gagal memproses embedding. Silakan ambil foto ulang.");
        return;
      }

      mfnStatus = 'match';

      // ===== Simpan foto ke disk =====
      photoPath = await _savePhotoToDisk(alignedForPhoto!, sessionUuid, mode);

      // ===== Simpan embedding ke SQLite =====
      await DatabaseService.instance.addEmbedding(
        userId: _userId!,
        mode: mode,
        embedding: emb,
      );

      // ===== Simpan ke memory juga =====
      await MobileFaceNetService().registerUser(
        _userId!,
        emb,
        sampleImage: aligned,
        mode: mode,
      );

      finalStatus = 'success';

      // ===== Log session + face attempt sukses =====
      await _logSession(
        sessionUuid: sessionUuid,
        startedAt: sessionStarted,
        mtcnnDoneAt: mtcnnDoneAt,
        mtcnnMs: mtcnnMs,
        mtcnnStatus: 'detected',
        mfnDoneAt: mfnDoneAt,
        mfnMs: mfnMs,
        mfnStatus: 'match',
        finalStatus: 'success',
        photoPath: photoPath,
      );

      if (isGlassesMode) {
        _savedGlassesCount++;
      } else {
        _savedNormalCount++;
      }

      debugPrint("[REGISTRASI] Foto Stage $stageName BERHASIL DISIMPAN. "
          "Total valid stage ini: ${isGlassesMode ? _savedGlassesCount : _savedNormalCount}, "
          "MTCNN=${mtcnnMs}ms, MFN=${mfnMs}ms, "
          "mode: $mode, user: $_userId, session: $sessionUuid");

      _evaluateStageProgress(isGlassesMode);

    } catch (e) {
      debugPrint("Error capture photo: $e");
      // Log kalau belum sempat log
      try {
        await _logSession(
          sessionUuid: sessionUuid,
          startedAt: sessionStarted,
          mtcnnDoneAt: mtcnnDoneAt,
          mtcnnMs: mtcnnMs,
          mtcnnStatus: mtcnnStatus,
          mfnDoneAt: mfnDoneAt,
          mfnMs: mfnMs,
          mfnStatus: mfnStatus,
          finalStatus: 'cancelled',
          photoPath: photoPath,
        );
      } catch (_) {}
      _showError("Terjadi kesalahan saat mengambil foto.");
    }
  }

  /// Helper: simpan session log + face attempt (kalau ada attempt MTCNN).
  Future<void> _logSession({
    required String sessionUuid,
    required DateTime startedAt,
    DateTime? mtcnnDoneAt,
    int? mtcnnMs,
    String? mtcnnStatus,
    DateTime? mfnDoneAt,
    int? mfnMs,
    String? mfnStatus,
    required String finalStatus,
    String? photoPath,
  }) async {
    if (_userId == null) return;
    final now = DateTime.now();

    try {
      await DatabaseService.instance.addSessionLog(
        sessionUuid: sessionUuid,
        userId: _userId!,
        sessionType: 'registration',
        startedAt: startedAt,
        mtcnnMsFinal: mtcnnMs,
        mfnMsFinal: mfnMs,
        finalStatus: finalStatus,
        finalAt: now,
        photoPath: photoPath,
        failedCount: mtcnnStatus == 'no_face' ? 1 : 0,
      );

      if (mtcnnStatus != null) {
        await DatabaseService.instance.addFaceAttempt(
          sessionUuid: sessionUuid,
          userId: _userId!,
          attemptNumber: 1,
          attemptedAt: mtcnnDoneAt ?? now,
          mtcnnStatus: mtcnnStatus,
          mtcnnMs: mtcnnMs,
          mfnStatus: mfnStatus,
          mfnMs: mfnMs,
          matchDistance: null,
        );
      }
    } catch (e) {
      debugPrint("REG: gagal simpan session log -> $e");
    }
  }

  void _evaluateStageProgress(bool isGlassesMode) {
    if (!isGlassesMode) {
      if (_savedNormalCount >= 3) {
        if (_useGlasses) {
          setState(() {
            _isProcessing = false;
            _currentStage = RegistrationStage.glassesSession;
            _hintMessage = "3 foto biasa valid tersimpan! Sekarang kenakan kacamata Anda, lalu ambil 3 foto kacamata.";
          });
        } else {
          _completeRegistration("Pendaftaran berhasil! Total 3 foto biasa telah disimpan.");
        }
      } else {
        setState(() {
          _isProcessing = false;
          _hintMessage = "Berhasil! Kumpulkan $_savedNormalCount/3 foto biasa.";
        });
      }
    } else {
      if (_savedGlassesCount >= 3) {
        _completeRegistration("Pendaftaran berhasil! Total tersimpan: 3 foto biasa + 3 foto kacamata.");
      } else {
        setState(() {
          _isProcessing = false;
          _hintMessage = "Berhasil! Kumpulkan $_savedGlassesCount/3 foto kacamata.";
        });
      }
    }
  }

  void _completeRegistration(String successMessage) async {
    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      _currentStage = RegistrationStage.completed;
      _hintMessage = successMessage;
    });
    await _stopAndDisposeCamera();

    SyncService().syncAll().then((r) {
      debugPrint("REGISTRASI: sync result = $r");
    });
  }

  String _getInstructionMessage() {
    if (_currentStage == RegistrationStage.normalSession) {
      return "Ambil Foto Sampel ($_savedNormalCount/3) - Tanpa Kacamata";
    } else if (_currentStage == RegistrationStage.glassesSession) {
      return "Ambil Foto Sampel ($_savedGlassesCount/3) - Dengan Kacamata";
    }
    return "Pendaftaran Selesai";
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      _hintMessage = message;
    });
  }

  Future<void> _initCamera() async {
    await _stopAndDisposeCamera();
    await Future.delayed(const Duration(milliseconds: 250));

    if (!mounted) return;

    try {
      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await controller.initialize();
      if (!mounted) return;

      setState(() {
        _controller = controller;
        _isCameraInitialized = true;
        _hintMessage = _getInstructionMessage();
      });
    } catch (e) {
      debugPrint("Gagal init kamera: $e");
    }
  }

  Future<void> _stopAndDisposeCamera() async {
    final oldController = _controller;
    if (oldController == null) return;

    _controller = null;
    _isCameraInitialized = false;

    if (mounted) setState(() {});

    try {
      await oldController.dispose();
    } catch (e) {
      debugPrint("Error dispose camera: $e");
    }
  }

  Future<void> _confirmAndDeleteData() async {
    if (_userId == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Hapus Data Wajah"),
        content: const Text(
          "Data wajah akan dihapus seluruhnya (termasuk di cloud saat sync nanti). Lanjutkan?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Batal"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Hapus", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    MobileFaceNetService().deleteUser(_userId!);
    await DatabaseService.instance.deleteEmbeddingsByUser(_userId!);
    MobileFaceNetService().clearMatchHistory();

    setState(() {
      _savedNormalCount = 0;
      _savedGlassesCount = 0;
      _currentStage = RegistrationStage.normalSession;
      _alreadyRegistered = false;
      _isProcessing = false;
      _hintMessage = "Data dihapus. Bersiap mendaftar ulang...";
    });

    await _loadAndInit();
  }

  @override
  void dispose() {
    _stopAndDisposeCamera();
    super.dispose();
  }

  // ============================================================
  // BUILD (sama seperti sebelumnya)
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final hasExistingData = _userId != null && MobileFaceNetService().hasUser(_userId!);
    final bool isCompleted = _currentStage == RegistrationStage.completed;

    return Scaffold(
      appBar: AppBar(title: const Text("Pendaftaran Wajah (3 Foto)")),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              const SizedBox(height: 12),
              if (_alreadyRegistered) ...[
                const SizedBox(height: 24),
                const Icon(Icons.verified_user, size: 64, color: Colors.green),
                const SizedBox(height: 12),
                const Text(
                  "Wajah sudah terdaftar",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  "Hapus data terlebih dahulu untuk mendaftar ulang.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _useGlasses ? Icons.visibility : Icons.person,
                            color: _useGlasses ? Colors.green : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _useGlasses ? "Mode + Kacamata" : "Mode Tanpa Kacamata",
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      Switch(
                        value: _useGlasses,
                        activeThumbColor: Colors.green,
                        onChanged: (_currentStage != RegistrationStage.normalSession || _savedNormalCount > 0)
                            ? null
                            : (val) {
                                setState(() {
                                  _useGlasses = val;
                                  _hintMessage = _getInstructionMessage();
                                });
                              },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildStageBadge(
                      "Biasa: $_savedNormalCount/3 Valid",
                      _currentStage == RegistrationStage.normalSession,
                      _savedNormalCount >= 3,
                    ),
                    if (_useGlasses) ...[
                      const SizedBox(width: 8),
                      _buildStageBadge(
                        "Kacamata: $_savedGlassesCount/3 Valid",
                        _currentStage == RegistrationStage.glassesSession,
                        _savedGlassesCount >= 3,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),

                Center(
                  child: SizedBox(
                    width: 260,
                    height: 260,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        ClipOval(
                          child: Container(
                            width: 260,
                            height: 260,
                            color: Colors.black,
                            child: !_isCameraReady
                                ? const Icon(Icons.videocam_off, size: 50, color: Colors.white54)
                                : FittedBox(
                                    fit: BoxFit.cover,
                                    child: SizedBox(
                                      width: _controller!.value.previewSize!.height,
                                      height: _controller!.value.previewSize!.width,
                                      child: CameraPreview(_controller!),
                                    ),
                                  ),
                          ),
                        ),
                        IgnorePointer(
                          child: Container(
                            width: 260,
                            height: 260,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isCompleted ? Colors.green : Colors.white54,
                                width: 4,
                              ),
                            ),
                          ),
                        ),
                        if (_isProcessing)
                          const CircularProgressIndicator(color: Colors.white),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  onPressed: (_isProcessing || isCompleted || _alreadyRegistered)
                      ? null
                      : _takePhoto,
                  icon: const Icon(Icons.camera_alt, size: 24),
                  label: Text(
                    _isProcessing ? "Memproses..." : "Ambil Foto Wajah",
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),

                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: isCompleted ? Colors.green.shade50 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isCompleted ? Colors.green : Colors.grey.shade400,
                    ),
                  ),
                  child: Text(
                    _hintMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isCompleted ? Colors.green.shade800 : Colors.black87,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (isCompleted)
                  ElevatedButton.icon(
                    onPressed: widget.onFinished,
                    icon: const Icon(Icons.check),
                    label: const Text("Selesai & Kembali"),
                  ),
              ],
              const SizedBox(height: 12),
              if (hasExistingData || isCompleted || _savedNormalCount > 0)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: _confirmAndDeleteData,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text("Hapus Data Wajah & Ulangi"),
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStageBadge(String label, bool isActive, bool isPassed) {
    Color bg = Colors.grey.shade200;
    Color border = Colors.grey.shade400;
    Color text = Colors.grey.shade700;

    if (isPassed) {
      bg = Colors.green.shade100;
      border = Colors.green;
      text = Colors.green.shade900;
    } else if (isActive) {
      bg = Colors.orange.shade100;
      border = Colors.orange;
      text = Colors.orange.shade900;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: (isActive || isPassed) ? FontWeight.bold : FontWeight.normal,
          color: text,
        ),
      ),
    );
  }
}