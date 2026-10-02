import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Simpan + ambil kunci enkripsi SQLCipher per user.
/// Kunci 256-bit random, disimpan di Android Keystore via secure storage.
class DbKeyStorage {
  DbKeyStorage._();
  static const _storage = FlutterSecureStorage();

  static String _keyFor(String userId) => 'db_key_$userId';

  /// Ambil key user. Kalau belum ada, generate + simpan.
  static Future<String> getOrCreate(String userId) async {
    try {
      final existing = await _storage.read(key: _keyFor(userId));
      if (existing != null && existing.isNotEmpty) return existing;

      final key = _generateKey();
      await _storage.write(key: _keyFor(userId), value: key);
      debugPrint("DBKEY: generated untuk user=$userId");
      return key;
    } catch (e) {
      debugPrint("DBKEY: error -> $e");
      rethrow;
    }
  }

  static String _generateKey() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Hapus key — dipakai kalau reset total.
  static Future<void> delete(String userId) async {
    await _storage.delete(key: _keyFor(userId));
    debugPrint("DBKEY: deleted untuk user=$userId");
  }
}