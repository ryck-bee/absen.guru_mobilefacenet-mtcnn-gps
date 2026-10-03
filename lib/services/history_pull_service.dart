import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'photo_retention_service.dart';
import 'db/database_service.dart';

/// Tarik riwayat dari server ke lokal.
///
/// Dipakai saat:
///  - Login di device baru (DB lokal kosong).
///  - Manual refresh di HistoryScreen.
///
/// Foto di-download cuma untuk 7 attendance terbaru. FIFO 7 mengurus sisanya.
class HistoryPullService {
  static final HistoryPullService _instance = HistoryPullService._internal();
  factory HistoryPullService() => _instance;
  HistoryPullService._internal();

  final SupabaseClient _client = Supabase.instance.client;
  static const String _photoBucket = 'face_photos';
  static const int _photoLimit = 7;

  bool _isPulling = false;
  bool get isPulling => _isPulling;

  /// Konversi ISO dari server (UTC) ke waktu lokal device.
  String? _toLocal(String? iso) {
    if (iso == null) return null;
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return dt.toLocal().toIso8601String();
  }

  /// Pull attendance + session_logs + foto.
  Future<bool> pullForUser(String userId) async {
    if (_isPulling) return false;
    _isPulling = true;

    try {
      // 1. ATTENDANCE — server → lokal.
      final attendanceRows = await _client
          .from('attendance')
          .select()
          .eq('user_id', userId)
          .order('recorded_at', ascending: false)
          .timeout(const Duration(seconds: 10));

      debugPrint("PULL: ${attendanceRows.length} attendance dari server");

      for (final row in attendanceRows) {
        await DatabaseService.instance.insertAttendanceFromServer(
          Map<String, dynamic>.from(row as Map),
        );
      }

      // 2. SESSION_LOGS — server → lokal.
      final sessionRows = await _client
          .from('session_logs')
          .select()
          .eq('user_id', userId)
          .order('started_at', ascending: false)
          .timeout(const Duration(seconds: 10));

      debugPrint("PULL: ${sessionRows.length} session_logs dari server");

      for (final row in sessionRows) {
        await _insertSessionLogFromServer(
          userId,
          Map<String, dynamic>.from(row as Map),
        );
      }

      // 3. FOTO — 7 attendance terbaru.
      await _downloadRecentPhotos(userId, attendanceRows);

      // 4. RETENSI.
      await PhotoRetentionService().enforce(userId);
      await PhotoRetentionService().cleanupNonAttendanceFiles(userId);

      debugPrint("PULL: selesai untuk user=$userId");
      return true;
    } catch (e) {
      debugPrint("PULL: error -> $e");
      return false;
    } finally {
      _isPulling = false;
    }
  }

  Future<void> _insertSessionLogFromServer(
    String userId,
    Map<String, dynamic> row,
  ) async {
    final db = await DatabaseService.instance.database;
    await db.insert(
      'session_logs_local',
      {
        'client_uuid': row['client_uuid'],
        'user_id': userId,
        'session_type': row['session_type'],
        'started_at': _toLocal(row['started_at'] as String?),
        'camera_ready_at': _toLocal(row['camera_ready_at'] as String?),
        'first_face_at': _toLocal(row['first_face_at'] as String?),
        'mtcnn_ms_first': row['mtcnn_ms_first'],
        'mfn_ms_first': row['mfn_ms_first'],
        'match_ms_first': row['match_ms_first'],
        'mtcnn_ms_final': row['mtcnn_ms_final'],
        'mfn_ms_final': row['mfn_ms_final'],
        'match_ms_final': row['match_ms_final'],
        'face_valid_at': _toLocal(row['face_valid_at'] as String?),
        'failed_count': row['failed_count'] ?? 0,
        'gps_start_at': _toLocal(row['gps_start_at'] as String?),
        'gps_done_at': _toLocal(row['gps_done_at'] as String?),
        'gps_result': row['gps_result'],
        'gps_ms': row['gps_ms'],
        'final_status': row['final_status'],
        'final_at': _toLocal(row['final_at'] as String?),
        'photo_path': null,
        'raw_photo_path': null,
        'photo_url': row['photo_url'],
        'raw_photo_url': row['raw_photo_url'],
        'device_uptime_ms': row['device_uptime_ms'],
        'device_boot_time_ms': row['device_boot_time_ms'],
        'offline_duration_ms': row['offline_duration_ms'],
        'battery_level': row['battery_level'],
        'lux_value': row['lux_value'],
        'time_status': row['time_status'],
        'sync_status': 'synced',
        'synced_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> _downloadRecentPhotos(
    String userId,
    List<dynamic> attendanceRows,
  ) async {
    final photoDir = await DatabaseService.instance.getPhotoDir();
    final userDir = Directory(p.join(photoDir.path, userId));
    if (!await userDir.exists()) await userDir.create(recursive: true);

    int downloaded = 0;
    for (final row in attendanceRows) {
      if (downloaded >= _photoLimit) break;

      final map = Map<String, dynamic>.from(row as Map);
      final photoUrl = map['photo_url'] as String?;
      final clientUuid = map['client_uuid'] as String?;
      if (photoUrl == null || clientUuid == null) continue;

      final localPath = p.join(userDir.path, '${clientUuid}_success.jpg');
      if (await File(localPath).exists()) {
        downloaded++;
        continue;
      }

      try {
        final bytes = await _client.storage
            .from(_photoBucket)
            .download(photoUrl)
            .timeout(const Duration(seconds: 15));
        await File(localPath).writeAsBytes(bytes);
        await DatabaseService.instance.updateAttendancePhotoPath(
          clientUuid,
          localPath,
        );
        downloaded++;
        debugPrint("PULL: foto $clientUuid diunduh");
      } catch (e) {
        debugPrint("PULL: gagal unduh $photoUrl -> $e");
      }
    }

    debugPrint("PULL: $downloaded foto diunduh");
  }
}