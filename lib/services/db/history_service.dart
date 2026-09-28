import 'package:sqflite/sqflite.dart';
import '../model/history_entry.dart';
import 'database_service.dart';

/// Service query + agregasi riwayat absen.
///
/// Menggabungkan:
///   - attendance_local  → valid, pending, izin, sakit
///   - session_logs_local → hitung gagal per hari + card "gagal murni"
///
/// Aturan: 1 hari = 1 entry. Prioritas menang:
///   valid > izin > sakit > gagal > pending
class HistoryService {
  static final HistoryService _instance = HistoryService._internal();
  factory HistoryService() => _instance;
  HistoryService._internal();

  /// Ambil semua riwayat absen untuk 1 bulan tertentu.
  /// [month] cukup tahun + bulannya saja (hari diabaikan).
  /// Hasil di-sort descending (tanggal terbaru di atas).
  Future<List<HistoryEntry>> loadMonth({
    required String userId,
    required DateTime month,
  }) async {
    final db = await DatabaseService.instance.database;

    final startOfMonth = DateTime(month.year, month.month, 1);
    final startOfNextMonth = DateTime(month.year, month.month + 1, 1);

    final startDate = _dateOnly(startOfMonth);
    final endDate = _dateOnly(
      startOfNextMonth.subtract(const Duration(days: 1)),
    );

    // === 1. Attendance bulan ini ===
    final attendanceRows = await db.query(
      'attendance_local',
      where: 'user_id = ? AND recorded_date >= ? AND recorded_date <= ?',
      whereArgs: [userId, startDate, endDate],
      orderBy: 'recorded_date ASC',
    );

    // === 2. Session logs bulan ini ===
    final sessionRows = await db.query(
      'session_logs_local',
      where: 'user_id = ? AND started_at >= ? AND started_at < ?',
      whereArgs: [
        userId,
        startOfMonth.toIso8601String(),
        startOfNextMonth.toIso8601String(),
      ],
      orderBy: 'started_at ASC',
    );

    // === 3. Hitung gagal per tanggal ===
    final Map<String, int> failedCountByDate = {};
    for (final row in sessionRows) {
      final startedAt = DateTime.tryParse(row['started_at'] as String? ?? '');
      if (startedAt == null) continue;

      final finalStatus = row['final_status'] as String? ?? '';
      if (finalStatus == 'success') continue;

      final dateKey = _dateOnly(startedAt);
      failedCountByDate[dateKey] = (failedCountByDate[dateKey] ?? 0) + 1;
    }

    // === 4. Group attendance per tanggal, ambil yang menang ===
    final Map<String, Map<String, dynamic>> attendanceByDate = {};
    for (final row in attendanceRows) {
      final dateKey = row['recorded_date'] as String;
      final existing = attendanceByDate[dateKey];
      if (existing == null) {
        attendanceByDate[dateKey] = row;
      } else if (_attendanceRank(row) < _attendanceRank(existing)) {
        attendanceByDate[dateKey] = row;
      }
    }

    // === 5. Semua tanggal yang ada aktivitas ===
    final allDates = <String>{};
    allDates.addAll(attendanceByDate.keys);
    allDates.addAll(failedCountByDate.keys);

    // === 6. Bangun entry ===
    final entries = <HistoryEntry>[];
    for (final dateKey in allDates) {
      final att = attendanceByDate[dateKey];
      final failedCount = failedCountByDate[dateKey] ?? 0;
      final date = DateTime.parse(dateKey);

      if (att != null) {
        entries.add(_buildFromAttendance(date, att, failedCount));
      } else {
        entries.add(HistoryEntry(
          date: date,
          status: HistoryStatus.gagal,
          failedCount: failedCount,
        ));
      }
    }

    // === 7. Sort descending ===
    entries.sort((a, b) => b.date.compareTo(a.date));
    return entries;
  }

  /// Rank untuk pilih row attendance yang menang kalau 1 hari ada >1 row.
  /// Makin kecil = makin kuat.
  int _attendanceRank(Map<String, dynamic> row) {
    final isIzin = (row['is_izin'] as int? ?? 0) == 1;
    final syncStatus = row['sync_status'] as String? ?? 'pending';

    if (isIzin) return 2; // izin / sakit
    if (syncStatus == 'synced') return 1; // valid
    return 3; // pending absen
  }

  HistoryEntry _buildFromAttendance(
    DateTime date,
    Map<String, dynamic> row,
    int failedCount,
  ) {
    final isIzin = (row['is_izin'] as int? ?? 0) == 1;
    final syncStatus = row['sync_status'] as String? ?? 'pending';
    final izinType = row['izin_type'] as String?;

    HistoryStatus status;
    if (isIzin) {
      status = izinType == 'sakit' ? HistoryStatus.sakit : HistoryStatus.izin;
    } else if (syncStatus == 'synced') {
      status = HistoryStatus.valid;
    } else {
      status = HistoryStatus.pending;
    }

    return HistoryEntry(
      date: date,
      status: status,
      recordedAt: DateTime.tryParse(row['recorded_at'] as String? ?? ''),
      distanceMeters: (row['distance_meters'] as num?)?.toDouble(),
      matchDistance: (row['match_distance'] as num?)?.toDouble(),
      matchMode: row['match_mode'] as String?,
      izinType: izinType,
      photoPath: row['photo_path'] as String?,
      photoUrl: row['photo_url'] as String?,
      syncStatus: syncStatus,
      sessionUuid: row['session_uuid'] as String?,
      failedCount: failedCount,
    );
  }

  /// Format DateTime → 'YYYY-MM-DD' (sama dengan recorded_date di DB).
  String _dateOnly(DateTime d) {
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}