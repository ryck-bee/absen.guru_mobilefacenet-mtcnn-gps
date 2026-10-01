import 'dart:async';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../model/mobilefacenet_service.dart';
import '../model/mtcnn_service.dart';

/// Hasil proses satu frame dari worker isolate.
class FaceWorkerResult {
  final bool faceDetected;
  final bool mfnOk;
  final List<double>? embedding;
  final int mtcnnMs;
  final int mfnMs;
  final Uint8List? alignedJpg;
  final Uint8List? alignedLmJpg;

  FaceWorkerResult({
    required this.faceDetected,
    required this.mfnOk,
    this.embedding,
    required this.mtcnnMs,
    required this.mfnMs,
    this.alignedJpg,
    this.alignedLmJpg,
  });

  static FaceWorkerResult empty({int mtcnnMs = 0, int mfnMs = 0}) =>
      FaceWorkerResult(
        faceDetected: false,
        mfnOk: false,
        mtcnnMs: mtcnnMs,
        mfnMs: mfnMs,
      );
}

/// Wrapper isolate MTCNN + MFN.
/// - Model di-load sekali di worker (dari bytes yang dikirim main).
/// - Proses frame jalan di isolate terpisah → main thread bebas.
class FaceWorker {
  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  final _readyCompleter = Completer<void>();
  final Map<int, Completer<FaceWorkerResult>> _pending = {};
  int _nextId = 1;
  bool _disposed = false;

  bool get isReady => _readyCompleter.isCompleted;

  Future<void> start({
    required Uint8List pnetBytes,
    required Uint8List rnetBytes,
    required Uint8List onetBytes,
    required Uint8List mfnBytes,
  }) async {
    if (_isolate != null) return;

    _fromWorker = ReceivePort();
    _isolate = await Isolate.spawn(_workerMain, _fromWorker!.sendPort);
    _fromWorker!.listen(_onMessage);

    // Tunggu sampai worker kirim balik SendPort-nya.
    while (_toWorker == null) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    _toWorker!.send({
      'cmd': 'init',
      'pnet': pnetBytes,
      'rnet': rnetBytes,
      'onet': onetBytes,
      'mfn': mfnBytes,
    });

    await _readyCompleter.future;
  }

  void _onMessage(dynamic msg) {
    if (msg is SendPort) {
      _toWorker = msg;
      return;
    }
    if (msg is Map) {
      final cmd = msg['cmd'] as String?;
      if (cmd == 'ready') {
        if (!_readyCompleter.isCompleted) _readyCompleter.complete();
      } else if (cmd == 'result') {
        final id = msg['id'] as int;
        final completer = _pending.remove(id);
        if (completer != null && !completer.isCompleted) {
          completer.complete(FaceWorkerResult(
            faceDetected: msg['faceDetected'] as bool,
            mfnOk: msg['mfnOk'] as bool,
            embedding: (msg['embedding'] as List?)?.cast<double>(),
            mtcnnMs: msg['mtcnnMs'] as int,
            mfnMs: msg['mfnMs'] as int,
            alignedJpg: msg['alignedJpg'] as Uint8List?,
            alignedLmJpg: msg['alignedLmJpg'] as Uint8List?,
          ));
        }
      }
    }
  }

  Future<FaceWorkerResult> processFrame({
    required Uint8List rgb,
    required int width,
    required int height,
    bool isGlassesMode = true,
  }) async {
    if (_toWorker == null) {
      return FaceWorkerResult.empty();
    }
    final id = _nextId++;
    final completer = Completer<FaceWorkerResult>();
    _pending[id] = completer;

    _toWorker!.send({
      'cmd': 'process',
      'id': id,
      'rgb': rgb,
      'width': width,
      'height': height,
      'isGlassesMode': isGlassesMode,
    });

    return completer.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _toWorker = null;
    _fromWorker?.close();
    _fromWorker = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(FaceWorkerResult.empty());
    }
    _pending.clear();
  }
}

// ============================================================
// WORKER MAIN (isolate entry)
// ============================================================
Future<void> _workerMain(SendPort mainPort) async {
  final mtcnn = MTCNNService();
  final mfn = MobileFaceNetService();

  final cmdPort = ReceivePort();
  mainPort.send(cmdPort.sendPort);

  await for (final msg in cmdPort) {
    if (msg is! Map) continue;
    final cmd = msg['cmd'] as String?;

    if (cmd == 'init') {
      try {
        await mtcnn.initFromBytes(
          pnetBytes: msg['pnet'] as Uint8List,
          rnetBytes: msg['rnet'] as Uint8List,
          onetBytes: msg['onet'] as Uint8List,
        );
        await mfn.initFromBytes(msg['mfn'] as Uint8List);
        debugPrint("WORKER: init OK");
      } catch (e) {
        debugPrint("WORKER: init error -> $e");
      }
      mainPort.send({'cmd': 'ready'});
    } else if (cmd == 'process') {
      final id = msg['id'] as int;
      final rgb = msg['rgb'] as Uint8List;
      final width = msg['width'] as int;
      final height = msg['height'] as int;
      final isGlassesMode = msg['isGlassesMode'] as bool? ?? true;

      int mtcnnMs = 0;
      int mfnMs = 0;
      bool faceDetected = false;
      bool mfnOk = false;
      List<double>? embedding;
      Uint8List? alignedJpg;
      Uint8List? alignedLmJpg;

      try {
        final safeRgb = Uint8List.fromList(rgb);
        final image = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: safeRgb.buffer,
          order: img.ChannelOrder.rgb,
        );

        final tMtc = DateTime.now();
        final faces =
            await mtcnn.detectFaces(image, isGlassesMode: isGlassesMode);
        mtcnnMs = DateTime.now().difference(tMtc).inMilliseconds;

        if (faces.isNotEmpty) {
          faceDetected = true;
          final best = faces.reduce((a, b) => a.score > b.score ? a : b);
          final aligned = mtcnn.alignAndCropFace(image, best);
          final alignedLm = mtcnn.alignCropAndDrawLandmarks(image, best);

          final tMfn = DateTime.now();
          final emb = mfn.predict(aligned);
          mfnMs = DateTime.now().difference(tMfn).inMilliseconds;

          if (emb != null) {
            mfnOk = true;
            embedding = emb;
          }

          try {
            alignedJpg =
                Uint8List.fromList(img.encodeJpg(aligned, quality: 75));
            alignedLmJpg =
                Uint8List.fromList(img.encodeJpg(alignedLm, quality: 75));
          } catch (_) {}
        }
      } catch (e) {
        debugPrint("WORKER: process error -> $e");
      }

      mainPort.send({
        'cmd': 'result',
        'id': id,
        'faceDetected': faceDetected,
        'mfnOk': mfnOk,
        'embedding': embedding,
        'mtcnnMs': mtcnnMs,
        'mfnMs': mfnMs,
        'alignedJpg': alignedJpg,
        'alignedLmJpg': alignedLmJpg,
      });
    }
  }
}