import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../utils/notification_permission.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'locale_service.dart';

/// Постоянное «тихое» уведомление-счётчик «дней вместе».
///
/// Висит в шторке уведомлений и показывает, сколько дней пара уже вместе.
/// Не пищит и не вибрирует (канал с Importance.low, silent), не смахивается
/// случайно (ongoing). Число пересчитывается:
///   • при включении тумблера в профиле,
///   • при старте приложения (rescheduleOnAppStart),
///   • при возврате в приложение (refresh),
///   • раз в сутки в 00:10 фоновым zonedSchedule (DateTimeComponents.time).
///
/// Замечание про точность: фоновое обновление повторяется с одним и тем же
/// текстом, поэтому если приложение не открывать несколько суток подряд, число
/// может отставать на эти сутки — оно выровняется при следующем открытии
/// (refresh вызывается на старте и на resume). По умолчанию фича выключена.
class DaysTogetherNotificationService {
  DaysTogetherNotificationService._();
  static final DaysTogetherNotificationService instance =
      DaysTogetherNotificationService._();

  // Уникальный ID (не пересекается с 9001-9004 праздники, 9991 маскот, 8888 mood)
  static const int _notificationId = 9101;
  static const String _channelId = 'days_together_v1';
  static const String _channelName = 'Дни вместе';
  static const String _channelDesc =
      'Постоянный счётчик дней, проведённых вместе';

  static const String _keyEnabled = 'days_together_notif_enabled';
  static const String _keyStartMs = 'days_together_start_ms';

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
        description: _channelDesc,
        importance: Importance.low, // тихо: без звука и без heads-up
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
    );

    _initialized = true;
  }

  // ── Public API ───────────────────────────────────────────────────────────

  /// Текущее состояние тумблера (по умолчанию выключено).
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyEnabled) ?? false;
  }

  /// Включает/выключает счётчик.
  /// [startDate] — дата начала отношений; если null, берётся ранее сохранённая.
  Future<void> setEnabled(bool value, {DateTime? startDate}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, value);
    if (startDate != null) {
      await prefs.setInt(_keyStartMs, startDate.millisecondsSinceEpoch);
    }
    if (value) {
      await _refresh();
    } else {
      await _cancel();
    }
  }

  /// Вызывается из home_screen при появлении/смене даты начала.
  /// [startDate] == null → пара распалась, счётчик убираем.
  Future<void> onStartDateChanged(DateTime? startDate) async {
    final prefs = await SharedPreferences.getInstance();
    if (startDate == null) {
      await prefs.remove(_keyStartMs);
      await _cancel();
      return;
    }
    await prefs.setInt(_keyStartMs, startDate.millisecondsSinceEpoch);
    if (await isEnabled()) await _refresh();
  }

  /// Пересчёт расписания при старте приложения.
  Future<void> rescheduleOnAppStart() => _refresh();

  /// Пересчёт при возврате в приложение (count мог измениться за полночь).
  Future<void> refresh() => _refresh();

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<DateTime?> _startDate() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_keyStartMs);
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// Сколько дней «вместе» на момент [when] — та же формула, что в профиле
  /// (`_calculateDaysTogether`): разница в полных сутках, минимум 0.
  int _daysAt(DateTime start, DateTime when) {
    final d = when.difference(start).inDays;
    return d < 0 ? 0 : d;
  }

  Future<void> _refresh() async {
    if (!await isEnabled()) return;
    final start = await _startDate();
    if (start == null) return;
    await init();

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    // Android 13+ требует явного разрешения POST_NOTIFICATIONS.
    // Общий сериализатор: не падаем на параллельном запросе (permissionRequestInProgress).
    await requestNotificationPermissionSafely(androidPlugin);

    // 1) Показать прямо сейчас с актуальным числом.
    await _show(_daysAt(start, DateTime.now()));

    // 2) Запланировать ежесуточное обновление в 00:10.
    await _scheduleDailyRefresh(start);
  }

  Future<void> _show(int days) async {
    final s = LocaleService.current;
    try {
      await _plugin.show(
        id: _notificationId,
        title: s.daysTogetherNotifBody(days),
        body: s.daysTogetherNotifTagline,
        notificationDetails: _details(),
      );
    } catch (e) {
      debugPrint('DaysTogetherNotificationService._show failed: $e');
    }
  }

  Future<void> _scheduleDailyRefresh(DateTime start) async {
    final s = LocaleService.current;
    try {
      final now = tz.TZDateTime.now(tz.local);
      var next = tz.TZDateTime(tz.local, now.year, now.month, now.day, 0, 10);
      if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
      // Число на момент следующего срабатывания (по календарным суткам).
      final daysAtNext =
          _daysAt(start, DateTime(next.year, next.month, next.day));

      await _plugin.zonedSchedule(
        id: _notificationId,
        title: s.daysTogetherNotifBody(daysAtNext),
        body: s.daysTogetherNotifTagline,
        scheduledDate: next,
        notificationDetails: _details(),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time, // повтор каждый день
      );
    } catch (e) {
      debugPrint(
          'DaysTogetherNotificationService._scheduleDailyRefresh failed: $e');
    }
  }

  NotificationDetails _details() => const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.low,
          priority: Priority.low,
          icon: '@drawable/ic_notification',
          ongoing: true, // не смахивается случайно
          autoCancel: false,
          onlyAlertOnce: true, // без повторного звука/вибро при обновлении
          showWhen: false,
          silent: true,
          playSound: false,
          enableVibration: false,
          channelShowBadge: false,
          category: AndroidNotificationCategory.status,
          visibility: NotificationVisibility.public,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: false,
          presentBadge: false,
          presentSound: false,
        ),
      );

  Future<void> _cancel() async {
    await init();
    try {
      await _plugin.cancel(id: _notificationId);
    } catch (e) {
      debugPrint('DaysTogetherNotificationService._cancel failed: $e');
    }
  }
}
