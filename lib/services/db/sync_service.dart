import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'database_service.dart';
import '../monotonic_clock.dart';

class SyncResult {
  final int embeddingsSynced;
  final int embeddingsFailed;
  final int attendanceSynced;
  final int attendanceFailed;
  final int sessionLogsSynced;
  final int sessionLogsFailed;
  final int faceAttemptsSynced;
  final int faceAttemptsFailed;
  final int gpsAttemptsSynced;
  final int gpsAttemptsFailed;
  final int photosUploaded;
  final int photosFailed;
  final int durationMs;

  SyncResult({
    this.embeddingsSynced = 0,
    this.embeddingsFailed = 0,
    this.attendanceSynced = 0,
    this.attendanceFailed = 0,
    this.sessionLogsSynced = 0,
    this.sessionLogsFailed = 0,
    this.faceAttemptsSynced = 0,
    this.faceAttemptsFailed = 0,
    this.gpsAttemptsSynced = 0,
    this.gpsAttemptsFailed = 0,
    this.photosUploaded = 0,
    this.photosFailed = 0,
    this.durationMs = 0,
  });

  bool get hasError =>
      embeddingsFailed > 0 ||
      attendanceFailed > 0 ||
      sessionLogsFailed > 0 ||
      faceAttemptsFailed > 0 ||
      gpsAttemptsFailed > 0 ||
      photosFailed > 0;

  @override
  String toString() {
    return 'SyncResult(emb=$embeddingsSynced/${embeddingsFailed}f, '
        'att=$attendanceSynced/${attendanceFailed}f, '
        'slog=$sessionLogsSynced/${sessionLogsFailed}f, '
        'fat=$faceAttemptsSynced/${faceAttemptsFailed}f, '
        'gat=$gpsAttemptsSynced/${gpsAttemptsFailed}f, '
        'photo=$photosUploaded/${photosFailed}f, ${durationMs}ms)';
  }
}

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final SupabaseClient _client = Supabase.instance.client;

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  static const String _photoBucket = 'face_photos';

  // Cache untuk isServerReachable
  DateTime? _lastReachableCheck;
  bool? _lastReachableResult;
  static const _reachableCacheDuration = Duration(seconds: 5);

  /// Sync semua pending data ke Supabase.
  Future<SyncResult> syncAll() async {
    if (_isSyncing) {
      debugPrint("SYNC: skip, sync sedang berjalan");
      return SyncResult();
    }

    final user = _client.auth.currentUser;
    if (user == null) {
      debugPrint("SYNC: skip, user tidak login");
      return SyncResult();
    }

    _isSyncing = true;
    final startTime = DateTime.now();
    final userId = user.id;

    int embOk = 0, embFail = 0;
    int attOk = 0, attFail = 0;
    int slOk = 0, slFail = 0;
    int faOk = 0, faFail = 0;
    int gaOk = 0, gaFail = 0;
    int photoOk = 0, photoFail = 0;

    try {
      // === 1. EMBEDDINGS ===
      final pendingEmb = await DatabaseService.instance.getPendingEmbeddings();
      debugPrint("SYNC: ${pendingEmb.length} embedding pending");
      for (final row in pendingEmb) {
        if (await _uploadEmbedding(row)) {
          await DatabaseService.instance.markEmbeddingSynced(row['id'] as int);
          embOk++;
        } else {
          embFail++;
        }
      }

      // === 2. SESSION LOGS ===
      final pendingSession = await DatabaseService.instance.getPendingSessionLogs();
      debugPrint("SYNC: ${pendingSession.length} session log pending");
      for (final row in pendingSession) {
        String? photoUrl = row['photo_url'] as String?;
        final photoPath = row['photo_path'] as String?;
        final sessionUuid = row['client_uuid'] as String?;

        if (photoPath != null && sessionUuid != null && photoUrl == null) {
          final uploaded = await _uploadPhoto(photoPath, userId, sessionUuid, 'session');
          if (uploaded != null) {
            photoUrl = uploaded;
            photoOk++;
          } else {
            photoFail++;
          }
        }

        if (await _uploadSessionLog(row, photoUrl)) {
          await DatabaseService.instance.markSessionLogSynced(
            row['id'] as int,
            photoUrl: photoUrl,
          );
          slOk++;
        } else {
          slFail++;
        }
      }

      // === 3. FACE ATTEMPTS ===
      final pendingFace = await DatabaseService.instance.getPendingFaceAttempts();
      debugPrint("SYNC: ${pendingFace.length} face attempt pending");
      for (final row in pendingFace) {
        if (await _uploadFaceAttempt(row)) {
          await DatabaseService.instance.markFaceAttemptSynced(row['id'] as int);
          faOk++;
        } else {
          faFail++;
        }
      }

      // === 4. GPS ATTEMPTS ===
      final pendingGps = await DatabaseService.instance.getPendingGpsAttempts();
      debugPrint("SYNC: ${pendingGps.length} gps attempt pending");
      for (final row in pendingGps) {
        if (await _uploadGpsAttempt(row)) {
          await DatabaseService.instance.markGpsAttemptSynced(row['id'] as int);
          gaOk++;
        } else {
          gaFail++;
        }
      }

      // === 5. ATTENDANCE ===
      final pendingAtt = await DatabaseService.instance.getPendingAttendance();
      debugPrint("SYNC: ${pendingAtt.length} attendance pending");
      for (final row in pendingAtt) {
        String? photoUrl = row['photo_url'] as String?;
        final photoPath = row['photo_path'] as String?;
        final clientUuid = row['client_uuid'] as String?;

        if (photoPath != null && clientUuid != null && photoUrl == null) {
          final uploaded = await _uploadPhoto(photoPath, userId, clientUuid, 'attendance');
          if (uploaded != null) {
            photoUrl = uploaded;
            photoOk++;
          } else {
            photoFail++;
          }
        }

        if (await _uploadAttendance(row, photoUrl)) {
          await DatabaseService.instance.markAttendanceSynced(
            row['id'] as int,
            photoUrl: photoUrl,
          );
          attOk++;
        } else {
          attFail++;
        }
      }

      // === 6. UPDATE ANCHOR ===
      await _updateAnchor(userId);

    } catch (e) {
      debugPrint("SYNC ERROR: $e");
    } finally {
      _isSyncing = false;
    }

    final result = SyncResult(
      embeddingsSynced: embOk,
      embeddingsFailed: embFail,
      attendanceSynced: attOk,
      attendanceFailed: attFail,
      sessionLogsSynced: slOk,
      sessionLogsFailed: slFail,
      faceAttemptsSynced: faOk,
      faceAttemptsFailed: faFail,
      gpsAttemptsSynced: gaOk,
      gpsAttemptsFailed: gaFail,
      photosUploaded: photoOk,
      photosFailed: photoFail,
      durationMs: DateTime.now().difference(startTime).inMilliseconds,
    );
    debugPrint("SYNC: selesai -> $result");
    return result;
  }

  // ============================================================
  // UPLOAD helpers
  // ============================================================
  Future<bool> _uploadEmbedding(Map<String, dynamic> row) async {
    final clientUuid = row['client_uuid'] as String?;
    if (clientUuid == null) return true;

    try {
      await _client.from('face_embeddings').insert({
        'client_uuid': clientUuid,
        'user_id': row['user_id'],
        'mode': row['mode'],
        'embedding': jsonDecode(row['embedding'] as String),
        'created_at': row['created_at'],
      });
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return true;
      debugPrint("SYNC: embedding $clientUuid gagal -> ${e.message}");
      return false;
    } catch (e) {
      debugPrint("SYNC: embedding $clientUuid gagal -> $e");
      return false;
    }
  }

  Future<bool> _uploadSessionLog(Map<String, dynamic> row, String? photoUrl) async {
    final clientUuid = row['client_uuid'] as String?;
    if (clientUuid == null) return true;

    try {
      await _client.from('session_logs').insert({
        'client_uuid': clientUuid,
        'user_id': row['user_id'],
        'session_type': row['session_type'],
        'started_at': row['started_at'],
        'camera_ready_at': row['camera_ready_at'],
        'first_face_at': row['first_face_at'],
        'mtcnn_ms_first': row['mtcnn_ms_first'],
        'mfn_ms_first': row['mfn_ms_first'],
        'match_ms_first': row['match_ms_first'],
        'mtcnn_ms_final': row['mtcnn_ms_final'],
        'mfn_ms_final': row['mfn_ms_final'],
        'match_ms_final': row['match_ms_final'],
        'face_valid_at': row['face_valid_at'],
        'failed_count': row['failed_count'],
        'gps_start_at': row['gps_start_at'],
        'gps_done_at': row['gps_done_at'],
        'gps_result': row['gps_result'],
        'gps_ms': row['gps_ms'],
        'final_status': row['final_status'],
        'final_at': row['final_at'],
        'photo_url': photoUrl,
        'device_uptime_ms': row['device_uptime_ms'],
        'device_boot_time_ms': row['device_boot_time_ms'],
        'lux_value': row['lux_value'],
      });
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return true;
      debugPrint("SYNC: session_logs $clientUuid gagal -> ${e.message}");
      return false;
    } catch (e) {
      debugPrint("SYNC: session_logs $clientUuid gagal -> $e");
      return false;
    }
  }

  Future<bool> _uploadFaceAttempt(Map<String, dynamic> row) async {
    final clientUuid = row['client_uuid'] as String?;
    if (clientUuid == null) return true;

    try {
      await _client.from('face_attempts').insert({
        'client_uuid': clientUuid,
        'session_uuid': row['session_uuid'],
        'user_id': row['user_id'],
        'attempt_number': row['attempt_number'],
        'attempted_at': row['attempted_at'],
        'mtcnn_status': row['mtcnn_status'],
        'mtcnn_ms': row['mtcnn_ms'],
        'mfn_status': row['mfn_status'],
        'mfn_ms': row['mfn_ms'],
        'match_distance': row['match_distance'],
        'lux_value': row['lux_value'],
      });
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return true;
      debugPrint("SYNC: face_attempts $clientUuid gagal -> ${e.message}");
      return false;
    } catch (e) {
      debugPrint("SYNC: face_attempts $clientUuid gagal -> $e");
      return false;
    }
  }

  Future<bool> _uploadGpsAttempt(Map<String, dynamic> row) async {
    final clientUuid = row['client_uuid'] as String?;
    if (clientUuid == null) return true;

    try {
      await _client.from('gps_attempts').insert({
        'client_uuid': clientUuid,
        'session_uuid': row['session_uuid'],
        'user_id': row['user_id'],
        'attempt_number': row['attempt_number'],
        'started_at': row['started_at'],
        'done_at': row['done_at'],
        'result': row['result'],
        'lat': row['lat'],
        'lng': row['lng'],
        'accuracy_meters': row['accuracy_meters'],
        'distance_to_school': row['distance_to_school'],
        'duration_ms': row['duration_ms'],
      });
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return true;
      debugPrint("SYNC: gps_attempts $clientUuid gagal -> ${e.message}");
      return false;
    } catch (e) {
      debugPrint("SYNC: gps_attempts $clientUuid gagal -> $e");
      return false;
    }
  }

  Future<bool> _uploadAttendance(Map<String, dynamic> row, String? photoUrl) async {
    final clientUuid = row['client_uuid'] as String?;
    if (clientUuid == null) return true;

    try {
      await _client.from('attendance').insert({
        'client_uuid': clientUuid,
        'user_id': row['user_id'],
        'recorded_at': row['recorded_at'],
        'recorded_date': row['recorded_date'],
        'local_timestamp': row['local_timestamp'],
        'lat': row['lat'],
        'lng': row['lng'],
        'distance_meters': row['distance_meters'],
        'match_distance': row['match_distance'],
        'match_mode': row['match_mode'],
        'connectivity_mode': row['connectivity_mode'],
        'is_late': (row['is_late'] as int) == 1,
        'is_izin': (row['is_izin'] as int? ?? 0) == 1,
        'izin_type': row['izin_type'],
        'photo_url': photoUrl,
      });
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return true;
      debugPrint("SYNC: attendance $clientUuid gagal -> ${e.message}");
      return false;
    } catch (e) {
      debugPrint("SYNC: attendance $clientUuid gagal -> $e");
      return false;
    }
  }

  Future<String?> _uploadPhoto(
    String localPath,
    String userId,
    String clientUuid,
    String type,
  ) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        debugPrint("SYNC: foto tidak ada di $localPath");
        return null;
      }

      final bytes = await file.readAsBytes();
      final storagePath = '$userId/${clientUuid}_$type.jpg';

      await _client.storage.from(_photoBucket).uploadBinary(
        storagePath,
        bytes,
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
      );

      return storagePath;
    } catch (e) {
      debugPrint("SYNC: upload foto gagal -> $e");
      return null;
    }
  }

  Future<void> _updateAnchor(String userId) async {
    try {
      final serverTimeResp = await _client.rpc('get_server_time');
      final serverTime = DateTime.parse(serverTimeResp.toString()).toUtc();

      final systemTime = DateTime.now().toUtc();
      final uptime = await MonotonicClock.elapsedRealtimeMs();

      if (uptime == null) {
        debugPrint("SYNC: tidak bisa ambil monotonic clock, skip anchor");
        return;
      }

      await DatabaseService.instance.saveAnchor(
        userId: userId,
        serverTime: serverTime,
        systemTime: systemTime,
        uptimeMs: uptime,
      );

      debugPrint("SYNC: anchor updated. server=$serverTime, uptime=${uptime}ms");
    } catch (e) {
      debugPrint("SYNC: update anchor gagal -> $e");
    }
  }

  /// Cek apakah server reachable (real ping ke Supabase).
  /// Hasil di-cache 5 detik supaya tidak spam.
  Future<bool> isServerReachable({bool useCache = true}) async {
    if (useCache && _lastReachableCheck != null) {
      final age = DateTime.now().difference(_lastReachableCheck!);
      if (age < _reachableCacheDuration && _lastReachableResult != null) {
        return _lastReachableResult!;
      }
    }
    try {
      await _client
          .from('sekolah')
          .select('id')
          .limit(1)
          .timeout(const Duration(seconds: 5));
      _lastReachableCheck = DateTime.now();
      _lastReachableResult = true;
      return true;
    } catch (e) {
      debugPrint("SYNC: server tidak reachable -> $e");
      _lastReachableCheck = DateTime.now();
      _lastReachableResult = false;
      return false;
    }
  }
}