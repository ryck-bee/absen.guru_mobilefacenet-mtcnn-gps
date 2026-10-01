import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../db/database_service.dart';
import '../monotonic_clock.dart';

enum TimeStatus {
  verified,
  noAnchor,
  restart,
  mismatch;

  String get dbValue {
    switch (this) {
      case TimeStatus.verified:
        return 'verified';
      case TimeStatus.noAnchor:
        return 'no_anchor';
      case TimeStatus.restart:
        return 'restart';
      case TimeStatus.mismatch:
        return 'mismatch';
    }
  }
}

class TimeVerifier {
  TimeVerifier._();

  static const Duration _onlineMargin = Duration(seconds: 60);
  static const Duration _offlineMargin = Duration(minutes: 5);
  static const Duration _onlineTimeout = Duration(seconds: 5);

  /// Cek integritas waktu. Return:
  ///   verified  — waktu HP cocok dengan server/anchor
  ///   noAnchor  — belum ada anchor (belum sync)
  ///   restart   — HP baru restart (uptime reset)
  ///   mismatch  — jam HP dimanipulasi (selisih > margin)
  static Future<TimeStatus> check() async {
    try {
      final anchor = await DatabaseService.instance.getAnchor();
      if (anchor == null) {
        debugPrint("TIME: no anchor");
        return TimeStatus.noAnchor;
      }

      final uptimeNow = await MonotonicClock.elapsedRealtimeMs();
      if (uptimeNow == null) {
        debugPrint("TIME: uptime null");
        return TimeStatus.noAnchor;
      }

      final uptimeAtSync = (anchor['uptime_at_sync_ms'] as num).toInt();

      if (uptimeNow < uptimeAtSync) {
        debugPrint("TIME: restart (now=$uptimeNow < sync=$uptimeAtSync)");
        return TimeStatus.restart;
      }

      // Coba online dulu
      final onlineStatus = await _checkOnline();
      if (onlineStatus != null) {
        debugPrint("TIME: online -> $onlineStatus");
        return onlineStatus;
      }

      // Fallback offline
      final offlineStatus = _checkOffline(anchor, uptimeNow, uptimeAtSync);
      debugPrint("TIME: offline -> $offlineStatus");
      return offlineStatus;
    } catch (e) {
      debugPrint("TIME: verify error -> $e");
      return TimeStatus.noAnchor;
    }
  }

  static Future<TimeStatus?> _checkOnline() async {
    try {
      final resp = await Supabase.instance.client
          .rpc('get_server_time')
          .timeout(_onlineTimeout);
      final serverTime = DateTime.parse(resp.toString()).toUtc();
      final localTime = DateTime.now().toUtc();
      final diff = serverTime.difference(localTime).abs();
      if (diff > _onlineMargin) {
        debugPrint("TIME: online mismatch (diff=${diff.inSeconds}s)");
        return TimeStatus.mismatch;
      }
      return TimeStatus.verified;
    } catch (_) {
      return null;
    }
  }

  static TimeStatus _checkOffline(
    Map<String, dynamic> anchor,
    int uptimeNow,
    int uptimeAtSync,
  ) {
    final serverTimeAtSync =
        DateTime.parse(anchor['server_time_at_sync'] as String);
    final elapsedMs = uptimeNow - uptimeAtSync;
    final predicted = serverTimeAtSync.add(Duration(milliseconds: elapsedMs));
    final localTime = DateTime.now();
    final diff = predicted.difference(localTime).abs();
    if (diff > _offlineMargin) {
      debugPrint("TIME: offline mismatch (diff=${diff.inMinutes}min)");
      return TimeStatus.mismatch;
    }
    return TimeStatus.verified;
  }
}