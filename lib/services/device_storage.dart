import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Penyimpanan global identitas device (lintas user).
///
/// Dulu tinggal di tabel `device_local` SQLite per-user, sekarang
/// dipindah ke Android Keystore agar tetap sama walau user ganti.
class DeviceStorage {
  DeviceStorage._();

  static const _storage = FlutterSecureStorage();

  static const _kDeviceId = 'device_id';
  static const _kAndroidId = 'device_android_id';
  static const _kModel = 'device_model';
  static const _kBrand = 'device_brand';
  static const _kAndroidVersion = 'device_android_version';
  static const _kRegistered = 'device_registered';

  /// Return null kalau device belum pernah daftar (android_id kosong).
  static Future<Map<String, dynamic>?> get() async {
    try {
      final androidId = await _storage.read(key: _kAndroidId);
      if (androidId == null || androidId.isEmpty) return null;
      return {
        'device_id': await _storage.read(key: _kDeviceId),
        'android_id': androidId,
        'model': await _storage.read(key: _kModel),
        'brand': await _storage.read(key: _kBrand),
        'android_version': await _storage.read(key: _kAndroidVersion),
        'registered': (await _storage.read(key: _kRegistered)) == '1' ? 1 : 0,
      };
    } catch (e) {
      debugPrint("DeviceStorage.get error -> $e");
      return null;
    }
  }

  static Future<String?> getAndroidId() async {
    try {
      return await _storage.read(key: _kAndroidId);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save({
    required String? deviceId,
    required String androidId,
    required String model,
    required String brand,
    required String androidVersion,
    required bool registered,
  }) async {
    try {
      await _storage.write(key: _kAndroidId, value: androidId);
      await _storage.write(key: _kModel, value: model);
      await _storage.write(key: _kBrand, value: brand);
      await _storage.write(key: _kAndroidVersion, value: androidVersion);
      await _storage.write(key: _kRegistered, value: registered ? '1' : '0');
      if (deviceId != null) {
        await _storage.write(key: _kDeviceId, value: deviceId);
      }
    } catch (e) {
      debugPrint("DeviceStorage.save error -> $e");
    }
  }
}