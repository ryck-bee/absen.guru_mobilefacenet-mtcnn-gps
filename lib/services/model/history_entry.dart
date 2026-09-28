/// Status akhir satu hari di riwayat absen.
///
/// Prioritas menang (dari terkuat ke terlemah):
/// valid > izin > sakit > gagal > pending
enum HistoryStatus {
  valid,   // absen sukses, dalam radius
  izin,    // izin disetujui
  sakit,   // sakit disetujui
  gagal,   // semua sesi hari itu gagal, tidak ada attendance
  pending, // absen sukses tapi belum sync ke server
}

/// Satu card riwayat = satu hari.
///
/// Sumber:
///   - attendance_local  → valid, pending, izin, sakit
///   - session_logs_local → gagal, counter failedCount
class HistoryEntry {
  final DateTime date;          // tanggal (jam 00:00:00)
  final HistoryStatus status;

  // Dari attendance_local (kalau ada).
  final DateTime? recordedAt;   // jam absen/izin
  final double? distanceMeters; // jarak GPS ke sekolah
  final double? matchDistance;  // distance wajah
  final String? matchMode;      // 'non_glasses' | 'glasses'
  final String? izinType;       // 'izin' | 'sakit'
  final String? photoPath;      // foto lokal (bisa null kalau sudah dihapus)
  final String? photoUrl;       // foto server
  final String? syncStatus;     // 'pending' | 'synced'
  final String? sessionUuid;    // link ke session_logs

  // Counter dari session_logs_local.
  final int failedCount;        // jumlah sesi gagal di hari itu

  HistoryEntry({
    required this.date,
    required this.status,
    this.recordedAt,
    this.distanceMeters,
    this.matchDistance,
    this.matchMode,
    this.izinType,
    this.photoPath,
    this.photoUrl,
    this.syncStatus,
    this.sessionUuid,
    this.failedCount = 0,
  });

  /// Expired untuk card pending = recorded_at + 72 jam.
  /// Null kalau bukan pending.
  DateTime? get expiresAt {
    if (status != HistoryStatus.pending) return null;
    if (recordedAt == null) return null;
    return recordedAt!.add(const Duration(hours: 72));
  }

  /// Helper: true kalau hari ini punya foto (lokal atau server).
  bool get hasPhoto => photoPath != null || photoUrl != null;
}