import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'db/database_service.dart';

/// Pengingat absen via notifikasi lokal.
///
/// Aturan:
///  - Kalau hari ini BELUM absen/izin → schedule notif jam 10:00.
///  - Kalau SUDAH absen/izin → cancel.
///  - Hari libur/Minggu → cancel.
///  - Lewat jam 10:00 dan belum absen → nggak schedule (udah telat).
class NotifService {
  NotifService._();
  static final NotifService instance = NotifService._();

  static const int _absenReminderId = 1001;
  static const String _channelId = 'absen_reminder';
  static const String _channelName = 'Pengingat Absen';
  static const String _channelDesc = 'Notifikasi pengingat absen wajah';

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    tz.initializeTimeZones();
    // Target user ada di Jember → WIB. Kalau nanti multi-zona, ganti
    // pakai plugin flutter_timezone.
    tz.setLocalLocation(tz.getLocation('Asia/Jakarta'));

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (response) {
        debugPrint("NOTIF: tapped -> ${response.payload}");
      },
    );

    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.high,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _initialized = true;
    debugPrint("NOTIF: initialized");
  }

  /// Schedule notif pengingat absen jam 10:00 hari ini.
  /// Cancel dulu yang lama biar nggak dobel.
  Future<void> scheduleAbsenReminderForToday() async {
    if (!_initialized) await init();
    await cancelAbsenReminder();

    final now = DateTime.now();
    final scheduled = DateTime(now.year, now.month, now.day, 10, 0);

    if (scheduled.isBefore(now)) {
      debugPrint("NOTIF: skip (jam 10:00 udah lewat)");
      return;
    }

    await _plugin.zonedSchedule(
      id: _absenReminderId,
      title: 'Waktunya Absen',
      body: 'Absen wajah ditutup jam 10:30. Segera lakukan absen sekarang.',
      scheduledDate: tz.TZDateTime.from(scheduled, tz.local),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );

    debugPrint("NOTIF: scheduled untuk $scheduled");
  }

  Future<void> cancelAbsenReminder() async {
    await _plugin.cancel(id: _absenReminderId);
    debugPrint("NOTIF: cancelled");
  }

  /// Panggil setiap app buka atau abis absen/izin.
  /// Cek DB: kalau belum absen/izin hari ini → schedule. Kalau sudah → cancel.
  Future<void> refreshForUser(String userId) async {
    try {
      if (!_initialized) await init();

      final today = await DatabaseService.instance.getTodayAttendance(userId);
      if (today != null) {
        debugPrint("NOTIF: cancel (sudah absen hari ini)");
        await cancelAbsenReminder();
        return;
      }

      final now = DateTime.now();

      if (now.weekday == DateTime.sunday) {
        debugPrint("NOTIF: cancel (hari Minggu)");
        await cancelAbsenReminder();
        return;
      }

      final libur = await DatabaseService.instance.getHariLiburSet();
      final dateKey = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      if (libur.contains(dateKey)) {
        debugPrint("NOTIF: cancel (hari libur: $dateKey)");
        await cancelAbsenReminder();
        return;
      }

      await scheduleAbsenReminderForToday();
    } catch (e) {
      debugPrint("NOTIF: refresh error -> $e");
    }
  }
}