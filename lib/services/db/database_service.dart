import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Service SQLite lokal untuk offline-first.
class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  Database? _db;
  static const int _dbVersion = 10;
  static const String _dbName = 'absensi_wajah.db';
  static const _uuid = Uuid();

  Future<void> init() async {
    if (_db != null) return;

    final dbPath = await getDatabasesPath();
    final fullPath = p.join(dbPath, _dbName);

    _db = await openDatabase(
      fullPath,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );

    debugPrint("DB: SQLite initialized at $fullPath");
  }

  Future<Database> get database async {
    if (_db == null) await init();
    return _db!;
  }

  Future<Directory> getPhotoDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'photos'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ============================================================
  // SCHEMA
  // ============================================================
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE users_local (
        user_id TEXT PRIMARY KEY,
        nip TEXT,
        nama_lengkap TEXT,
        role TEXT,
        sekolah_id TEXT,
        logged_in_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE sekolah_local (
        sekolah_id TEXT PRIMARY KEY,
        nama TEXT,
        lat REAL,
        lng REAL,
        radius_meters REAL,
        updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE embeddings_local (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        client_uuid TEXT,
        user_id TEXT NOT NULL,
        mode TEXT NOT NULL,
        embedding TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'registration',
        created_at TEXT NOT NULL,
        sync_status TEXT NOT NULL DEFAULT 'pending',
        synced_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE attendance_local (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        client_uuid TEXT,
        session_uuid TEXT,
        user_id TEXT NOT NULL,
        recorded_at TEXT NOT NULL,
        recorded_date TEXT,
        local_timestamp TEXT NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        distance_meters REAL,
        match_distance REAL NOT NULL,
        match_mode TEXT NOT NULL,
        connectivity_mode TEXT NOT NULL,
        is_late INTEGER NOT NULL DEFAULT 0,
        is_izin INTEGER NOT NULL DEFAULT 0,
        izin_type TEXT,
        photo_path TEXT,
        photo_url TEXT,
        sync_status TEXT NOT NULL DEFAULT 'pending',
        synced_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE session_logs_local (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        client_uuid TEXT UNIQUE,
        user_id TEXT NOT NULL,
        session_type TEXT NOT NULL,
        started_at TEXT NOT NULL,
        camera_ready_at TEXT,
        first_face_at TEXT,
        mtcnn_ms_first INTEGER,
        mfn_ms_first INTEGER,
        match_ms_first INTEGER,
        mtcnn_ms_final INTEGER,
        mfn_ms_final INTEGER,
        match_ms_final INTEGER,
        face_valid_at TEXT,
        failed_count INTEGER NOT NULL DEFAULT 0,
        gps_start_at TEXT,
        gps_done_at TEXT,
        gps_result TEXT,
        gps_ms INTEGER,
        final_status TEXT NOT NULL,
        final_at TEXT NOT NULL,
        photo_path TEXT,
        device_uptime_ms INTEGER,
        device_boot_time_ms INTEGER,
        lux_value INTEGER,
        photo_url TEXT,
        sync_status TEXT NOT NULL DEFAULT 'pending',
        synced_at TEXT
        time_status TEXT,
      )
    ''');

    await db.execute('''
      CREATE TABLE face_attempts_local (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        client_uuid TEXT UNIQUE,
        session_uuid TEXT NOT NULL,
        user_id TEXT NOT NULL,
        attempt_number INTEGER NOT NULL,
        attempted_at TEXT NOT NULL,
        mtcnn_status TEXT NOT NULL,
        mtcnn_ms INTEGER,
        mfn_status TEXT,
        mfn_ms INTEGER,
        match_distance REAL,
        lux_value INTEGER,
        sync_status TEXT NOT NULL DEFAULT 'pending',
        synced_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE gps_attempts_local (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        client_uuid TEXT UNIQUE,
        session_uuid TEXT NOT NULL,
        user_id TEXT NOT NULL,
        attempt_number INTEGER NOT NULL,
        started_at TEXT NOT NULL,
        done_at TEXT,
        result TEXT NOT NULL,
        lat REAL,
        lng REAL,
        accuracy_meters REAL,
        distance_to_school REAL,
        duration_ms INTEGER,
        sync_status TEXT NOT NULL DEFAULT 'pending',
        synced_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE trusted_time_anchor_local (
        user_id TEXT PRIMARY KEY,
        server_time_at_sync TEXT NOT NULL,
        system_time_at_sync TEXT NOT NULL,
        uptime_at_sync_ms INTEGER NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE device_local (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        device_id TEXT,
        android_id TEXT,
        model TEXT,
        brand TEXT,
        android_version TEXT,
        registered INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('CREATE INDEX idx_embeddings_sync ON embeddings_local(sync_status)');
    await db.execute('CREATE INDEX idx_attendance_sync ON attendance_local(sync_status)');
    await db.execute('CREATE INDEX idx_session_logs_sync ON session_logs_local(sync_status)');
    await db.execute('CREATE INDEX idx_face_attempts_sync ON face_attempts_local(sync_status)');
    await db.execute('CREATE INDEX idx_gps_attempts_sync ON gps_attempts_local(sync_status)');

    debugPrint("DB: Tables created (v$version)");
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    debugPrint("DB: Upgrade from v$oldVersion to v$newVersion");

    if (oldVersion < 2) {
      await db.execute('ALTER TABLE embeddings_local ADD COLUMN client_uuid TEXT');
      await db.execute('ALTER TABLE attendance_local ADD COLUMN client_uuid TEXT');
    }

    if (oldVersion < 3) {
      await db.execute('ALTER TABLE attendance_local ADD COLUMN session_uuid TEXT');
      await db.execute('ALTER TABLE attendance_local ADD COLUMN photo_path TEXT');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS session_logs_local (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          client_uuid TEXT UNIQUE,
          user_id TEXT NOT NULL,
          session_type TEXT NOT NULL,
          started_at TEXT NOT NULL,
          camera_ready_at TEXT,
          first_face_at TEXT,
          mtcnn_ms_first INTEGER,
          mfn_ms_first INTEGER,
          match_ms_first INTEGER,
          mtcnn_ms_final INTEGER,
          mfn_ms_final INTEGER,
          match_ms_final INTEGER,
          face_valid_at TEXT,
          failed_count INTEGER NOT NULL DEFAULT 0,
          gps_start_at TEXT,
          gps_done_at TEXT,
          gps_result TEXT,
          gps_ms INTEGER,
          final_status TEXT NOT NULL,
          final_at TEXT NOT NULL,
          photo_path TEXT,
          sync_status TEXT NOT NULL DEFAULT 'pending',
          synced_at TEXT
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS face_attempts_local (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          client_uuid TEXT UNIQUE,
          session_uuid TEXT NOT NULL,
          user_id TEXT NOT NULL,
          attempt_number INTEGER NOT NULL,
          attempted_at TEXT NOT NULL,
          mtcnn_status TEXT NOT NULL,
          mtcnn_ms INTEGER,
          mfn_status TEXT,
          mfn_ms INTEGER,
          match_distance REAL,
          sync_status TEXT NOT NULL DEFAULT 'pending',
          synced_at TEXT
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS gps_attempts_local (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          client_uuid TEXT UNIQUE,
          session_uuid TEXT NOT NULL,
          user_id TEXT NOT NULL,
          attempt_number INTEGER NOT NULL,
          started_at TEXT NOT NULL,
          done_at TEXT,
          result TEXT NOT NULL,
          lat REAL,
          lng REAL,
          accuracy_meters REAL,
          distance_to_school REAL,
          duration_ms INTEGER,
          sync_status TEXT NOT NULL DEFAULT 'pending',
          synced_at TEXT
        )
      ''');
    }

    if (oldVersion < 4) {
      await db.execute('ALTER TABLE session_logs_local ADD COLUMN device_uptime_ms INTEGER');
      await db.execute('ALTER TABLE session_logs_local ADD COLUMN device_boot_time_ms INTEGER');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS trusted_time_anchor_local (
          user_id TEXT PRIMARY KEY,
          server_time_at_sync TEXT NOT NULL,
          system_time_at_sync TEXT NOT NULL,
          uptime_at_sync_ms INTEGER NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
    }

    if (oldVersion < 5) {
      await db.execute('ALTER TABLE session_logs_local ADD COLUMN lux_value INTEGER');
      await db.execute('ALTER TABLE face_attempts_local ADD COLUMN lux_value INTEGER');
    }

    if (oldVersion < 6) {
      await db.execute('ALTER TABLE session_logs_local ADD COLUMN photo_url TEXT');
      await db.execute('ALTER TABLE attendance_local ADD COLUMN photo_url TEXT');
    }

    if (oldVersion < 7) {
      await db.execute('ALTER TABLE attendance_local ADD COLUMN is_izin INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE attendance_local ADD COLUMN izin_type TEXT');
      await db.execute('ALTER TABLE attendance_local ADD COLUMN recorded_date TEXT');
    }

    if (oldVersion < 8) {
      await db.execute("ALTER TABLE embeddings_local ADD COLUMN source TEXT NOT NULL DEFAULT 'registration'");
    }

    if (oldVersion < 9) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS device_local (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          device_id TEXT,
          android_id TEXT,
          model TEXT,
          brand TEXT,
          android_version TEXT,
          registered INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }

    if (oldVersion < 10) {
      await db.execute('ALTER TABLE session_logs_local ADD COLUMN time_status TEXT');
    }
  }

  // ============================================================
  // DEVICE LOCAL
  // ============================================================
  Future<Map<String, dynamic>?> getDeviceLocal() async {
    final db = await database;
    final rows = await db.query('device_local', where: 'id = 1', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> saveDeviceLocal({
    required String? deviceId,
    required String androidId,
    required String model,
    required String brand,
    required String androidVersion,
    required bool registered,
  }) async {
    final db = await database;
    await db.insert('device_local', {
      'id': 1,
      'device_id': deviceId,
      'android_id': androidId,
      'model': model,
      'brand': brand,
      'android_version': androidVersion,
      'registered': registered ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ============================================================
  // USERS
  // ============================================================
  Future<void> saveUser({
    required String userId,
    required String nip,
    required String namaLengkap,
    required String role,
    String? sekolahId,
  }) async {
    final db = await database;
    await db.insert('users_local', {
      'user_id': userId,
      'nip': nip,
      'nama_lengkap': namaLengkap,
      'role': role,
      'sekolah_id': sekolahId,
      'logged_in_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getUser() async {
    final db = await database;
    final rows = await db.query('users_local', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> clearUser() async {
    final db = await database;
    await db.delete('users_local');
  }

  // ============================================================
  // SEKOLAH
  // ============================================================
  Future<void> saveSekolah({
    required String sekolahId,
    required String nama,
    required double lat,
    required double lng,
    required double radiusMeters,
  }) async {
    final db = await database;
    await db.insert('sekolah_local', {
      'sekolah_id': sekolahId,
      'nama': nama,
      'lat': lat,
      'lng': lng,
      'radius_meters': radiusMeters,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getSekolah() async {
    final db = await database;
    final rows = await db.query('sekolah_local', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  // ============================================================
  // TRUSTED TIME ANCHOR
  // ============================================================
  Future<void> saveAnchor({
    required String userId,
    required DateTime serverTime,
    required DateTime systemTime,
    required int uptimeMs,
  }) async {
    final db = await database;
    await db.insert('trusted_time_anchor_local', {
      'user_id': userId,
      'server_time_at_sync': serverTime.toIso8601String(),
      'system_time_at_sync': systemTime.toIso8601String(),
      'uptime_at_sync_ms': uptimeMs,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getAnchor() async {
    final db = await database;
    final rows = await db.query('trusted_time_anchor_local', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  // ============================================================
  // EMBEDDINGS
  // ============================================================
  Future<int> addEmbedding({
    required String userId,
    required String mode,
    required List<double> embedding,
    String source = 'registration',
  }) async {
    final db = await database;
    return await db.insert('embeddings_local', {
      'client_uuid': _uuid.v4(),
      'user_id': userId,
      'mode': mode,
      'embedding': jsonEncode(embedding),
      'source': source,
      'created_at': DateTime.now().toIso8601String(),
      'sync_status': 'pending',
    });
  }

  Future<List<Map<String, dynamic>>> getEmbeddings({
    required String userId,
    String? mode,
  }) async {
    final db = await database;
    final where = mode != null ? 'user_id = ? AND mode = ?' : 'user_id = ?';
    final whereArgs = mode != null ? [userId, mode] : [userId];
    return await db.query('embeddings_local',
        where: where, whereArgs: whereArgs, orderBy: 'created_at ASC');
  }

  Future<List<Map<String, dynamic>>> getPendingEmbeddings() async {
    final db = await database;
    return await db.query('embeddings_local',
        where: "sync_status = ? AND source != 'learning'",
        whereArgs: ['pending'],
        orderBy: 'created_at ASC');
  }

  Future<void> markEmbeddingSynced(int id) async {
    final db = await database;
    await db.update('embeddings_local',
        {'sync_status': 'synced', 'synced_at': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteEmbeddingsByUser(String userId) async {
    final db = await database;
    final count = await db.delete('embeddings_local',
        where: 'user_id = ?', whereArgs: [userId]);
    debugPrint("DB: deleteEmbeddingsByUser($userId) -> $count rows");
  }

  Future<int> countEmbeddings() async {
    final db = await database;
    final r = await db.rawQuery('SELECT COUNT(*) as c FROM embeddings_local');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  Future<int> countPendingEmbeddings() async {
    final db = await database;
    final r = await db.rawQuery(
      "SELECT COUNT(*) as c FROM embeddings_local WHERE sync_status = 'pending' AND source != 'learning'"
    );
    return Sqflite.firstIntValue(r) ?? 0;
  }

  Future<int> countLearningEmbeddings(String userId) async {
    final db = await database;
    final r = await db.rawQuery(
      "SELECT COUNT(*) as c FROM embeddings_local WHERE user_id = ? AND source = 'learning'",
      [userId],
    );
    return Sqflite.firstIntValue(r) ?? 0;
  }

  Future<int?> getOldestLearningEmbeddingId(String userId) async {
    final db = await database;
    final rows = await db.query(
      'embeddings_local',
      columns: ['id'],
      where: "user_id = ? AND source = 'learning'",
      whereArgs: [userId],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as int?;
  }

  Future<void> deleteEmbeddingById(int id) async {
    final db = await database;
    await db.delete('embeddings_local', where: 'id = ?', whereArgs: [id]);
  }

  // ============================================================
  // SESSION LOGS
  // ============================================================
  Future<int> addSessionLog({
    required String sessionUuid,
    required String userId,
    required String sessionType,
    required DateTime startedAt,
    DateTime? cameraReadyAt,
    DateTime? firstFaceAt,
    int? mtcnnMsFirst,
    int? mfnMsFirst,
    int? matchMsFirst,
    int? mtcnnMsFinal,
    int? mfnMsFinal,
    int? matchMsFinal,
    DateTime? faceValidAt,
    int failedCount = 0,
    DateTime? gpsStartAt,
    DateTime? gpsDoneAt,
    String? gpsResult,
    int? gpsMs,
    required String finalStatus,
    required DateTime finalAt,
    String? photoPath,
    int? deviceUptimeMs,
    int? deviceBootTimeMs,
    int? luxValue,
    String? timeStatus,
  }) async {
    final db = await database;
    return await db.insert('session_logs_local', {
      'client_uuid': sessionUuid,
      'user_id': userId,
      'session_type': sessionType,
      'started_at': startedAt.toIso8601String(),
      'camera_ready_at': cameraReadyAt?.toIso8601String(),
      'first_face_at': firstFaceAt?.toIso8601String(),
      'mtcnn_ms_first': mtcnnMsFirst,
      'mfn_ms_first': mfnMsFirst,
      'match_ms_first': matchMsFirst,
      'mtcnn_ms_final': mtcnnMsFinal,
      'mfn_ms_final': mfnMsFinal,
      'match_ms_final': matchMsFinal,
      'face_valid_at': faceValidAt?.toIso8601String(),
      'failed_count': failedCount,
      'gps_start_at': gpsStartAt?.toIso8601String(),
      'gps_done_at': gpsDoneAt?.toIso8601String(),
      'gps_result': gpsResult,
      'gps_ms': gpsMs,
      'final_status': finalStatus,
      'final_at': finalAt.toIso8601String(),
      'photo_path': photoPath,
      'device_uptime_ms': deviceUptimeMs,
      'device_boot_time_ms': deviceBootTimeMs,
      'lux_value': luxValue,
      'sync_status': 'pending',
      'time_status': timeStatus,
    });
  }

  Future<List<Map<String, dynamic>>> getPendingSessionLogs() async {
    final db = await database;
    return await db.query('session_logs_local',
        where: 'sync_status = ?', whereArgs: ['pending'], orderBy: 'started_at ASC');
  }

  Future<void> markSessionLogSynced(int id, {String? photoUrl}) async {
    final db = await database;
    final values = <String, dynamic>{
      'sync_status': 'synced',
      'synced_at': DateTime.now().toIso8601String(),
    };
    if (photoUrl != null) values['photo_url'] = photoUrl;
    await db.update('session_logs_local', values,
        where: 'id = ?', whereArgs: [id]);
  }

  // ============================================================
  // FACE ATTEMPTS
  // ============================================================
  Future<int> addFaceAttempt({
    required String sessionUuid,
    required String userId,
    required int attemptNumber,
    required DateTime attemptedAt,
    required String mtcnnStatus,
    int? mtcnnMs,
    String? mfnStatus,
    int? mfnMs,
    double? matchDistance,
    int? luxValue,
  }) async {
    final db = await database;
    return await db.insert('face_attempts_local', {
      'client_uuid': _uuid.v4(),
      'session_uuid': sessionUuid,
      'user_id': userId,
      'attempt_number': attemptNumber,
      'attempted_at': attemptedAt.toIso8601String(),
      'mtcnn_status': mtcnnStatus,
      'mtcnn_ms': mtcnnMs,
      'mfn_status': mfnStatus,
      'mfn_ms': mfnMs,
      'match_distance': matchDistance,
      'lux_value': luxValue,
      'sync_status': 'pending',
    });
  }

  Future<List<Map<String, dynamic>>> getPendingFaceAttempts() async {
    final db = await database;
    return await db.query('face_attempts_local',
        where: 'sync_status = ?', whereArgs: ['pending'], orderBy: 'attempted_at ASC');
  }

  Future<void> markFaceAttemptSynced(int id) async {
    final db = await database;
    await db.update('face_attempts_local',
        {'sync_status': 'synced', 'synced_at': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  // ============================================================
  // GPS ATTEMPTS
  // ============================================================
  Future<int> addGpsAttempt({
    required String sessionUuid,
    required String userId,
    required int attemptNumber,
    required DateTime startedAt,
    DateTime? doneAt,
    required String result,
    double? lat,
    double? lng,
    double? accuracyMeters,
    double? distanceToSchool,
    int? durationMs,
  }) async {
    final db = await database;
    return await db.insert('gps_attempts_local', {
      'client_uuid': _uuid.v4(),
      'session_uuid': sessionUuid,
      'user_id': userId,
      'attempt_number': attemptNumber,
      'started_at': startedAt.toIso8601String(),
      'done_at': doneAt?.toIso8601String(),
      'result': result,
      'lat': lat,
      'lng': lng,
      'accuracy_meters': accuracyMeters,
      'distance_to_school': distanceToSchool,
      'duration_ms': durationMs,
      'sync_status': 'pending',
    });
  }

  Future<List<Map<String, dynamic>>> getPendingGpsAttempts() async {
    final db = await database;
    return await db.query('gps_attempts_local',
        where: 'sync_status = ?', whereArgs: ['pending'], orderBy: 'started_at ASC');
  }

  Future<void> markGpsAttemptSynced(int id) async {
    final db = await database;
    await db.update('gps_attempts_local',
        {'sync_status': 'synced', 'synced_at': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  // ============================================================
  // ATTENDANCE
  // ============================================================
  Future<int> addAttendance({
    required String userId,
    required DateTime recordedAt,
    required double lat,
    required double lng,
    double? distanceMeters,
    required double matchDistance,
    required String matchMode,
    required String connectivityMode,
    bool isLate = false,
    bool isIzin = false,
    String? izinType,
    String? sessionUuid,
    String? photoPath,
  }) async {
    final db = await database;

    final dateOnly = '${recordedAt.year.toString().padLeft(4, '0')}-'
        '${recordedAt.month.toString().padLeft(2, '0')}-'
        '${recordedAt.day.toString().padLeft(2, '0')}';

    return await db.insert('attendance_local', {
      'client_uuid': _uuid.v4(),
      'session_uuid': sessionUuid,
      'user_id': userId,
      'recorded_at': recordedAt.toIso8601String(),
      'recorded_date': dateOnly,
      'local_timestamp': DateTime.now().toIso8601String(),
      'lat': lat,
      'lng': lng,
      'distance_meters': distanceMeters,
      'match_distance': matchDistance,
      'match_mode': matchMode,
      'connectivity_mode': connectivityMode,
      'is_late': isLate ? 1 : 0,
      'is_izin': isIzin ? 1 : 0,
      'izin_type': izinType,
      'photo_path': photoPath,
      'sync_status': 'pending',
    });
  }

  Future<Map<String, dynamic>?> getTodayAttendance(String userId) async {
    final db = await database;
    final now = DateTime.now();
    final dateOnly = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    final rows = await db.query(
      'attendance_local',
      where: 'user_id = ? AND recorded_date = ?',
      whereArgs: [userId, dateOnly],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> getPendingAttendance() async {
    final db = await database;
    return await db.query('attendance_local',
        where: 'sync_status = ?', whereArgs: ['pending'], orderBy: 'recorded_at ASC');
  }

  Future<void> markAttendanceSynced(int id, {String? photoUrl}) async {
    final db = await database;
    final values = <String, dynamic>{
      'sync_status': 'synced',
      'synced_at': DateTime.now().toIso8601String(),
    };
    if (photoUrl != null) values['photo_url'] = photoUrl;
    await db.update('attendance_local', values,
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> countAttendance() async {
    final db = await database;
    final r = await db.rawQuery('SELECT COUNT(*) as c FROM attendance_local');
    return Sqflite.firstIntValue(r) ?? 0;
  }

  Future<int> countPendingAttendance() async {
    final db = await database;
    final r = await db.rawQuery("SELECT COUNT(*) as c FROM attendance_local WHERE sync_status = 'pending'");
    return Sqflite.firstIntValue(r) ?? 0;
  }

  // ============================================================
  // PENDING CHECK
  // ============================================================
  Future<bool> hasAnyPending() async {
    final db = await database;
    const tables = [
      'embeddings_local',
      'attendance_local',
      'session_logs_local',
      'face_attempts_local',
      'gps_attempts_local',
    ];
    for (final t in tables) {
      final where = t == 'embeddings_local'
          ? "sync_status = 'pending' AND source != 'learning'"
          : "sync_status = 'pending'";
      final r = await db.rawQuery("SELECT COUNT(*) as c FROM $t WHERE $where");
      final count = Sqflite.firstIntValue(r) ?? 0;
      if (count > 0) return true;
    }
    return false;
  }

  // ============================================================
  // CLEANUP
  // ============================================================
  Future<int> cleanupExpiredPending() async {
    final db = await database;
    final cutoff = DateTime.now().subtract(const Duration(hours: 72)).toIso8601String();
    int totalDeleted = 0;

    final expiredAttendance = await db.query('attendance_local',
        where: "sync_status = 'pending' AND recorded_at < ?", whereArgs: [cutoff]);
    for (final row in expiredAttendance) {
      final photoPath = row['photo_path'] as String?;
      if (photoPath != null) {
        try {
          final f = File(photoPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      await db.delete('attendance_local', where: 'id = ?', whereArgs: [row['id']]);
      totalDeleted++;
    }

    final expiredEmb = await db.query('embeddings_local',
        where: "sync_status = 'pending' AND source != 'learning' AND created_at < ?",
        whereArgs: [cutoff]);
    for (final row in expiredEmb) {
      await db.delete('embeddings_local', where: 'id = ?', whereArgs: [row['id']]);
      totalDeleted++;
    }

    final expiredSessions = await db.query('session_logs_local',
        where: "sync_status = 'pending' AND started_at < ?", whereArgs: [cutoff]);
    for (final row in expiredSessions) {
      final photoPath = row['photo_path'] as String?;
      if (photoPath != null) {
        try {
          final f = File(photoPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      await db.delete('face_attempts_local',
          where: 'session_uuid = ?', whereArgs: [row['client_uuid']]);
      await db.delete('gps_attempts_local',
          where: 'session_uuid = ?', whereArgs: [row['client_uuid']]);
      await db.delete('session_logs_local', where: 'id = ?', whereArgs: [row['id']]);
      totalDeleted++;
    }

    if (totalDeleted > 0) {
      debugPrint("DB: cleanupExpiredPending -> $totalDeleted records deleted");
    }
    return totalDeleted;
  }

  Future<int> cleanupOldSyncedPhotos() async {
    final db = await database;
    final cutoff = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
    int deleted = 0;

    final rows = await db.query('attendance_local',
        where: "sync_status = 'synced' AND photo_path IS NOT NULL AND recorded_at < ?",
        whereArgs: [cutoff]);
    for (final row in rows) {
      final path = row['photo_path'] as String?;
      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
          deleted++;
        } catch (_) {}
      }
      await db.update('attendance_local',
          {'photo_path': null}, where: 'id = ?', whereArgs: [row['id']]);
    }

    final sessions = await db.query('session_logs_local',
        where: "sync_status = 'synced' AND photo_path IS NOT NULL AND started_at < ?",
        whereArgs: [cutoff]);
    for (final row in sessions) {
      final path = row['photo_path'] as String?;
      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
          deleted++;
        } catch (_) {}
      }
      await db.update('session_logs_local',
          {'photo_path': null}, where: 'id = ?', whereArgs: [row['id']]);
    }

    if (deleted > 0) {
      debugPrint("DB: cleanupOldSyncedPhotos -> $deleted photos deleted");
    }
    return deleted;
  }

  // ============================================================
  // UTILITY
  // ============================================================
  Future<void> clearAll() async {
    final db = await database;
    await db.delete('users_local');
    await db.delete('sekolah_local');
    await db.delete('embeddings_local');
    await db.delete('attendance_local');
    await db.delete('session_logs_local');
    await db.delete('face_attempts_local');
    await db.delete('gps_attempts_local');
    await db.delete('trusted_time_anchor_local');
    // device_local TIDAK dihapus — device tetap terdaftar di HP ini
    debugPrint("DB: All tables cleared (device_local kept)");
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}