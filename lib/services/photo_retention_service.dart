import 'dart:io';
import 'package:flutter/foundation.dart';

import 'db/database_service.dart';

/// Aturan retensi file foto lokal.
///
/// - Attendance synced: simpan maksimal 7 file terbaru (FIFO).
/// - File raw/failed/gps_failed: hapus setelah sync sukses (nggak dipakai UI).
/// - File pending: JANGAN dihapus — tunggu sync dulu.
class PhotoRetentionService {
  static final PhotoRetentionService _instance =
      PhotoRetentionService._internal();
  factory PhotoRetentionService() => _instance;
  PhotoRetentionService._internal();

  static const int _maxAttendancePhotos = 7;

  /// Jalankan aturan retensi untuk user ini.
  /// Panggil setelah syncAll() sukses atau setelah pull.
  Future<void> enforce(String userId) async {
    try {
      await _enforceAttendanceFifo(userId);
    } catch (e) {
      debugPrint("RETENTION: error -> $e");
    }
  }

  /// Hapus file attendance paling lama kalau > 7.
  /// Cuma hitung yang sync_status = 'synced' dan photo_path != null.
  Future<void> _enforceAttendanceFifo(String userId) async {
    final db = await DatabaseService.instance.database;

    final rows = await db.query(
      'attendance_local',
      columns: ['id', 'photo_path'],
      where: "user_id = ? AND sync_status = 'synced' AND photo_path IS NOT NULL",
      whereArgs: [userId],
      orderBy: 'recorded_at DESC',
    );

    if (rows.length <= _maxAttendancePhotos) return;

    final toDelete = rows.sublist(_maxAttendancePhotos);
    int deleted = 0;

    for (final row in toDelete) {
      final path = row['photo_path'] as String?;
      final id = row['id'] as int;

      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (e) {
          debugPrint("RETENTION: gagal hapus file $path -> $e");
        }
      }

      await db.update(
        'attendance_local',
        {'photo_path': null},
        where: 'id = ?',
        whereArgs: [id],
      );
      deleted++;
    }

    if (deleted > 0) {
      debugPrint(
          "RETENTION: FIFO $userId -> $deleted foto dihapus (sisakan $_maxAttendancePhotos)");
    }
  }

  /// Hapus file non-attendance (raw, failed, gps_failed) yang sudah synced.
  /// Panggil ini terpisah setelah syncAll sukses.
  Future<void> cleanupNonAttendanceFiles(String userId) async {
    try {
      final db = await DatabaseService.instance.database;

      final sessions = await db.query(
        'session_logs_local',
        columns: ['id', 'photo_path', 'raw_photo_path', 'final_status'],
        where: "user_id = ? AND sync_status = 'synced'",
        whereArgs: [userId],
      );

      int deleted = 0;
      for (final row in sessions) {
        final photoPath = row['photo_path'] as String?;
        final rawPath = row['raw_photo_path'] as String?;
        final finalStatus = row['final_status'] as String?;

        // Hapus file `_raw.jpg` (arsip ada di server).
        if (rawPath != null) {
          try {
            final f = File(rawPath);
            if (await f.exists()) await f.delete();
            deleted++;
          } catch (_) {}
        }

        // Hapus file sesi gagal. Sesi sukses diurus FIFO attendance.
        if (photoPath != null && finalStatus != 'success') {
          try {
            final f = File(photoPath);
            if (await f.exists()) await f.delete();
            deleted++;
          } catch (_) {}
        }

        // Update kolom — cuma kalau ada yang perlu di-null.
        final updates = <String, dynamic>{};
        if (rawPath != null) updates['raw_photo_path'] = null;
        if (photoPath != null && finalStatus != 'success') {
          updates['photo_path'] = null;
        }

        if (updates.isNotEmpty) {
          await db.update(
            'session_logs_local',
            updates,
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }

      if (deleted > 0) {
        debugPrint(
            "RETENTION: cleanup non-attendance $userId -> $deleted file dihapus");
      }
    } catch (e) {
      debugPrint("RETENTION: cleanup error -> $e");
    }
  }
}