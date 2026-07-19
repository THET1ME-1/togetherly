import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../utils/notification_permission.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'locale_service.dart';

/// Сервис уведомлений о праздниках: годовщина и день рождения.
///
/// Уведомления приходят за 1 день до праздника (в 10:00) и точно в день (в 09:00).
/// Расписание пересчитывается при каждом открытии приложения и при изменении дат.
class CelebrationNotificationService {
  CelebrationNotificationService._();
  static final CelebrationNotificationService instance =
      CelebrationNotificationService._();

  // ID уведомлений (уникальные, не пересекаются с маскотом=9991)
  static const int _idAnniversaryEve = 9001;
  static const int _idAnniversaryDay = 9002;
  static const int _idBirthdayEve = 9003;
  static const int _idBirthdayDay = 9004;

  static const String _channelId = 'celebrations_v1';
  static const String _channelName = 'Праздники';

  // Ключи SharedPreferences для хранения дат между сессиями.
  static const String _keyAnniversaryMs = 'celebration_anniversary_ms';
  static const String _keyBirthdayMs = 'celebration_birthday_ms';
  static const String _keyNotifEnabled = 'celebration_notif_enabled';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // ── Init ───────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;

    tz.initializeTimeZones();

    const androidSettings = AndroidInitializationSettings(
      '@drawable/ic_notification',
    );
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(settings: settings);

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Напоминания о годовщинах и днях рождения',
        importance: Importance.high,
      ),
    );

    if (Platform.isIOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }

    _initialized = true;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Возвращает текущий флаг включения уведомлений.
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyNotifEnabled) ?? true;
  }

  /// Включает или выключает уведомления о праздниках.
  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyNotifEnabled, value);
    if (!value) {
      await _cancelAll();
    } else {
      await _rescheduleFromPrefs();
    }
  }

  /// Вызывается при изменении годовщины или дня рождения.
  /// [anniversaryDate] — дата годовщины (nullable = нет).
  /// [birthDate]       — мой день рождения (nullable = нет).
  Future<void> onDatesChanged({
    DateTime? anniversaryDate,
    DateTime? birthDate,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (anniversaryDate != null) {
      await prefs.setInt(
          _keyAnniversaryMs, anniversaryDate.millisecondsSinceEpoch);
    } else {
      await prefs.remove(_keyAnniversaryMs);
    }
    if (birthDate != null) {
      await prefs.setInt(_keyBirthdayMs, birthDate.millisecondsSinceEpoch);
    } else {
      await prefs.remove(_keyBirthdayMs);
    }
    await _rescheduleAll(
        anniversaryDate: anniversaryDate, birthDate: birthDate);
  }

  /// Пересчитывает расписание из SharedPreferences (вызывается при старте приложения).
  Future<void> rescheduleOnAppStart() async {
    await _rescheduleFromPrefs();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<void> _rescheduleFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final annMs = prefs.getInt(_keyAnniversaryMs);
    final bdMs = prefs.getInt(_keyBirthdayMs);
    await _rescheduleAll(
      anniversaryDate:
          annMs != null ? DateTime.fromMillisecondsSinceEpoch(annMs) : null,
      birthDate:
          bdMs != null ? DateTime.fromMillisecondsSinceEpoch(bdMs) : null,
    );
  }

  Future<void> _rescheduleAll({
    DateTime? anniversaryDate,
    DateTime? birthDate,
  }) async {
    if (!await isEnabled()) return;
    await init();

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    // Общий сериализатор: не падаем на параллельном запросе (permissionRequestInProgress).
    await requestNotificationPermissionSafely(androidPlugin);

    final s = LocaleService.current;

    // Годовщина
    await _plugin.cancel(id: _idAnniversaryEve);
    await _plugin.cancel(id: _idAnniversaryDay);
    if (anniversaryDate != null) {
      await _scheduleAnnual(
        id: _idAnniversaryEve,
        month: anniversaryDate.month,
        day: anniversaryDate.day,
        hour: 10,
        minute: 0,
        daysOffset: -1,
        title: s.anniversaryTomorrowTitle,
        body: s.anniversaryTomorrowBody,
      );
      await _scheduleAnnual(
        id: _idAnniversaryDay,
        month: anniversaryDate.month,
        day: anniversaryDate.day,
        hour: 9,
        minute: 0,
        daysOffset: 0,
        title: s.anniversaryTodayTitle,
        body: s.anniversaryTodayBody,
      );
    }

    // День рождения
    await _plugin.cancel(id: _idBirthdayEve);
    await _plugin.cancel(id: _idBirthdayDay);
    if (birthDate != null) {
      await _scheduleAnnual(
        id: _idBirthdayEve,
        month: birthDate.month,
        day: birthDate.day,
        hour: 10,
        minute: 0,
        daysOffset: -1,
        title: s.birthdayTomorrowTitle,
        body: s.birthdayTomorrowBody,
      );
      await _scheduleAnnual(
        id: _idBirthdayDay,
        month: birthDate.month,
        day: birthDate.day,
        hour: 9,
        minute: 0,
        daysOffset: 0,
        title: s.birthdayTodayTitle,
        body: s.birthdayTodayBody,
      );
    }
  }

  /// Планирует одно ежегодное уведомление.
  /// [daysOffset] -1 = день до, 0 = в сам день.
  Future<void> _scheduleAnnual({
    required int id,
    required int month,
    required int day,
    required int hour,
    required int minute,
    required int daysOffset,
    required String title,
    required String body,
  }) async {
    try {
      final now = tz.TZDateTime.now(tz.local);
      // Вычисляем целевую дату с учётом смещения daysOffset.
      DateTime target = DateTime(now.year, month, day).add(
        Duration(days: daysOffset),
      );
      // Если дата уже прошла в этом году — берём следующий год.
      var scheduled = tz.TZDateTime(
        tz.local,
        target.year,
        target.month,
        target.day,
        hour,
        minute,
      );
      if (scheduled.isBefore(now)) {
        // Следующий год: пересчитываем от базовой даты + 1 год.
        target = DateTime(now.year + 1, month, day).add(
          Duration(days: daysOffset),
        );
        scheduled = tz.TZDateTime(
          tz.local,
          target.year,
          target.month,
          target.day,
          hour,
          minute,
        );
      }

      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: scheduled,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'Напоминания о годовщинах и днях рождения',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@drawable/ic_notification',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
      debugPrint(
        'CelebrationNotif: scheduled id=$id at $scheduled ($title)',
      );
    } catch (e) {
      debugPrint('CelebrationNotificationService._scheduleAnnual failed: $e');
    }
  }

  Future<void> _cancelAll() async {
    await init();
    await _plugin.cancel(id: _idAnniversaryEve);
    await _plugin.cancel(id: _idAnniversaryDay);
    await _plugin.cancel(id: _idBirthdayEve);
    await _plugin.cancel(id: _idBirthdayDay);
  }

  // ── Helper: дней до следующего события ────────────────────────────────────

  /// Сколько дней до следующего вхождения [date] (по месяцу и дню).
  /// Возвращает 0, если сегодня.
  static int daysUntil(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime next = DateTime(now.year, date.month, date.day);
    if (next.isBefore(today)) {
      next = DateTime(now.year + 1, date.month, date.day);
    }
    return next.difference(today).inDays;
  }

  /// True если сегодня совпадает день и месяц с [date].
  static bool isToday(DateTime date) {
    final now = DateTime.now();
    return now.month == date.month && now.day == date.day;
  }
}
