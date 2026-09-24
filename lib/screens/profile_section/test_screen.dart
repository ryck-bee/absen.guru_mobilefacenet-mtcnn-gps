import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class _Face {
  final Rect box;
  final List<Point<double>> landmarks;
  final double score;
  _Face({required this.box, required this.landmarks, required this.score});
}

class _RawBox {
  double x1, y1, x2, y2, score;
  _RawBox(this.x1, this.y1, this.x2, this.y2, this.score);
}

class TestScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const TestScreen({super.key, required this.cameras});
  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _busy = false;
  String _status = "Menyiapkan...";

  Interpreter? _pnet;
  Interpreter? _rnet;
  Interpreter? _onet;

  static const int kPNetSize = 240;

  String _modelInfo = "Belum dimuat";
  Uint8List? _resultPng;
  String _meta = "";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _disposeCamera() async {
    final c = _controller;
    _controller = null;
    if (c != null) {
      try {
        await c.dispose();
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _initCamera() async {
    if (_controller != null && _controller!.value.isInitialized) return;
    try {
      final front = widget.cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => widget.cameras.first,
      );
      final c = CameraController(front, ResolutionPreset.high, enableAudio: false);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _status = "Siap. Tekan tombol.";
      });
    } catch (e) {
      if (mounted) setState(() => _status = "Gagal buka kamera: $e");
    }
  }

  Future<void> _init() async {
    setState(() {
      _busy = true;
      _status = "Memuat model TFLite...";
    });

    final log = StringBuffer();
    final opts = InterpreterOptions()..threads = 4;

    try {
      _pnet = await Interpreter.fromAsset('assets/models/pnet.tflite', options: opts);
      _pnet!.allocateTensors();
      log.writeln("P-Net OK");
    } catch (e) {
      log.writeln("P-Net FAIL: $e");
    }
    try {
      _rnet = await Interpreter.fromAsset('assets/models/rnet.tflite', options: opts);
      _rnet!.allocateTensors();
      log.writeln("R-Net OK");
    } catch (e) {
      log.writeln("R-Net FAIL: $e");
    }
    try {
      _onet = await Interpreter.fromAsset('assets/models/onet.tflite', options: opts);
      _onet!.allocateTensors();
      log.writeln("O-Net OK");
    } catch (e) {
      log.writeln("O-Net FAIL: $e");
    }

    _modelInfo = log.toString();

    if (_pnet == null || _rnet == null || _onet == null) {
      setState(() {
        _busy = false;
        _status = "Sebagian model gagal dimuat.";
      });
      return;
    }

    await _initCamera();
    if (mounted) setState(() => _busy = false);
  }

  List<List<List<List<double>>>> _imageToInput(img.Image image, double mean, double std) {
    final w = image.width;
    final h = image.height;
    final bytes = image.getBytes(order: img.ChannelOrder.rgb);
    return List.generate(1, (_) => List.generate(h, (y) => List.generate(w, (x) {
      final i = (y * w + x) * 3;
      return [
        (bytes[i] - mean) / std,
        (bytes[i + 1] - mean) / std,
        (bytes[i + 2] - mean) / std,
      ];
    })));
  }

  dynamic _zeros(List<int> shape) {
    if (shape.length == 1) return List.filled(shape[0], 0.0);
    if (shape.length == 2) {
      return List.generate(shape[0], (_) => List.filled(shape[1], 0.0));
    }
    if (shape.length == 3) {
      return List.generate(shape[0], (_) => List.generate(shape[1], (_) => List.filled(shape[2], 0.0)));
    }
    if (shape.length == 4) {
      return List.generate(shape[0], (_) => List.generate(shape[1], (_) => List.generate(shape[2], (_) => List.filled(shape[3], 0.0))));
    }
    throw Exception("Unsupported shape $shape");
  }

  double _iou(_RawBox a, _RawBox b) {
    final interX1 = max(a.x1, b.x1);
    final interY1 = max(a.y1, b.y1);
    final interX2 = min(a.x2, b.x2);
    final interY2 = min(a.y2, b.y2);
    final inter = max(0.0, interX2 - interX1) * max(0.0, interY2 - interY1);
    final areaA = (a.x2 - a.x1) * (a.y2 - a.y1);
    final areaB = (b.x2 - b.x1) * (b.y2 - b.y1);
    return inter / (areaA + areaB - inter + 1e-9);
  }

  List<_RawBox> _nms(List<_RawBox> boxes, double thresh) {
    if (boxes.isEmpty) return [];
    boxes.sort((a, b) => b.score.compareTo(a.score));
    final picked = <_RawBox>[];
    final active = List.filled(boxes.length, true);
    for (int i = 0; i < boxes.length; i++) {
      if (!active[i]) continue;
      picked.add(boxes[i]);
      for (int j = i + 1; j < boxes.length; j++) {
        if (active[j] && _iou(boxes[i], boxes[j]) > thresh) active[j] = false;
      }
    }
    return picked;
  }

  List<_RawBox> _resizeToSquare(List<_RawBox> boxes) {
    final out = <_RawBox>[];
    for (final b in boxes) {
      final w = b.x2 - b.x1;
      final h = b.y2 - b.y1;
      final side = max(w, h);
      final nx1 = b.x1 + w * 0.5 - side * 0.5;
      final ny1 = b.y1 + h * 0.5 - side * 0.5;
      final nx2 = nx1 + side;
      final ny2 = ny1 + side;
      out.add(_RawBox(nx1, ny1, nx2, ny2, b.score));
    }
    return out;
  }

  List<_RawBox> _runPNet(img.Image image, {double threshold = 0.6}) {
    final sw = Stopwatch()..start();

    final int side = min(image.width, image.height);
    final int cx = image.width ~/ 2;
    final int cy = image.height ~/ 2;
    final int cropX = cx - side ~/ 2;
    final int cropY = cy - side ~/ 2;
    final square = img.copyCrop(image, x: cropX, y: cropY, width: side, height: side);

    int idxClass = -1, idxBbox = -1;
    final outs = _pnet!.getOutputTensors();
    for (int i = 0; i < outs.length; i++) {
      final last = outs[i].shape.last;
      if (last == 2) idxClass = i;
      else if (last == 4) idxBbox = i;
    }
    final outClassShape = _pnet!.getOutputTensor(idxClass).shape;
    final outBboxShape = _pnet!.getOutputTensor(idxBbox).shape;
    final int oh = outClassShape[1];
    final int ow = outClassShape[2];

    // 6 skala — penting untuk deteksi wajah di berbagai ukuran
    final scales = [1.0, 0.5, 0.25, 0.125, 0.0625, 0.03125];

    final candidates = <_RawBox>[];
    double globalMaxProb = 0;

    for (final s in scales) {
      final int sw2 = (side * s).round();
      final int sh2 = (side * s).round();
      if (sw2 < 16 || sh2 < 16) continue;

      final scaled = img.copyResize(square, width: sw2, height: sh2);

      final padded = img.Image(width: kPNetSize, height: kPNetSize);
      for (int y = 0; y < kPNetSize; y++) {
        for (int x = 0; x < kPNetSize; x++) {
          if (x < sw2 && y < sh2) {
            final p = scaled.getPixel(x, y);
            padded.setPixelRgb(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt());
          } else {
            padded.setPixelRgb(x, y, 0, 0, 0);
          }
        }
      }

      final input = _imageToInput(padded, 127.5, 127.5);
      final outClass = _zeros(outClassShape);
      final outBbox = _zeros(outBboxShape);
      _pnet!.runForMultipleInputs([input], {idxClass: outClass, idxBbox: outBbox});

      final double invScale = 1.0 / s;

      for (int y = 0; y < oh; y++) {
        for (int x = 0; x < ow; x++) {
          if (x * 2 + 12 > sw2) continue;
          if (y * 2 + 12 > sh2) continue;

          final double prob = (outClass[0][y][x][1] as num).toDouble();
          if (prob > globalMaxProb) globalMaxProb = prob;
          if (prob > threshold) {
            final double r0 = (outBbox[0][y][x][0] as num).toDouble();
            final double r1 = (outBbox[0][y][x][1] as num).toDouble();
            final double r2 = (outBbox[0][y][x][2] as num).toDouble();
            final double r3 = (outBbox[0][y][x][3] as num).toDouble();

            final double sxSc = x * 2.0;
            final double sySc = y * 2.0;
            const double swSc = 12.0;
            const double shSc = 12.0;

            final double x1s = sxSc + r0 * swSc;
            final double y1s = sySc + r1 * shSc;
            final double x2s = sxSc + (1.0 + r2) * swSc;
            final double y2s = sySc + (1.0 + r3) * shSc;

            candidates.add(_RawBox(
              cropX + x1s * invScale,
              cropY + y1s * invScale,
              cropX + x2s * invScale,
              cropY + y2s * invScale,
              prob,
            ));
          }
        }
      }
    }

    final nmsed = _nms(candidates, 0.5);
    final squared = _resizeToSquare(nmsed);

    sw.stop();
    debugPrint("P-NET maxProb=${globalMaxProb.toStringAsFixed(4)} candidates=${candidates.length} afterNMS=${nmsed.length} time=${sw.elapsedMilliseconds}ms");
    return squared;
  }

  img.Image _cropSquare(img.Image image, _RawBox b, int size) {
    final double w = b.x2 - b.x1;
    final double h = b.y2 - b.y1;
    final double side = max(w, h);
    final double cx = b.x1 + w / 2;
    final double cy = b.y1 + h / 2;
    int x1 = (cx - side / 2).round();
    int y1 = (cy - side / 2).round();
    int x2 = (cx + side / 2).round();
    int y2 = (cy + side / 2).round();

    x1 = x1.clamp(0, image.width - 1);
    y1 = y1.clamp(0, image.height - 1);
    x2 = x2.clamp(x1 + 1, image.width);
    y2 = y2.clamp(y1 + 1, image.height);

    final c = img.copyCrop(image, x: x1, y: y1, width: x2 - x1, height: y2 - y1);
    return img.copyResize(c, width: size, height: size);
  }

  List<_RawBox> _runRNet(img.Image image, List<_RawBox> boxes, {double threshold = 0.6}) {
    final sw = Stopwatch()..start();

    final sorted = List<_RawBox>.from(boxes)..sort((a, b) => b.score.compareTo(a.score));
    final limited = sorted.take(30).toList();

    final result = <_RawBox>[];

    int idxClass = -1, idxBbox = -1;
    final outs = _rnet!.getOutputTensors();
    for (int i = 0; i < outs.length; i++) {
      final last = outs[i].shape.last;
      if (last == 2) idxClass = i;
      else if (last == 4) idxBbox = i;
    }

    final outClassShape = _rnet!.getOutputTensor(idxClass).shape;
    final outBboxShape = _rnet!.getOutputTensor(idxBbox).shape;

    double maxProb = 0;

    for (final b in limited) {
      final crop = _cropSquare(image, b, 24);
      final input = _imageToInput(crop, 127.5, 127.5);

      final outClass = _zeros(outClassShape);
      final outBbox = _zeros(outBboxShape);
      _rnet!.runForMultipleInputs([input], {idxClass: outClass, idxBbox: outBbox});

      final double prob = (outClass[0][1] as num).toDouble();
      if (prob > maxProb) maxProb = prob;

      if (prob > threshold) {
        final double w = b.x2 - b.x1 + 1.0;
        final double h = b.y2 - b.y1 + 1.0;
        final double r0 = (outBbox[0][0] as num).toDouble();
        final double r1 = (outBbox[0][1] as num).toDouble();
        final double r2 = (outBbox[0][2] as num).toDouble();
        final double r3 = (outBbox[0][3] as num).toDouble();
        result.add(_RawBox(
          b.x1 + r0 * w, b.y1 + r1 * h,
          b.x2 + r2 * w, b.y2 + r3 * h,
          prob,
        ));
      }
    }
    final nmsed = _nms(result, 0.7);
    final squared = _resizeToSquare(nmsed);

    sw.stop();
    debugPrint("R-NET maxProb=${maxProb.toStringAsFixed(4)} tried=${limited.length} survivors=${nmsed.length} time=${sw.elapsedMilliseconds}ms");
    return squared;
  }

  List<_Face> _runONet(img.Image image, List<_RawBox> boxes, {double threshold = 0.5}) {
    final sw = Stopwatch()..start();

    final sorted = List<_RawBox>.from(boxes)..sort((a, b) => b.score.compareTo(a.score));
    final limited = sorted.take(5).toList();

    final result = <_Face>[];

    int idxClass = -1, idxBbox = -1, idxLm = -1;
    final outs = _onet!.getOutputTensors();
    for (int i = 0; i < outs.length; i++) {
      final last = outs[i].shape.last;
      if (last == 2) idxClass = i;
      else if (last == 4) idxBbox = i;
      else if (last == 10) idxLm = i;
    }

    final outClassShape = _onet!.getOutputTensor(idxClass).shape;
    final outBboxShape = _onet!.getOutputTensor(idxBbox).shape;
    final outLmShape = _onet!.getOutputTensor(idxLm).shape;

    double maxProb = 0;

    for (final b in limited) {
      final crop = _cropSquare(image, b, 48);
      final input = _imageToInput(crop, 127.5, 127.5);

      final outClass = _zeros(outClassShape);
      final outBbox = _zeros(outBboxShape);
      final outLm = _zeros(outLmShape);
      _onet!.runForMultipleInputs([input], {idxClass: outClass, idxBbox: outBbox, idxLm: outLm});

      final double prob = (outClass[0][1] as num).toDouble();
      if (prob > maxProb) maxProb = prob;

      if (prob > threshold) {
        final double bw = b.x2 - b.x1 + 1.0;
        final double bh = b.y2 - b.y1 + 1.0;

        final landmarks = <Point<double>>[];
        for (int i = 0; i < 5; i++) {
          final lx = (outLm[0][i] as num).toDouble() * bw + b.x1 - 1.0;
          final ly = (outLm[0][i + 5] as num).toDouble() * bh + b.y1 - 1.0;
          landmarks.add(Point(lx, ly));
        }

        final double r0 = (outBbox[0][0] as num).toDouble();
        final double r1 = (outBbox[0][1] as num).toDouble();
        final double r2 = (outBbox[0][2] as num).toDouble();
        final double r3 = (outBbox[0][3] as num).toDouble();
        final double nx1 = b.x1 + r0 * bw;
        final double ny1 = b.y1 + r1 * bh;
        final double nx2 = b.x2 + r2 * bw;
        final double ny2 = b.y2 + r3 * bh;

        result.add(_Face(
          box: Rect.fromLTRB(nx1, ny1, nx2, ny2),
          landmarks: landmarks,
          score: prob,
        ));
      }
    }

    sw.stop();
    debugPrint("O-NET maxProb=${maxProb.toStringAsFixed(4)} tried=${limited.length} survivors=${result.length} time=${sw.elapsedMilliseconds}ms");
    return result;
  }

  List<_Face> _detect(img.Image image) {
    final sw = Stopwatch()..start();

    final p = _runPNet(image);
    final tP = sw.elapsedMilliseconds;
    if (p.isEmpty) {
      _meta = "P-Net: 0. Time: ${sw.elapsedMilliseconds}ms";
      return [];
    }
    final r = _runRNet(image, p);
    final tR = sw.elapsedMilliseconds - tP;
    if (r.isEmpty) {
      _meta = "P-Net:${p.length}(${tP}ms) R-Net:0(${tR}ms) Total:${sw.elapsedMilliseconds}ms";
      return [];
    }
    final o = _runONet(image, r);
    final tO = sw.elapsedMilliseconds - tP - tR;
    sw.stop();

    _meta = "P-Net:${p.length}(${tP}ms) R-Net:${r.length}(${tR}ms) O-Net:${o.length}(${tO}ms) Total:${sw.elapsedMilliseconds}ms";
    return o;
  }

  Future<void> _capture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() {
      _busy = true;
      _status = "Mengambil foto...";
      _resultPng = null;
    });

    try {
      final xfile = await _controller!.takePicture();
      final bytes = await xfile.readAsBytes();
      var raw = img.decodeImage(bytes);
      if (raw == null) {
        setState(() {
          _busy = false;
          _status = "Gagal decode.";
        });
        return;
      }

      if (raw.width > 960) raw = img.copyResize(raw, width: 960);

      setState(() => _status = "Menjalankan MTCNN...");
      final sw = Stopwatch()..start();
      final faces = _detect(raw);
      sw.stop();

      final vis = img.Image.from(raw);
      for (final f in faces) {
        final x1 = f.box.left.toInt().clamp(0, vis.width - 1);
        final y1 = f.box.top.toInt().clamp(0, vis.height - 1);
        final x2 = f.box.right.toInt().clamp(0, vis.width - 1);
        final y2 = f.box.bottom.toInt().clamp(0, vis.height - 1);
        for (int x = x1; x <= x2; x++) {
          vis.setPixelRgb(x, y1, 255, 0, 0);
          vis.setPixelRgb(x, y2, 255, 0, 0);
        }
        for (int y = y1; y <= y2; y++) {
          vis.setPixelRgb(x1, y, 255, 0, 0);
          vis.setPixelRgb(x2, y, 255, 0, 0);
        }
        for (final lm in f.landmarks) {
          final lx = lm.x.toInt().clamp(0, vis.width - 1);
          final ly = lm.y.toInt().clamp(0, vis.height - 1);
          for (int dx = -4; dx <= 4; dx++) {
            for (int dy = -4; dy <= 4; dy++) {
              final px = (lx + dx).clamp(0, vis.width - 1);
              final py = (ly + dy).clamp(0, vis.height - 1);
              vis.setPixelRgb(px, py, 0, 255, 0);
            }
          }
        }
      }

      final png = Uint8List.fromList(img.encodeJpg(vis, quality: 85));

      setState(() {
        _resultPng = png;
        _busy = false;
        final metaInfo = "TOTAL: ${sw.elapsedMilliseconds} ms | Deteksi: ${faces.length}";
        _meta = "$metaInfo\n$_meta";
        _status = "Selesai.";
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _status = "Error: $e";
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Testing MTCNN")),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Text(_status, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Status load model", style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  SelectableText(_modelInfo, style: const TextStyle(fontFamily: "monospace", fontSize: 11)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (_controller != null && _controller!.value.isInitialized)
            AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: CameraPreview(_controller!),
            ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _busy ? null : _capture,
            icon: const Icon(Icons.camera_alt),
            label: Text(_busy ? "Memproses..." : "Ambil Foto & Deteksi"),
          ),
          const SizedBox(height: 16),
          if (_meta.isNotEmpty)
            Text(_meta, style: const TextStyle(fontWeight: FontWeight.bold)),
          if (_resultPng != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Image.memory(_resultPng!, fit: BoxFit.contain),
            ),
        ],
      ),
    );
  }
}