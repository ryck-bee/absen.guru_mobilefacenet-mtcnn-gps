import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import '../../config/glasses_config.dart';

class MTCNNFace {
  final Rect box;
  final List<Point<double>> landmarks;
  final double score;

  MTCNNFace({
    required this.box,
    required this.landmarks,
    required this.score,
  });
}

class _RawBox {
  double x1, y1, x2, y2, score;
  _RawBox(this.x1, this.y1, this.x2, this.y2, this.score);
}

class MTCNNService {
  Interpreter? _pnet;
  Interpreter? _rnet;
  Interpreter? _onet;
  bool _isLoaded = false;

  static const int kPNetSize = 240;

  Future<void> init() async {
    if (_isLoaded) return;
    try {
      final options = InterpreterOptions()..threads = 4;
      _pnet = await Interpreter.fromAsset('assets/models/pnet.tflite', options: options);
      _rnet = await Interpreter.fromAsset('assets/models/rnet.tflite', options: options);
      _onet = await Interpreter.fromAsset('assets/models/onet.tflite', options: options);
      _pnet!.allocateTensors();
      _rnet!.allocateTensors();
      _onet!.allocateTensors();
      _isLoaded = true;
    } catch (e) {
      debugPrint("Gagal memuat model MTCNN: $e");
    }
  }

  bool detectGlasses(img.Image inputImage, MTCNNFace face) {
    if (face.landmarks.length < 2) return false;

    final leftEye = face.landmarks[0];
    final rightEye = face.landmarks[1];

    int minX = min(leftEye.x, rightEye.x).round().clamp(0, inputImage.width - 1);
    int maxX = max(leftEye.x, rightEye.x).round().clamp(0, inputImage.width - 1);
    int eyeY = ((leftEye.y + rightEye.y) / 2).round().clamp(0, inputImage.height - 1);

    int edgePixels = 0;
    int totalSample = 0;

    for (int x = minX; x <= maxX; x++) {
      for (int y = max(0, eyeY - 4); y <= min(inputImage.height - 1, eyeY + 4); y++) {
        var current = inputImage.getPixel(x, y);
        var next = inputImage.getPixel(min(inputImage.width - 1, x + 1), y);

        double lum1 = (current.r * 0.299 + current.g * 0.587 + current.b * 0.114);
        double lum2 = (next.r * 0.299 + next.g * 0.587 + next.b * 0.114);

        if ((lum1 - lum2).abs() > 40) {
          edgePixels++;
        }
        totalSample++;
      }
    }

    if (totalSample == 0) return false;
    return (edgePixels / totalSample) > 0.25;
  }

  Future<List<MTCNNFace>> detectFaces(
    img.Image inputImage, {
    bool isGlassesMode = true,
    double minFaceSize = 50.0,
  }) async {
    if (!_isLoaded) await init();
    if (_pnet == null || _rnet == null || _onet == null) return [];

    double rNetThreshold = GlassesConfig.strictRNetThreshold;
    double oNetThreshold = GlassesConfig.strictONetThreshold;

    if (isGlassesMode) {
      rNetThreshold = GlassesConfig.looseRNetThreshold;
      oNetThreshold = GlassesConfig.looseONetThreshold;
    }

    final pnetBoxes = _runPNet(inputImage);
    if (pnetBoxes.isEmpty) return [];

    final rnetBoxes = _runRNet(inputImage, pnetBoxes, threshold: rNetThreshold);
    if (rnetBoxes.isEmpty) return [];

    final onetFaces = _runONet(inputImage, rnetBoxes, threshold: oNetThreshold);
    return onetFaces;
  }

  // ============================================================
  // CROP + LANDMARK DRAWING (BARU)
  // ============================================================

  /// Crop wajah dari frame (pakai logika alignAndCropFace yang sudah ada),
  /// lalu gambar 5 landmark sebagai titik.
  ///
  /// Return img.Image 96x112 dengan landmark digambar.
  img.Image alignCropAndDrawLandmarks(
    img.Image inputImage,
    MTCNNFace face, {
    int r = 0, int g = 255, int b = 0, // warna titik (hijau default)
    int radius = 2, // radius titik dalam px
  }) {
    // 1. Hitung crop region — SAMA PERSIS dengan alignAndCropFace
    final double boxX = face.box.left;
    final double boxY = face.box.top;
    final double boxW = face.box.width;
    final double boxH = face.box.height;

    final double centerX = boxX + (boxW / 2) + (boxW * 0.03);
    final double centerY = boxY + (boxH / 2);

    final double cropHeight = max(boxW, boxH) * 1.45;
    final double cropWidth = cropHeight * (96.0 / 112.0);

    int cropX = (centerX - (cropWidth / 2)).round();
    int cropY = (centerY - (cropHeight / 2) + (boxH * 0.03)).round();

    cropX = cropX.clamp(0, max(0, inputImage.width - 1));
    cropY = cropY.clamp(0, max(0, inputImage.height - 1));

    final int validW = min(inputImage.width - cropX, cropWidth.round());
    final int validH = min(inputImage.height - cropY, cropHeight.round());

    if (validW <= 20 || validH <= 20) return inputImage;

    // 2. Crop dan resize ke 96x112
    final img.Image cropped = img.copyCrop(
      inputImage, x: cropX, y: cropY, width: validW, height: validH,
    );
    final img.Image resized = img.copyResize(cropped, width: 96, height: 112);

    // 3. Hitung skala dari crop region ke 96x112
    final double scaleX = 96.0 / validW;
    final double scaleY = 112.0 / validH;

    // 4. Gambar tiap landmark
    for (final lm in face.landmarks) {
      // Posisi landmark di crop (relatif terhadap cropX/cropY)
      final double lmInCropX = (lm.x - cropX) * scaleX;
      final double lmInCropY = (lm.y - cropY) * scaleY;

      // Skip kalau landmark di luar area crop
      if (lmInCropX < 0 || lmInCropX >= 96 || lmInCropY < 0 || lmInCropY >= 112) {
        continue;
      }

      final int px = lmInCropX.round();
      final int py = lmInCropY.round();

      // Gambar lingkaran kecil
      for (int dx = -radius; dx <= radius; dx++) {
        for (int dy = -radius; dy <= radius; dy++) {
          if (dx * dx + dy * dy > radius * radius) continue;
          final int x = (px + dx).clamp(0, 95);
          final int y = (py + dy).clamp(0, 111);
          resized.setPixelRgb(x, y, r, g, b);
        }
      }
    }

    return resized;
  }

  // ============================================================
  // PIPELINE INTERNAL (tidak berubah dari versi sebelumnya)
  // ============================================================
  List<_RawBox> _runPNet(img.Image image, {double threshold = 0.6}) {
    final int side = min(image.width, image.height);
    final int cx = image.width ~/ 2;
    final int cy = image.height ~/ 2;
    final int cropX = cx - side ~/ 2;
    final int cropY = cy - side ~/ 2;
    final square = img.copyCrop(image, x: cropX, y: cropY, width: side, height: side);

    _pnet!.resizeInputTensor(0, [1, kPNetSize, kPNetSize, 3]);
    _pnet!.allocateTensors();

    int idxClass = -1, idxBbox = -1;
    final outs = _pnet!.getOutputTensors();
    for (int i = 0; i < outs.length; i++) {
      final last = outs[i].shape.last;
      if (last == 2) {
        idxClass = i;
      } else if (last == 4) {
        idxBbox = i;
      }
    }
    if (idxClass < 0 || idxBbox < 0) return [];

    final outClassShape = _pnet!.getOutputTensor(idxClass).shape;
    final outBboxShape = _pnet!.getOutputTensor(idxBbox).shape;
    final int oh = outClassShape[1];
    final int ow = outClassShape[2];

    final scales = [1.0, 0.5, 0.25, 0.125, 0.0625, 0.03125];

    final candidates = <_RawBox>[];

    for (final s in scales) {
      final int sw = (side * s).round();
      final int sh = (side * s).round();
      if (sw < 16 || sh < 16) continue;

      final scaled = img.copyResize(square, width: sw, height: sh);

      final padded = img.Image(width: kPNetSize, height: kPNetSize);
      for (int y = 0; y < kPNetSize; y++) {
        for (int x = 0; x < kPNetSize; x++) {
          if (x < sw && y < sh) {
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
          if (x * 2 + 12 > sw) continue;
          if (y * 2 + 12 > sh) continue;

          final double prob = (outClass[0][y][x][1] as num).toDouble();
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

    final nmsed = _nmsRaw(candidates, 0.5);
    return _resizeToSquare(nmsed);
  }

  List<_RawBox> _runRNet(img.Image image, List<_RawBox> boxes, {double threshold = 0.6}) {
    final sorted = List<_RawBox>.from(boxes)..sort((a, b) => b.score.compareTo(a.score));
    final limited = sorted.take(30).toList();

    final result = <_RawBox>[];

    int idxClass = -1, idxBbox = -1;
    final outs = _rnet!.getOutputTensors();
    for (int i = 0; i < outs.length; i++) {
      final last = outs[i].shape.last;
      if (last == 2) {
        idxClass = i;
      } else if (last == 4) {
        idxBbox = i;
      }
    }
    if (idxClass < 0 || idxBbox < 0) return [];

    final outClassShape = _rnet!.getOutputTensor(idxClass).shape;
    final outBboxShape = _rnet!.getOutputTensor(idxBbox).shape;

    for (final b in limited) {
      final crop = _cropSquare(image, b, 24);
      final input = _imageToInput(crop, 127.5, 127.5);

      final outClass = _zeros(outClassShape);
      final outBbox = _zeros(outBboxShape);
      _rnet!.runForMultipleInputs([input], {idxClass: outClass, idxBbox: outBbox});

      final double prob = (outClass[0][1] as num).toDouble();
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

    final nmsed = _nmsRaw(result, 0.7);
    return _resizeToSquare(nmsed);
  }

  List<MTCNNFace> _runONet(img.Image image, List<_RawBox> boxes, {double threshold = 0.5}) {
    final sorted = List<_RawBox>.from(boxes)..sort((a, b) => b.score.compareTo(a.score));
    final limited = sorted.take(5).toList();

    final result = <MTCNNFace>[];

    int idxClass = -1, idxBbox = -1, idxLm = -1;
    final outs = _onet!.getOutputTensors();
    for (int i = 0; i < outs.length; i++) {
      final last = outs[i].shape.last;
      if (last == 2) {
        idxClass = i;
      } else if (last == 4) {
        idxBbox = i;
      } else if (last == 10) {
        idxLm = i;
      }
    }
    if (idxClass < 0 || idxBbox < 0 || idxLm < 0) return [];

    final outClassShape = _onet!.getOutputTensor(idxClass).shape;
    final outBboxShape = _onet!.getOutputTensor(idxBbox).shape;
    final outLmShape = _onet!.getOutputTensor(idxLm).shape;

    for (final b in limited) {
      final crop = _cropSquare(image, b, 48);
      final input = _imageToInput(crop, 127.5, 127.5);

      final outClass = _zeros(outClassShape);
      final outBbox = _zeros(outBboxShape);
      final outLm = _zeros(outLmShape);
      _onet!.runForMultipleInputs([input], {idxClass: outClass, idxBbox: outBbox, idxLm: outLm});

      final double prob = (outClass[0][1] as num).toDouble();
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

        result.add(MTCNNFace(
          box: Rect.fromLTRB(nx1, ny1, nx2, ny2),
          landmarks: landmarks,
          score: prob,
        ));
      }
    }

    return _filterPlausibleFaces(result);
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

  List<_RawBox> _nmsRaw(List<_RawBox> boxes, double thresh) {
    if (boxes.isEmpty) return [];
    boxes.sort((a, b) => b.score.compareTo(a.score));
    final picked = <_RawBox>[];
    final active = List.filled(boxes.length, true);
    for (int i = 0; i < boxes.length; i++) {
      if (!active[i]) continue;
      picked.add(boxes[i]);
      for (int j = i + 1; j < boxes.length; j++) {
        if (active[j] && _iouRaw(boxes[i], boxes[j]) > thresh) active[j] = false;
      }
    }
    return picked;
  }

  double _iouRaw(_RawBox a, _RawBox b) {
    final interX1 = max(a.x1, b.x1);
    final interY1 = max(a.y1, b.y1);
    final interX2 = min(a.x2, b.x2);
    final interY2 = min(a.y2, b.y2);
    final inter = max(0.0, interX2 - interX1) * max(0.0, interY2 - interY1);
    final areaA = (a.x2 - a.x1) * (a.y2 - a.y1);
    final areaB = (b.x2 - b.x1) * (b.y2 - b.y1);
    return inter / (areaA + areaB - inter + 1e-9);
  }

  List<MTCNNFace> _filterPlausibleFaces(List<MTCNNFace> boxes) {
    return boxes.where((face) {
      final double w = face.box.width;
      final double h = face.box.height;
      if (w <= 0 || h <= 0) return false;

      final double ratio = h / w;
      if (ratio < 0.65 || ratio > 1.75) return false;

      if (min(w, h) < 30) return false;

      if (face.landmarks.length >= 5) {
        final leftEye = face.landmarks[0];
        final rightEye = face.landmarks[1];

        if (leftEye.x >= rightEye.x) return false;

        final nose = face.landmarks[2];
        final avgEyeY = (leftEye.y + rightEye.y) / 2;
        if (avgEyeY >= nose.y) return false;
      }

      return true;
    }).toList();
  }

  img.Image alignAndCropFace(img.Image inputImage, MTCNNFace face) {
    img.Image workingImage = inputImage;

    double boxX = face.box.left;
    double boxY = face.box.top;
    double boxW = face.box.width;
    double boxH = face.box.height;

    double centerX = boxX + (boxW / 2) + (boxW * 0.03);
    double centerY = boxY + (boxH / 2);

    double cropHeight = max(boxW, boxH) * 1.45;
    double cropWidth = cropHeight * (96.0 / 112.0);

    int x = (centerX - (cropWidth / 2)).round();
    int y = (centerY - (cropHeight / 2) + (boxH * 0.03)).round();

    x = x.clamp(0, max(0, workingImage.width - 1));
    y = y.clamp(0, max(0, workingImage.height - 1));

    int validW = min(workingImage.width - x, cropWidth.round());
    int validH = min(workingImage.height - y, cropHeight.round());

    if (validW <= 20 || validH <= 20) return inputImage;

    img.Image cropped = img.copyCrop(workingImage, x: x, y: y, width: validW, height: validH);
    return img.copyResize(cropped, width: 96, height: 112);
  }

  img.Image alignFace(img.Image inputImage, MTCNNFace face) {
    return alignAndCropFace(inputImage, face);
  }
}