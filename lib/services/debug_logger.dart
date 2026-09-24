import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Logger yang capture semua debugPrint ke file.
/// Export bisa dibagikan via WhatsApp.
class DebugLogger {
  DebugLogger._();
  static final DebugLogger instance = DebugLogger._();

  final List<String> _buffer = [];
  static const int _maxBufferLines = 5000;
  File? _logFile;
  Timer? _flushTimer; 
  bool _initialized = false;
  bool _capturing = false;

  bool get isCapturing => _capturing;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) await logDir.create(recursive: true);

      final stamp = _fileStamp();
      _logFile = File('${logDir.path}/log_$stamp.txt');
      await _logFile!.writeAsString(
        '=== LOG START ${DateTime.now().toIso8601String()} ===\n',
      );

      _initialized = true;
      _capturing = true;

      _flushTimer = Timer.periodic(const Duration(seconds: 5), (_) => _flush());
      _flush();
    } catch (e) {
      debugPrintSynchronously('DebugLogger init error: $e');
    }
  }

  String _fileStamp() {
    final now = DateTime.now();
    return '${now.year}${_two(now.month)}${_two(now.day)}_'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  /// Dipanggil dari override debugPrint
  void append(String? message) {
    if (!_capturing || message == null) return;
    final ts = DateTime.now().toIso8601String();
    _buffer.add('[$ts] $message');
    if (_buffer.length > _maxBufferLines) {
      _buffer.removeRange(0, _buffer.length - _maxBufferLines);
    }
  }

  Future<void> _flush() async {
    if (_logFile == null || _buffer.isEmpty) return;
    try {
      final text = '${_buffer.join('\n')}\n';
      await _logFile!.writeAsString(text, mode: FileMode.append, flush: true);
      _buffer.clear();
    } catch (_) {}
  }

  /// Force flush (dipanggil sebelum export).
  Future<void> flushNow() => _flush();

  /// Export semua log ke file JSON.
  Future<File?> exportJson() async {
    await _flush();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) await logDir.create(recursive: true);

      final stamp = _fileStamp();
      final exportFile = File('${logDir.path}/export_$stamp.json');

      final allFiles = logDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.txt'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      final allLines = <String>[];
      for (final f in allFiles) {
        allLines.addAll(await f.readAsLines());
      }

      final data = {
        'exportedAt': DateTime.now().toIso8601String(),
        'platform': Platform.operatingSystem,
        'platformVersion': Platform.operatingSystemVersion,
        'totalLines': allLines.length,
        'logs': allLines,
      };

      await exportFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );
      return exportFile;
    } catch (e) {
      debugPrintSynchronously('Export JSON error: $e');
      return null;
    }
  }

  /// Export ringkas (text) untuk dibaca manusia.
  Future<File?> exportText() async {
    await _flush();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) await logDir.create(recursive: true);

      final stamp = _fileStamp();
      final exportFile = File('${logDir.path}/export_$stamp.txt');

      final allFiles = logDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.txt'))
          .where((f) => !f.path.contains('export_'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      final sb = StringBuffer();
      sb.writeln('=== EXPORT ${DateTime.now().toIso8601String()} ===');
      sb.writeln('Device: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
      sb.writeln();
      for (final f in allFiles) {
        sb.writeln('--- ${f.path.split('/').last} ---');
        sb.writeln(await f.readAsString());
      }

      await exportFile.writeAsString(sb.toString());
      return exportFile;
    } catch (e) {
      debugPrintSynchronously('Export TXT error: $e');
      return null;
    }
  }

  /// Hapus semua log lama.
  Future<void> clearAll() async {
    _flushTimer?.cancel();
    await _flush();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (await logDir.exists()) {
        await logDir.delete(recursive: true);
      }
      _buffer.clear();
      _logFile = null;
      _initialized = false;
      await init();
    } catch (_) {}
  }

  /// Jumlah baris di buffer (belum di-flush).
  int get bufferedLines => _buffer.length;

  /// Path log file aktif.
  String? get activeFilePath => _logFile?.path;
}