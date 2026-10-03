import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge ke plugin deteksi mock location (Fake GPS).
class MockLocation {
  MockLocation._();
  static const _channel =
      MethodChannel('id.ac.umj.rikoputra.absensiwajah/mock_location');

  /// Return true kalau ada mock location aktif.
  static Future<bool> check() async {
    try {
      final v = await _channel.invokeMethod<bool>('check');
      return v ?? false;
    } catch (e) {
      debugPrint("MockLocation.check error: $e");
      return false;
    }
  }
}