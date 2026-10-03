import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'database_service.dart';
import '../photo_retention_service.dart';
import '../device_storage.dart';
import '../monotonic_clock.dart';
import '../../main.dart';

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

  DateTime? _lastReachableCheck;
  bool? _lastReachableResult;
  static const _reachableCacheDuration = Duration(seconds: 5);

  /// Konversi ISO string dari DB lokal (WIB, tanpa TZ) ke UTC.
  /// Kalau sudah ada TZ info, tidak double-convert.
  String? _toUtc(String? iso) {
    if (iso == null) return null;
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return dt.toUtc().toIso8601String();
  }

  /// Pastikan device terdaftar di Supabase. Insert/upsert sekali.
  /// Return device UUID yang siap dipakai sebagai `device_id`.
  Future<void> _ensureDeviceRegistered(String userId) async {
    // Sudah ada di global? Skip.
    if (gDeviceId.isNotEmpty) return;

    // Cek secure storage
    final local = await DeviceStorage.get();
    if (local != null && (local['registered'] as int? ?? 0) == 1) {
      final id = local['device_id'] as String?;
      if (id != null && id.isNotEmpty) {
        gDeviceId = id;
        debugPrint("DEVICE: loaded from secure storage, id=$gDeviceId");
        return;
      }
    }

    // Belum terdaftar. Coba insert ke Supabase.
    if (gAndroidId.isEmpty) {
      debugPrint("DEVICE: android_id kosong, skip register");
      return;
    }

    try {
      // Upsert: kalau android_id sudah ada, update user_id & return row
      await _client.from('devices').upsert({
        'user_id': userId,
        'android_id': gAndroidId,
        'model': gDeviceModel,
        'brand': gDeviceBrand,
        'android_version': gDeviceAndroid,
      }, onConflict: 'android_id');

      // Ambil id-nya
      final row = await _client
          .from('devices')
          .select('id')
          .eq('android_id', gAndroidId)
          .maybeSingle();

      if (row == null) {
        debugPrint("DEVICE: gagal ambil id setelah upsert");
        return;
      }

      gDeviceId = row['id'] as String;

      await DeviceStorage.save(
        deviceId: gDeviceId,
        androidId: gAndroidId,
        model: gDeviceModel,
        brand: gDeviceBrand,
        androidVersion: gDeviceAndroid,
        registered: true,
      );

      debugPrint("DEVICE: registered, id=$gDeviceId");
    } catch (e) {
      debugPrint("DEVICE: register error -> $e");
      await DeviceStorage.save(
        deviceId: null,
        androidId: gAndroidId,
        model: gDeviceModel,
        brand: gDeviceBrand,
        androidVersion: gDeviceAndroid,
        registered: false,
      );
    }
  }

  /// Tarik hari libur dari Supabase.
  /// Filter: dari hari ini sampai (tahun depan) 31 Desember.
  /// Skip kalau lokal sudah punya data sampai minimal 30 hari sebelum end.
  Future<void> _syncHariLibur() async {
    try {
      final now = DateTime.now();
      final endDate = DateTime(now.year + 1, 12, 31);
      final threshold = endDate.subtract(const Duration(days: 30));

      final maxLocal = await DatabaseService.instance.getMaxTanggalLibur();
      if (maxLocal != null) {
        final maxDate = DateTime.tryParse(maxLocal);
        if (maxDate != null && maxDate.isAfter(threshold)) {
          debugPrint("SYNC: libur lokal cukup (max=$maxLocal), skip");
          return;
        }
      }

      final startStr = _dateOnly(now);
      final endStr = _dateOnly(endDate);

      final rows = await _client
          .from('hari_libur')
          .select()
          .gte('tanggal', startStr)
          .lte('tanggal', endStr)
          .timeout(const Duration(seconds: 5));

      if (rows.isEmpty) {
        debugPrint("SYNC: 0 hari libur di server");
        return;
      }

      await DatabaseService.instance.clearHariLibur();
      await DatabaseService.instance.saveHariLiburBulk(
        rows.map((r) => Map<String, dynamic>.from(r as Map)).toList(),
      );
      debugPrint("SYNC: ${rows.length} hari libur ditarik");
    } catch (e) {
      debugPrint("SYNC: tarik hari libur gagal -> $e");
    }
  }

  String _dateOnly(DateTime d) {
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

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
      // === 0a. DEVICE REGISTRATION ===
      await _ensureDeviceRegistered(userId);

      // === 0b. HARI LIBUR ===
      await _syncHariLibur();

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
      final pendingSession =
          await DatabaseService.instance.getPendingSessionLogs();
      debugPrint("SYNC: ${pendingSession.length} session log pending");
      for (final row in pendingSession) {
        String? photoUrl = row['photo_url'] as String?;
        String? rawPhotoUrl = row['raw_photo_url'] as String?;
        final photoPath = row['photo_path'] as String?;
        final rawPhotoPath = row['raw_photo_path'] as String?;
        final sessionUuid = row['client_uuid'] as String?;

        if (photoPath != null && sessionUuid != null && photoUrl == null) {
          final uploaded =
              await _uploadPhoto(photoPath, userId, sessionUuid, 'session');
          if (uploaded != null) {
            photoUrl = uploaded;
            photoOk++;
          } else {
            photoFail++;
          }
        }

        if (rawPhotoPath != null &&
            sessionUuid != null &&
            rawPhotoUrl == null) {
          final uploaded =
              await _uploadPhoto(rawPhotoPath, userId, sessionUuid, 'raw');
          if (uploaded != null) {
            rawPhotoUrl = uploaded;
            photoOk++;
          } else {
            photoFail++;
          }
        }

        if (await _uploadSessionLog(row, photoUrl, rawPhotoUrl)) {
          await DatabaseService.instance.markSessionLogSynced(
            row['id'] as int,
            photoUrl: photoUrl,
            rawPhotoUrl: rawPhotoUrl,
          );
          slOk++;
        } else {
          slFail++;
        }
      }

      // === 3. FACE ATTEMPTS ===
      final pendingFace =
          await DatabaseService.instance.getPendingFaceAttempts();
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
          final uploaded =
              await _uploadPhoto(photoPath, userId, clientUuid, 'attendance');
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

      // === 7. RETENSI FOTO ===
      await PhotoRetentionService().enforce(userId);
      await PhotoRetentionService().cleanupNonAttendanceFiles(userId);
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
  String? get _deviceIdOrNull => gDeviceId.isEmpty ? null : gDeviceId;

  Future<bool> _uploadEmbedding(Map<String, dynamic> row) async {
    final clientUuid = row['client_uuid'] as String?;
    if (clientUuid == null) return true;

    try {
      await _client.from('face_embeddings').insert({
        'client_uuid': clientUuid,
        'user_id': row['user_id'],
        'mode': row['mode'],
        'embedding': jsonDecode(row['embedding'] as String),
        'created_at': _toUtc(row['created_at'] as String?),
        'device_id': _deviceIdOrNull,
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

  Future<bool> _uploadSessionLog(
      Map<String, dynamic> row, String? photoUrl, String? rawPhotoUrl) async {
    final clientUuid = row['client_uuid'] as String?;
    if (clientUuid == null) return true;

    try {
      await _client.from('session_logs').insert({
        'client_uuid': clientUuid,
        'user_id': row['user_id'],
        'session_type': row['session_type'],
        'started_at': _toUtc(row['started_at'] as String?),
        'camera_ready_at': _toUtc(row['camera_ready_at'] as String?),
        'first_face_at': _toUtc(row['first_face_at'] as String?),
        'mtcnn_ms_first': row['mtcnn_ms_first'],
        'mfn_ms_first': row['mfn_ms_first'],
        'match_ms_first': row['match_ms_first'],
        'mtcnn_ms_final': row['mtcnn_ms_final'],
        'mfn_ms_final': row['mfn_ms_final'],
        'match_ms_final': row['match_ms_final'],
        'face_valid_at': _toUtc(row['face_valid_at'] as String?),
        'failed_count': row['failed_count'],
        'gps_start_at': _toUtc(row['gps_start_at'] as String?),
        'gps_done_at': _toUtc(row['gps_done_at'] as String?),
        'gps_result': row['gps_result'],
        'gps_ms': row['gps_ms'],
        'final_status': row['final_status'],
        'final_at': _toUtc(row['final_at'] as String?),
        'photo_url': photoUrl,
        'raw_photo_url': rawPhotoUrl,
        'device_uptime_ms': row['device_uptime_ms'],
        'device_boot_time_ms': row['device_boot_time_ms'],
        'lux_value': row['lux_value'],
        'offline_duration_ms': row['offline_duration_ms'],
        'battery_level': row['battery_level'],
        'time_status': row['time_status'],
        'device_id': _deviceIdOrNull,
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
        'attempted_at': _toUtc(row['attempted_at'] as String?),
        'mtcnn_status': row['mtcnn_status'],
        'mtcnn_ms': row['mtcnn_ms'],
        'mfn_status': row['mfn_status'],
        'mfn_ms': row['mfn_ms'],
        'match_distance': row['match_distance'],
        'lux_value': row['lux_value'],
        'device_id': _deviceIdOrNull,
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
        'started_at': _toUtc(row['started_at'] as String?),
        'done_at': _toUtc(row['done_at'] as String?),
        'result': row['result'],
        'lat': row['lat'],
        'lng': row['lng'],
        'accuracy_meters': row['accuracy_meters'],
        'distance_to_school': row['distance_to_school'],
        'duration_ms': row['duration_ms'],
        'device_id': _deviceIdOrNull,
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

  Future<bool> _uploadAttendance(
      Map<String, dynamic> row, String? photoUrl) async {
    final clientUuid = row['client_uuid'] as String?;
    if (clientUuid == null) return true;

    try {
      await _client.from('attendance').insert({
        'client_uuid': clientUuid,
        'user_id': row['user_id'],
        'recorded_at': _toUtc(row['recorded_at'] as String?),
        'recorded_date': row['recorded_date'],
        'local_timestamp': _toUtc(row['local_timestamp'] as String?),
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
        'device_id': _deviceIdOrNull,
      });

      // Ambil balik status dari server (trigger BEFORE INSERT sudah set).
      try {
        final serverRow = await _client
            .from('attendance')
            .select('status, reject_reason, validated_at')
            .eq('client_uuid', clientUuid)
            .maybeSingle();

        if (serverRow != null) {
          await DatabaseService.instance.updateAttendanceServerStatus(
            clientUuid,
            status: (serverRow['status'] as String?) ?? 'PENDING',
            rejectReason: serverRow['reject_reason'] as String?,
            validatedAt: serverRow['validated_at'] as String?,
          );
        }
      } catch (e) {
        debugPrint("SYNC: fetch status server gagal -> $e");
      }

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
        fileOptions:
            const FileOptions(contentType: 'image/jpeg', upsert: true),
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