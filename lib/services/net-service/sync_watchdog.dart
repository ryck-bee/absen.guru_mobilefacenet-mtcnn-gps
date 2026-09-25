import 'dart:async';
import 'package:flutter/foundation.dart';
import '../db/database_service.dart';
import '../db/sync_service.dart';

/// Watchdog sinkronisasi.
///
/// Aktif hanya kalau ada pending di SQLite lokal.
/// Saat aktif: coba ping Supabase + sync, dengan backoff bertingkat.
/// Saat pending habis: mati total. Tidak bangun sampai ada trigger baru.
class SyncWatchdog {
  static final SyncWatchdog _instance = SyncWatchdog._();
  factory SyncWatchdog() => _instance;
  SyncWatchdog._();

  /// Interval antar-percobaan (detik).
  /// Index 0 = percobaan pertama (langsung).
  /// Index 1 = setelah gagal pertama, tunggu 30s.
  /// Index 2 = setelah gagal kedua, tunggu 60s.
  /// Index 3 = 150s. Index 4+ = 300s (cap).
  static const List<int> _intervalsSec = [0, 30, 60, 150, 300];
  static const int _capIndex = 4;

  Timer? _timer;
  int _attemptIndex = 0;
  bool _active = false;
  bool _running = false;

  bool get isActive => _active;

  /// Pemicu dari luar:
  /// - bootstrap sync selesai
  /// - post-session sync selesai
  /// - network berubah (dari NetworkMonitor)
  ///
  /// Selalu reset backoff dan coba instan dulu.
  Future<void> notify() async {
    // Cek pending dulu. Kalau tidak ada, tidak usah aktif.
    bool hasPending;
    try {
      hasPending = await DatabaseService.instance.hasAnyPending();
    } catch (e) {
      debugPrint("WATCHDOG: cek pending error → $e");
      return;
    }

    if (!hasPending) {
      _stop();
      debugPrint("WATCHDOG: no pending → idle");
      return;
    }

    debugPrint("WATCHDOG: pending detected → activating");
    _active = true;
    _attemptIndex = 0;
    _scheduleNext();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _active = false;
    _attemptIndex = 0;
  }

  void _scheduleNext() {
    _timer?.cancel();

    final idx = _attemptIndex > _capIndex ? _capIndex : _attemptIndex;
    final delaySec = _intervalsSec[idx];
    final delay = Duration(seconds: delaySec);

    debugPrint("WATCHDOG: attempt #${_attemptIndex + 1}, next in ${delaySec}s");

    if (delaySec == 0) {
      // Instan.
      _timer = Timer(Duration.zero, _tick);
    } else {
      _timer = Timer(delay, _tick);
    }
  }

  Future<void> _tick() async {
    if (_running) return;
    _running = true;
    try {
      // 1. Cek pending
      final hasPending = await DatabaseService.instance.hasAnyPending();
      if (!hasPending) {
        debugPrint("WATCHDOG: pending cleared → idle");
        _stop();
        return;
      }

      // 2. Ping Supabase
      final reachable = await SyncService().isServerReachable();
      if (!reachable) {
        debugPrint("WATCHDOG: server unreachable → backoff");
        _attemptIndex++;
        _scheduleNext();
        return;
      }

      // 3. Sync
      debugPrint("WATCHDOG: syncing...");
      final result = await SyncService().syncAll();
      debugPrint("WATCHDOG: sync = $result");

      // 4. Cek pending setelah sync
      final stillPending = await DatabaseService.instance.hasAnyPending();
      if (!stillPending) {
        debugPrint("WATCHDOG: all synced → idle");
        _stop();
        return;
      }

      // 5. Masih ada → backoff
      _attemptIndex++;
      _scheduleNext();
    } catch (e) {
      debugPrint("WATCHDOG: error → $e");
      _attemptIndex++;
      _scheduleNext();
    } finally {
      _running = false;
    }
  }
}