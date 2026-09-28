import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import '../../config/glasses_config.dart';
import '../db/database_service.dart';
import '../debug_logger.dart';

/// Satu sampel wajah — registrasi atau learning.
class FaceEntry {
  /// ID di SQLite. `null` = registrasi baru (belum ada ID di memory).
  /// Non-null = learning (selalu ada ID dari insert).
  final int? dbId;
  final List<double> embedding;
  final String source; // 'registration' | 'learning'
  final DateTime createdAt;

  FaceEntry({
    this.dbId,
    required this.embedding,
    required this.source,
    required this.createdAt,
  });
}

/// Data wajah satu user — dipisah antara non-kacamata dan kacamata
class UserFaceData {
  final List<FaceEntry> nonGlasses;
  final List<FaceEntry> glasses;

  UserFaceData({
    List<FaceEntry>? nonGlasses,
    List<FaceEntry>? glasses,
  })  : nonGlasses = nonGlasses ?? [],
        glasses = glasses ?? [];

  int get totalSamples => nonGlasses.length + glasses.length;
  bool get hasNonGlasses => nonGlasses.isNotEmpty;
  bool get hasGlasses => glasses.isNotEmpty;
}

/// Hasil pencocokan wajah (Telemetry)
class FaceRecognitionResult {
  final String? userId;
  final double distance;
  final bool isRecognized;
  final double similarity;
  final int totalRegisteredCount;
  final bool hasGlasses;
  final String matchMode; // 'non_glasses' | 'glasses' | 'none'

  FaceRecognitionResult({
    this.userId,
    required this.distance,
    required this.isRecognized,
    this.similarity = 0.0,
    this.totalRegisteredCount = 0,
    this.hasGlasses = false,
    this.matchMode = 'none',
  });

  String? get label => userId ?? "Tidak Diketahui";
  String? get closestName => userId;
  double get minDistance => distance;
  bool get isMatch => isRecognized;
}

/// Entri riwayat percobaan absen
class MatchAttempt {
  final Uint8List thumbnailPng;
  final double distance;
  final bool isMatch;
  final String? matchedName;
  final DateTime timestamp;
  final String matchMode;

  MatchAttempt({
    required this.thumbnailPng,
    required this.distance,
    required this.isMatch,
    required this.matchedName,
    required this.timestamp,
    this.matchMode = 'none',
  });
}

class MobileFaceNetService {
  static final MobileFaceNetService _instance = MobileFaceNetService._internal();
  factory MobileFaceNetService() => _instance;
  MobileFaceNetService._internal();

  Interpreter? _interpreter;
  bool _isModelLoaded = false;
  bool get isModelLoaded => _isModelLoaded;

  // Map<userId, UserFaceData>
  final Map<String, UserFaceData> _registeredUsers = {};
  Map<String, UserFaceData> get registeredUsers => _registeredUsers;

  final Map<String, List<Uint8List>> _registeredThumbnails = {};
  Map<String, List<Uint8List>> get registeredThumbnails => _registeredThumbnails;

  static const int _maxHistoryEntries = 40;
  final List<MatchAttempt> _matchHistory = [];
  List<MatchAttempt> get matchHistory => List.unmodifiable(_matchHistory.reversed);

  bool _isPredicting = false;

  Future<void> init([String modelPath = 'assets/models/mobilefacenet.tflite']) async {
    if (_isModelLoaded && _interpreter != null) return;
    try {
      final byteData = await rootBundle.load(modelPath);
      final buffer = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      final options = InterpreterOptions()..threads = 4;
      _interpreter = Interpreter.fromBuffer(buffer, options: options);
      _isModelLoaded = true;
      debugPrint("DEBUG_MOBILEFACENET: Model BERHASIL dimuat.");
    } catch (e, stackTrace) {
      _isModelLoaded = false;
      _interpreter = null;
      debugPrint("DEBUG_MOBILEFACENET_ERROR: Gagal memuat model -> $e");
      debugPrint(stackTrace.toString());
    }
  }

  List<double>? predictEmbedding(img.Image faceImage) {
    if (_interpreter == null) {
      debugPrint("DEBUG_MOBILEFACENET_ERROR: Interpreter belum diinisialisasi!");
      return null;
    }

    double variance = _pixelVariance(faceImage);
    debugPrint("DEBUG_FACE_VARIANCE: $variance");
    if (variance < 10.0) {
      debugPrint("DEBUG_MOBILEFACENET_WARNING: Gambar wajah terlalu rata/kosong.");
      return null;
    }

    if (_isPredicting) {
      debugPrint("DEBUG_MOBILEFACENET: predictEmbedding dilewati.");
      return null;
    }
    _isPredicting = true;

    try {
      img.Image normalizedImage = _normalizeBrightness(faceImage);

      img.Image resizedImage = (normalizedImage.width == 96 && normalizedImage.height == 112)
          ? normalizedImage
          : img.copyResize(normalizedImage, width: 96, height: 112);

      var input = _imageToByteListFloat32(resizedImage).reshape([1, 112, 96, 3]);
      var output = List.generate(1, (_) => List.filled(128, 0.0));

      _interpreter!.run(input, output);

      List<double> normalizedResult = _l2Normalize(List<double>.from(output[0]));
      debugPrint("DEBUG_EMBEDDING_SAMPLE: ${normalizedResult.take(5).toList()} (Panjang: ${normalizedResult.length})");

      return normalizedResult;
    } catch (e, stackTrace) {
      debugPrint("DEBUG_MOBILEFACENET_ERROR: Gagal inferensi TFLite -> $e");
      debugPrint(stackTrace.toString());
      return null;
    } finally {
      _isPredicting = false;
    }
  }

  double _pixelVariance(img.Image image) {
    double sum = 0;
    double sumSq = 0;
    int count = 0;
    for (int y = 0; y < image.height; y += 4) {
      for (int x = 0; x < image.width; x += 4) {
        var p = image.getPixel(x, y);
        double gray = (p.r + p.g + p.b) / 3.0;
        sum += gray;
        sumSq += gray * gray;
        count++;
      }
    }
    if (count == 0) return 0;
    double mean = sum / count;
    return (sumSq / count) - (mean * mean);
  }

  img.Image _normalizeBrightness(img.Image image, {double targetMean = 128.0}) {
    double sum = 0;
    int count = 0;
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        var p = image.getPixel(x, y);
        sum += (p.r + p.g + p.b) / 3.0;
        count++;
      }
    }
    if (count == 0) return image;
    double currentMean = sum / count;
    if (currentMean <= 1.0) return image;

    double gain = (targetMean / currentMean).clamp(0.4, 2.8);
    if ((gain - 1.0).abs() < 0.03) return image;

    img.Image output = img.Image(width: image.width, height: image.height);
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        var p = image.getPixel(x, y);
        int r = (p.r * gain).round().clamp(0, 255);
        int g = (p.g * gain).round().clamp(0, 255);
        int b = (p.b * gain).round().clamp(0, 255);
        output.setPixelRgb(x, y, r, g, b);
      }
    }
    return output;
  }

  List<double>? predict(img.Image faceImage) => predictEmbedding(faceImage);

  /// Registrasi embedding ke grup yang sesuai
  /// [mode] = 'non_glasses' atau 'glasses'
  Future<void> registerUser(
    String userId,
    List<double> embedding, {
    img.Image? sampleImage,
    String mode = 'non_glasses',
  }) async {
    final data = _registeredUsers.putIfAbsent(userId, () => UserFaceData());
    final entry = FaceEntry(
      dbId: null,
      embedding: embedding,
      source: 'registration',
      createdAt: DateTime.now(),
    );

    if (mode == 'glasses') {
      data.glasses.add(entry);
    } else {
      data.nonGlasses.add(entry);
    }

    if (sampleImage != null) {
      try {
        final png = Uint8List.fromList(img.encodePng(sampleImage));
        _registeredThumbnails.putIfAbsent(userId, () => []).add(png);
      } catch (e) {
        debugPrint("DEBUG_MOBILEFACENET: Gagal encode thumbnail -> $e");
      }
    }
  }

  /// Load semua embedding dari SQLite lokal ke memory.
  /// Dipanggil setelah login / app restart.
  Future<void> loadFromDatabase() async {
    try {
      final user = await DatabaseService.instance.getUser();
      if (user == null) {
        debugPrint("MFN load: user tidak ada di SQLite");
        return;
      }

      final userId = user['user_id'] as String;
      final rows = await DatabaseService.instance.getEmbeddings(userId: userId);

      _registeredUsers.clear();
      _registeredThumbnails.clear();

      for (final row in rows) {
        final mode = row['mode'] as String;
        final embRaw = jsonDecode(row['embedding'] as String) as List;
        final emb = embRaw.map((v) => (v as num).toDouble()).toList();

        final entry = FaceEntry(
          dbId: row['id'] as int?,
          embedding: emb,
          source: (row['source'] as String?) ?? 'registration',
          createdAt: DateTime.tryParse(
                (row['created_at'] as String?) ?? '',
              ) ??
              DateTime.now(),
        );

        final data = _registeredUsers.putIfAbsent(userId, () => UserFaceData());
        if (mode == 'glasses') {
          data.glasses.add(entry);
        } else {
          data.nonGlasses.add(entry);
        }
      }

      debugPrint("MFN load: ${rows.length} embedding untuk user $userId");
    } catch (e) {
      debugPrint("MFN load ERROR: $e");
    }
  }

  /// CASCADING: coba non-glasses dulu (strict), lalu glasses (loose)
  FaceRecognitionResult recognize(List<double> targetEmbedding, {bool hasGlasses = false}) {
    if (_registeredUsers.isEmpty) {
      return FaceRecognitionResult(
        userId: null,
        distance: 99.0,
        isRecognized: false,
        totalRegisteredCount: 0,
        hasGlasses: hasGlasses,
        matchMode: 'none',
      );
    }

    // === STEP 1: coba ke non-glasses dataset (threshold strict) ===
    String? bestIdStep1;
    double minDistStep1 = double.infinity;

    _registeredUsers.forEach((id, data) {
      for (final entry in data.nonGlasses) {
        double dist = _euclideanDistance(targetEmbedding, entry.embedding);
        if (dist < minDistStep1) {
          minDistStep1 = dist;
          bestIdStep1 = id;
        }
      }
    });

    if (minDistStep1 <= GlassesConfig.strictThreshold) {
      debugPrint("MATCH DEBUG -> STEP1 (non-glasses) distance=${minDistStep1.toStringAsFixed(4)}, "
          "userId=$bestIdStep1, threshold=${GlassesConfig.strictThreshold}");
      return FaceRecognitionResult(
        userId: bestIdStep1,
        distance: minDistStep1,
        isRecognized: true,
        similarity: max(0.0, 1.0 - (minDistStep1 / GlassesConfig.strictThreshold)),
        totalRegisteredCount: _registeredUsers.length,
        hasGlasses: hasGlasses,
        matchMode: 'non_glasses',
      );
    }

    // === STEP 2: coba ke glasses dataset (threshold loose) ===
    String? bestIdStep2;
    double minDistStep2 = double.infinity;

    _registeredUsers.forEach((id, data) {
      for (final entry in data.glasses) {
        double dist = _euclideanDistance(targetEmbedding, entry.embedding);
        if (dist < minDistStep2) {
          minDistStep2 = dist;
          bestIdStep2 = id;
        }
      }
    });

    if (minDistStep2 <= GlassesConfig.looseThreshold) {
      debugPrint("MATCH DEBUG -> STEP2 (glasses) distance=${minDistStep2.toStringAsFixed(4)}, "
          "userId=$bestIdStep2, threshold=${GlassesConfig.looseThreshold}");
      return FaceRecognitionResult(
        userId: bestIdStep2,
        distance: minDistStep2,
        isRecognized: true,
        similarity: max(0.0, 1.0 - (minDistStep2 / GlassesConfig.looseThreshold)),
        totalRegisteredCount: _registeredUsers.length,
        hasGlasses: hasGlasses,
        matchMode: 'glasses',
      );
    }

    // === STEP 3: gagal dua-duanya ===
    final finalDist = min(minDistStep1, minDistStep2);
    final finalId = minDistStep1 <= minDistStep2 ? bestIdStep1 : bestIdStep2;

    debugPrint("MATCH DEBUG -> GAGAL. step1=${minDistStep1.toStringAsFixed(4)} "
        "(th=${GlassesConfig.strictThreshold}), "
        "step2=${minDistStep2.toStringAsFixed(4)} (th=${GlassesConfig.looseThreshold})");

    return FaceRecognitionResult(
      userId: finalId,
      distance: finalDist,
      isRecognized: false,
      similarity: 0.0,
      totalRegisteredCount: _registeredUsers.length,
      hasGlasses: hasGlasses,
      matchMode: 'none',
    );
  }

  FaceRecognitionResult evaluateFace(List<double> targetEmbedding, {bool hasGlasses = false}) =>
      recognize(targetEmbedding, hasGlasses: hasGlasses);

  double _euclideanDistance(List<double> e1, List<double> e2) {
    double sum = 0.0;
    int length = min(e1.length, e2.length);
    for (int i = 0; i < length; i++) {
      double diff = e1[i] - e2[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }

  List<double> _l2Normalize(List<double> v) {
    double sumSq = 0.0;
    for (var x in v) {
      sumSq += x * x;
    }
    double norm = sqrt(sumSq);
    if (norm == 0) return v;
    return v.map((e) => e / norm).toList();
  }

  Float32List _imageToByteListFloat32(img.Image image) {
    var convertedBytes = Float32List(1 * 112 * 96 * 3);
    int pixelIndex = 0;
    for (var y = 0; y < 112; y++) {
      for (var x = 0; x < 96; x++) {
        var pixel = image.getPixel(x, y);
        convertedBytes[pixelIndex++] = (pixel.r - 127.5) / 128.0;
        convertedBytes[pixelIndex++] = (pixel.g - 127.5) / 128.0;
        convertedBytes[pixelIndex++] = (pixel.b - 127.5) / 128.0;
      }
    }
    return convertedBytes;
  }

  void recordAttempt({
    required img.Image faceImage,
    required FaceRecognitionResult telemetry,
  }) {
    try {
      final png = Uint8List.fromList(img.encodePng(faceImage));
      _matchHistory.add(MatchAttempt(
        thumbnailPng: png,
        distance: telemetry.distance,
        isMatch: telemetry.isRecognized,
        matchedName: telemetry.closestName,
        timestamp: DateTime.now(),
        matchMode: telemetry.matchMode,
      ));
      if (_matchHistory.length > _maxHistoryEntries) {
        _matchHistory.removeAt(0);
      }
    } catch (e) {
      debugPrint("DEBUG_MOBILEFACENET: Gagal catat riwayat -> $e");
    }
  }

  Future<bool> addLearningEmbedding(
    String userId,
    List<double> embedding, {
    required String mode,
    double? matchDistance,
  }) async {
    try {
      // 1. Cek duplikat.
      final existing = _registeredUsers[userId];
      if (existing != null) {
        final pool = <List<double>>[
          ...existing.nonGlasses.map((e) => e.embedding),
          ...existing.glasses.map((e) => e.embedding),
        ];
        for (final old in pool) {
          final d = _euclideanDistance(embedding, old);
          if (d < 0.3) {
            debugPrint("MFN learn: duplikat (d=${d.toStringAsFixed(4)}), skip");
            return false;
          }
        }
      }

      // 2. Cek batas 30. Kalau penuh, hapus yang paling lama (DB + memory).
      final count = await DatabaseService.instance.countLearningEmbeddings(userId);
      if (count >= 30) {
        final oldestId = await DatabaseService.instance.getOldestLearningEmbeddingId(userId);
        if (oldestId != null) {
          await DatabaseService.instance.deleteEmbeddingById(oldestId);

          // Self-heal: hapus dari memory juga.
          final data = _registeredUsers[userId];
          if (data != null) {
            final beforeLen = data.glasses.length + data.nonGlasses.length;
            data.glasses.removeWhere((e) => e.dbId == oldestId);
            data.nonGlasses.removeWhere((e) => e.dbId == oldestId);
            final afterLen = data.glasses.length + data.nonGlasses.length;
            if (beforeLen == afterLen) {
              debugPrint("MFN learn: WARNING oldestId=$oldestId tidak ada di memory");
            }
          }
          debugPrint("MFN learn: max 30, hapus id=$oldestId (FIFO)");
        }
      }

      // 3. Simpan ke DB, tangkap ID-nya.
      final newId = await DatabaseService.instance.addEmbedding(
        userId: userId,
        mode: mode,
        embedding: embedding,
        source: 'learning',
      );

      // 4. Tambah ke memory dengan ID yang sama.
      final entry = FaceEntry(
        dbId: newId,
        embedding: embedding,
        source: 'learning',
        createdAt: DateTime.now(),
      );
      final data = _registeredUsers.putIfAbsent(userId, () => UserFaceData());
      if (mode == 'glasses') {
        data.glasses.add(entry);
      } else {
        data.nonGlasses.add(entry);
      }

      // 5. Log ke file terpisah.
      final label = mode == 'glasses' ? 'loose' : 'strict';
      final first5 = embedding
          .take(5)
          .map((v) => v.toStringAsFixed(4))
          .join(', ');
      final totalBaru = count + 1;
      await DebugLogger.instance.appendLearning(
        'added mode=$label d=${matchDistance?.toStringAsFixed(4) ?? "?"} '
        'total=$totalBaru first5=[$first5]',
      );

      debugPrint("MFN learn: tambah embedding ($label), total=$totalBaru");
      return true;
    } catch (e) {
      debugPrint("MFN learn: error -> $e");
      return false;
    }
  }

  void deleteUser(String userId) {
    _registeredUsers.remove(userId);
    _registeredThumbnails.remove(userId);
  }

  void clearAllUsers() {
    _registeredUsers.clear();
    _registeredThumbnails.clear();
  }

  void clearMatchHistory() {
    _matchHistory.clear();
  }

  bool hasUser(String userId) => _registeredUsers.containsKey(userId);
  int sampleCountFor(String userId) => _registeredUsers[userId]?.totalSamples ?? 0;
  int nonGlassesCountFor(String userId) => _registeredUsers[userId]?.nonGlasses.length ?? 0;
  int glassesCountFor(String userId) => _registeredUsers[userId]?.glasses.length ?? 0;
}