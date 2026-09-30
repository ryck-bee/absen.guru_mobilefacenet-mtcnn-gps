import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../config/app_colors.dart';
import '../../config/app_spacing.dart';
import '../../services/db/database_service.dart';
import '../../services/gps/gps_service.dart';
import '../../services/model/mobilefacenet_service.dart';
import '../../services/model/mtcnn_service.dart';
import '../../main.dart';

class TestScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const TestScreen({super.key, required this.cameras});

  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _FaceProcessResult {
  final int? mtcnnMs;
  final int? mfnMs;
  _FaceProcessResult(this.mtcnnMs, this.mfnMs);
}

class _TestScreenState extends State<TestScreen> {
  bool _running = false;
  String _progress = '';
  String? _result;
  int _perPhoto = 10;

  static const _positives = [
    'assets/benchmark/sample1.jpg',
    'assets/benchmark/sample2.jpg',
    'assets/benchmark/sample3.jpg',
  ];
  static const _negatives = [
    'assets/benchmark/neg1.jpg',
  ];

  // ============================================================
  // FACE SPEED BENCHMARK
  // ============================================================
  Future<void> _runFaceBenchmark(int perPhoto) async {
    setState(() {
      _running = true;
      _progress = 'Memuat model...';
      _result = null;
    });

    try {
      await MTCNNService().init();
      if (!MobileFaceNetService().isModelLoaded) {
        await MobileFaceNetService().init();
      }

      final photos = <img.Image>[];
      for (final a in _positives) {
        try {
          final data = await rootBundle.load(a);
          final decoded = img.decodeImage(data.buffer.asUint8List());
          if (decoded != null) photos.add(decoded);
        } catch (_) {}
      }

      if (photos.isEmpty) {
        setState(() {
          _running = false;
          _progress = '';
          _result = 'Tidak ada foto valid di assets/benchmark/';
        });
        return;
      }

      final allMtcnn = <int>[];
      final allMfn = <int>[];
      final allTotal = <int>[];
      int detectSuccess = 0;
      int detectTotal = 0;
      final perPhotoResults = <Map<String, dynamic>>[];

      for (int i = 0; i < photos.length; i++) {
        setState(() => _progress = 'Foto ${i + 1}/${photos.length} — warmup...');

        final photo = photos[i];

        for (int w = 0; w < 3; w++) {
          await _processOne(photo);
        }

        final photoMtcnn = <int>[];
        final photoMfn = <int>[];
        final photoTotal = <int>[];

        for (int it = 0; it < perPhoto; it++) {
          setState(() => _progress =
              'Foto ${i + 1}/${photos.length} — iterasi ${it + 1}/$perPhoto');

          final t0 = DateTime.now();
          final r = await _processOne(photo);
          final t1 = DateTime.now();
          final total = t1.difference(t0).inMilliseconds;

          detectTotal++;
          if (r.mtcnnMs != null && r.mfnMs != null) {
            detectSuccess++;
            photoMtcnn.add(r.mtcnnMs!);
            photoMfn.add(r.mfnMs!);
            photoTotal.add(total);
            allMtcnn.add(r.mtcnnMs!);
            allMfn.add(r.mfnMs!);
            allTotal.add(total);
          }
        }

        perPhotoResults.add({
          'photo': i + 1,
          'mtcnn_avg': _avg(photoMtcnn),
          'mfn_avg': _avg(photoMfn),
          'total_avg': _avg(photoTotal),
          'success': photoTotal.length,
          'iterations': perPhoto,
        });
      }

      final stats = <String, dynamic>{
        'photos': photos.length,
        'per_photo_iterations': perPhoto,
        'warmup_per_photo': 3,
        'mtcnn': _statBlock(allMtcnn),
        'mfn': _statBlock(allMfn),
        'total': _statBlock(allTotal),
        'detect_success': detectSuccess,
        'detect_total': detectTotal,
        'per_photo': perPhotoResults,
      };

      setState(() => _progress = 'Upload ke Supabase...');
      final uploaded = await _uploadResult('face_speed', stats);

      setState(() {
        _running = false;
        _progress = '';
        _result = _formatFaceResult(stats, uploaded);
      });
    } catch (e) {
      setState(() {
        _running = false;
        _progress = '';
        _result = 'Error: $e';
      });
    }
  }

  Future<_FaceProcessResult> _processOne(img.Image src) async {
    final resized = src.width > 640 ? img.copyResize(src, width: 640) : src;

    final tMtc = DateTime.now();
    final faces = await MTCNNService().detectFaces(resized, isGlassesMode: true);
    final mtcnnMs = DateTime.now().difference(tMtc).inMilliseconds;

    if (faces.isEmpty) return _FaceProcessResult(null, null);

    final bestFace = faces.reduce((a, b) => a.score > b.score ? a : b);
    final aligned = MTCNNService().alignAndCropFace(resized, bestFace);

    final tMfn = DateTime.now();
    MobileFaceNetService().predict(aligned);
    final mfnMs = DateTime.now().difference(tMfn).inMilliseconds;

    return _FaceProcessResult(mtcnnMs, mfnMs);
  }

  // ============================================================
  // FACE ACCURACY BENCHMARK
  // ============================================================
  Future<void> _runAccuracyBenchmark() async {
    setState(() {
      _running = true;
      _progress = 'Menyiapkan model...';
      _result = null;
    });

    try {
      await MTCNNService().init();
      if (!MobileFaceNetService().isModelLoaded) {
        await MobileFaceNetService().init();
      }

      // Load positif
      final posImgs = <img.Image>[];
      for (final a in _positives) {
        try {
          final data = await rootBundle.load(a);
          final decoded = img.decodeImage(data.buffer.asUint8List());
          if (decoded != null) posImgs.add(decoded);
        } catch (_) {}
      }
      if (posImgs.isEmpty) {
        setState(() {
          _running = false;
          _progress = '';
          _result = 'Tidak ada foto positif.';
        });
        return;
      }

      // Load negatif
      final negImgs = <img.Image>[];
      for (final a in _negatives) {
        try {
          final data = await rootBundle.load(a);
          final decoded = img.decodeImage(data.buffer.asUint8List());
          if (decoded != null) negImgs.add(decoded);
        } catch (_) {}
      }

      // Ambil embedding registrasi user dari DB
      final user = await DatabaseService.instance.getUser();
      if (user == null) {
        setState(() {
          _running = false;
          _progress = '';
          _result = 'User tidak ditemukan.';
        });
        return;
      }
      final userId = user['user_id'] as String;

      final rows = await DatabaseService.instance.getEmbeddings(
        userId: userId,
        mode: 'non_glasses',
      );
      if (rows.isEmpty) {
        setState(() {
          _running = false;
          _progress = '';
          _result = 'Tidak ada embedding registrasi.';
        });
        return;
      }

      final refEmb = <List<double>>[];
      for (final row in rows) {
        final raw = row['embedding'] as String;
        final parsed = (raw.startsWith('['))
            ? (raw.substring(1, raw.length - 1).split(','))
            : [];
        final emb = parsed
            .map((s) => double.tryParse(s.trim()) ?? 0.0)
            .toList();
        if (emb.length == 128) refEmb.add(emb);
      }
      if (refEmb.isEmpty) {
        setState(() {
          _running = false;
          _progress = '';
          _result = 'Embedding registrasi kosong/tidak valid.';
        });
        return;
      }

      // Hitung distance tiap foto ke embedding registrasi (ambil min)
      setState(() => _progress = 'Menghitung distance positif...');
      final posDist = <double>[];
      for (int i = 0; i < posImgs.length; i++) {
        setState(() => _progress = 'Positif ${i + 1}/${posImgs.length}');
        final d = await _minDistance(posImgs[i], refEmb);
        if (d != null) posDist.add(d);
      }

      setState(() => _progress = 'Menghitung distance negatif...');
      final negDist = <double>[];
      for (int i = 0; i < negImgs.length; i++) {
        setState(() => _progress = 'Negatif ${i + 1}/${negImgs.length}');
        final d = await _minDistance(negImgs[i], refEmb);
        if (d != null) negDist.add(d);
      }

      // Sweep threshold
      const thresholds = [0.60, 0.65, 0.70, 0.75, 0.80, 0.85];
      final sweep = <Map<String, dynamic>>[];

      for (final t in thresholds) {
        int tp = 0, fn = 0, tn = 0, fp = 0;
        for (final d in posDist) {
          if (d <= t) {
            tp++;
          } else {
            fn++;
          }
        }
        for (final d in negDist) {
          if (d <= t) {
            fp++;
          } else {
            tn++;
          }
        }
        final total = tp + fn + tn + fp;
        final acc = total == 0 ? 0.0 : (tp + tn) / total * 100;
        final far = (fp + tn) == 0 ? 0.0 : fp / (fp + tn) * 100;
        final frr = (fn + tp) == 0 ? 0.0 : fn / (fn + tp) * 100;
        sweep.add({
          'threshold': t,
          'tp': tp,
          'fn': fn,
          'tn': tn,
          'fp': fp,
          'accuracy': acc,
          'far': far,
          'frr': frr,
        });
      }

      // Cari threshold terbaik (akurasi tertinggi, tie-break FAR terendah)
      sweep.sort((a, b) {
        final accCmp =
            (b['accuracy'] as double).compareTo(a['accuracy'] as double);
        if (accCmp != 0) return accCmp;
        return (a['far'] as double).compareTo(b['far'] as double);
      });
      final best = sweep.first;

      final stats = <String, dynamic>{
        'positives': posDist.length,
        'negatives': negDist.length,
        'ref_embeddings': refEmb.length,
        'pos_distances': posDist,
        'neg_distances': negDist,
        'sweep': sweep,
        'best': best,
      };

      setState(() => _progress = 'Upload ke Supabase...');
      final uploaded = await _uploadResult('face_accuracy', stats);

      setState(() {
        _running = false;
        _progress = '';
        _result = _formatAccuracyResult(stats, uploaded);
      });
    } catch (e) {
      setState(() {
        _running = false;
        _progress = '';
        _result = 'Error: $e';
      });
    }
  }

  Future<double?> _minDistance(
    img.Image src,
    List<List<double>> refs,
  ) async {
    final resized = src.width > 640 ? img.copyResize(src, width: 640) : src;
    final faces = await MTCNNService().detectFaces(resized, isGlassesMode: true);
    if (faces.isEmpty) return null;

    final bestFace = faces.reduce((a, b) => a.score > b.score ? a : b);
    final aligned = MTCNNService().alignAndCropFace(resized, bestFace);
    final emb = MobileFaceNetService().predict(aligned);
    if (emb == null) return null;

    double minD = double.infinity;
    for (final ref in refs) {
      double sum = 0.0;
      final n = emb.length < ref.length ? emb.length : ref.length;
      for (int i = 0; i < n; i++) {
        final diff = emb[i] - ref[i];
        sum += diff * diff;
      }
      final d = sum;
      final dist = d == 0 ? 0.0 : _sqrt(d);
      if (dist < minD) minD = dist;
    }
    return minD;
  }

  double _sqrt(double x) {
    if (x <= 0) return 0;
    double r = x;
    for (int i = 0; i < 20; i++) {
      r = 0.5 * (r + x / r);
    }
    return r;
  }

  // ============================================================
  // GPS BENCHMARK
  // ============================================================
  Future<void> _runGpsBenchmark(bool useSatellite) async {
    final label = useSatellite ? 'SAT' : 'FUSED';

    setState(() {
      _running = true;
      _progress = 'GPS $label — menyiapkan...';
      _result = null;
    });

    try {
      final gps = GpsService();
      final ready = await gps.isGpsReady();
      if (!ready) {
        setState(() {
          _running = false;
          _progress = '';
          _result = 'GPS tidak siap / permission ditolak.';
        });
        return;
      }

      final t0 = DateTime.now();
      final fix = await gps.getPositionStreamCalibrate(
        timeout: const Duration(seconds: 60),
        useSatellite: useSatellite,
        onProgress: (elapsed, total) {
          setState(() => _progress = 'GPS $label — ${elapsed}s/$total');
        },
      );
      final durationMs = DateTime.now().difference(t0).inMilliseconds;

      final result = <String, dynamic>{
        'mode': useSatellite ? 'sat' : 'fused',
        'duration_ms': durationMs,
        'success': fix != null && fix.isValid,
        'lat': fix?.lat,
        'lng': fix?.lng,
        'accuracy_meters': fix?.accuracyMeters,
      };

      setState(() => _progress = 'Upload GPS $label...');
      final uploaded = await _uploadResult(
        useSatellite ? 'gps_sat' : 'gps_fused',
        result,
      );

      setState(() {
        _running = false;
        _progress = '';
        final acc = fix?.accuracyMeters.toStringAsFixed(1) ?? '-';
        final ok = result['success'] == true ? 'sukses' : 'gagal';
        _result = 'GPS $label: $ok\n'
            'Durasi: ${durationMs}ms\n'
            'Accuracy: ${acc}m\n'
            'Upload: ${uploaded ? "OK" : "GAGAL"}';
      });
    } catch (e) {
      setState(() {
        _running = false;
        _progress = '';
        _result = 'GPS Error: $e';
      });
    }
  }

  // ============================================================
  // UPLOAD
  // ============================================================
  Future<bool> _uploadResult(String testType, Map<String, dynamic> data) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return false;

    try {
      await Supabase.instance.client.from('benchmark_runs').insert({
        'user_id': user.id,
        'device_id': gDeviceId.isEmpty ? null : gDeviceId,
        'test_type': testType,
        'result_json': data,
      });
      debugPrint("BENCHMARK: uploaded $testType");
      return true;
    } catch (e) {
      debugPrint("BENCHMARK upload error: $e");
      return false;
    }
  }

  // ============================================================
  // HELPER
  // ============================================================
  Map<String, dynamic> _statBlock(List<int> xs) {
    if (xs.isEmpty) {
      return {'min': 0, 'max': 0, 'avg': 0.0, 'median': 0, 'count': 0};
    }
    return {
      'min': xs.reduce((a, b) => a < b ? a : b),
      'max': xs.reduce((a, b) => a > b ? a : b),
      'avg': _avg(xs),
      'median': _median(xs),
      'count': xs.length,
    };
  }

  double _avg(List<int> xs) {
    if (xs.isEmpty) return 0;
    return xs.reduce((a, b) => a + b) / xs.length;
  }

  int _median(List<int> xs) {
    if (xs.isEmpty) return 0;
    final sorted = List<int>.from(xs)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return ((sorted[mid - 1] + sorted[mid]) / 2).round();
  }

  String _formatFaceResult(Map<String, dynamic> stats, bool uploaded) {
    final m = stats['mtcnn'] as Map<String, dynamic>;
    final f = stats['mfn'] as Map<String, dynamic>;
    final t = stats['total'] as Map<String, dynamic>;

    return 'FACE SPEED BENCHMARK\n'
        'Foto: ${stats['photos']} × ${stats['per_photo_iterations']} iterasi\n'
        'Deteksi: ${stats['detect_success']}/${stats['detect_total']}\n\n'
        'MTCNN (ms): min=${m['min']} max=${m['max']} '
        'avg=${(m['avg'] as double).toStringAsFixed(1)} median=${m['median']}\n'
        'MFN (ms): min=${f['min']} max=${f['max']} '
        'avg=${(f['avg'] as double).toStringAsFixed(1)} median=${f['median']}\n'
        'Total (ms): min=${t['min']} max=${t['max']} '
        'avg=${(t['avg'] as double).toStringAsFixed(1)} median=${t['median']}\n\n'
        'Upload: ${uploaded ? "OK" : "GAGAL"}';
  }

  String _formatAccuracyResult(Map<String, dynamic> stats, bool uploaded) {
    final sb = StringBuffer();
    sb.writeln('FACE ACCURACY BENCHMARK');
    sb.writeln('Positif: ${stats['positives']} foto');
    sb.writeln('Negatif: ${stats['negatives']} foto');
    sb.writeln('Ref embeddings: ${stats['ref_embeddings']}');
    sb.writeln();
    sb.writeln('Sweep threshold:');
    for (final s in stats['sweep'] as List) {
      final m = s as Map<String, dynamic>;
      sb.writeln(
          '  t=${(m['threshold'] as double).toStringAsFixed(2)} '
          'acc=${(m['accuracy'] as double).toStringAsFixed(1)}% '
          'FAR=${(m['far'] as double).toStringAsFixed(1)}% '
          'FRR=${(m['frr'] as double).toStringAsFixed(1)}% '
          '[TP=${m['tp']} FN=${m['fn']} TN=${m['tn']} FP=${m['fp']}]');
    }
    final best = stats['best'] as Map<String, dynamic>;
    sb.writeln();
    sb.writeln('TERBAIK: t=${(best['threshold'] as double).toStringAsFixed(2)} '
        'acc=${(best['accuracy'] as double).toStringAsFixed(1)}%');
    sb.writeln();
    sb.writeln('Upload: ${uploaded ? "OK" : "GAGAL"}');
    return sb.toString();
  }

  // ============================================================
  // BUILD
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final gutter = AppSpacing.horizontal(context);

    return Scaffold(
      backgroundColor: AppColors.cream,
      appBar: AppBar(
        title: const Text('Testing & Benchmark'),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.darkSlate,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text(
                  'Iterasi per foto:',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.darkSlate,
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: _perPhoto,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 10, child: Text('Cepat (10)')),
                    DropdownMenuItem(value: 30, child: Text('Lama (30)')),
                  ],
                  onChanged: _running
                      ? null
                      : (v) => setState(() => _perPhoto = v ?? 10),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _running ? null : () => _runFaceBenchmark(_perPhoto),
                icon: const Icon(Icons.speed),
                label: const Text(
                  'Benchmark Kecepatan Wajah',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _running ? null : _runAccuracyBenchmark,
                icon: const Icon(Icons.analytics),
                label: const Text(
                  'Benchmark Akurasi Wajah',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _running ? null : () => _runGpsBenchmark(false),
                icon: const Icon(Icons.location_on),
                label: const Text(
                  'Benchmark GPS — FUSED',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _running ? null : () => _runGpsBenchmark(true),
                icon: const Icon(Icons.satellite_alt),
                label: const Text(
                  'Benchmark GPS — SAT',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 28),
            if (_progress.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.creamDark,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.tealMedium,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _progress,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.darkSlate,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_result != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.creamDark,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  _result!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.darkSlate,
                    height: 1.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}