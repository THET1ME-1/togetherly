import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../utils/notification_permission.dart';
import 'locale_service.dart';

/// Локальное уведомление «капсула времени открылась» на дату [DateTime] открытия.
/// Планируется через `zonedSchedule` (системный будильник срабатывает и при
/// закрытом приложении — фоновый код не нужен, iOS-ограничения не мешают).
/// Планируется на устройстве автора при создании и на устройстве партнёра при
/// получении капсулы из realtime-ленты; id стабилен по memoryId → идемпотентно.
class CapsuleNotificationService {
  CapsuleNotificationService._();
  static final CapsuleNotificationService instance =
      CapsuleNotificationService._();

  static const String _channelId = 'time_capsule';
  static const String _channelName = 'Капсула времени';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  final Set<int> _scheduled = <int>{};

  Future<void> init() async {
    if (_initialized) return;
    tz.initializeTimeZones();
    const androidSettings =
        AndroidInitializationSettings('@drawable/ic_notification');
    const iosSettings = DarwinInitializationSettings();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
    );
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Напоминание об открытии капсулы времени',
        importance: Importance.high,
      ),
    );
    if (Platform.isIOS || Platform.isMacOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
    _initialized = true;
  }

  /// Планирует уведомление на [openAt]. Повторные вызовы с тем же memoryId —
  /// no-op (id стабилен). Прошедшие даты игнорируются.
  Future<void> schedule(String memoryId, DateTime openAt,
      {String? capsuleTitle}) async {
    final id = idForMemory(memoryId);
    if (_scheduled.contains(id)) return;
    if (!openAt.isAfter(DateTime.now())) return;
    // Помечаем СРАЗУ: каждую капсулу планируем максимум один раз за сессию, даже
    // если платформенный вызов упадёт. Иначе стрим-листенер ленты (зовёт schedule
    // на КАЖДУЮ эмиссию) при неудаче гонял бы тяжёлый init()/tz.initializeTimeZones
    // заново на каждой эмиссии, забивая isolate и не давая outbox-флашу
    // завершиться — это читалось как «бесконечная синхронизация».
    _scheduled.add(id);
    try {
      if (!_initialized) await init();
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await requestNotificationPermissionSafely(androidPlugin);
      final s = LocaleService.current;
      final body = (capsuleTitle != null && capsuleTitle.trim().isNotEmpty)
          ? s.capsuleOpenedBodyNamed(capsuleTitle.trim())
          : s.capsuleOpenedBody;
      await _plugin.zonedSchedule(
        id: id,
        title: s.capsuleOpenedTitle,
        body: body,
        scheduledDate: tz.TZDateTime.from(openAt, tz.local),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'Напоминание об открытии капсулы времени',
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
        // Неточный режим: не требует спец-разрешения SCHEDULE_EXACT_ALARM
        // (Android 13+ иначе кидает исключение). Для капсулы, открывающейся через
        // недели/месяцы, окно в пару часов несущественно.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (e) {
      debugPrint('CapsuleNotificationService.schedule failed: $e');
    }
  }

  /// Стабильный положительный id из memoryId (не пересекается с фиксированными
  /// id других сервисов, напр. 9991 маскота). Статический — покрыт тестами.
  static int idForMemory(String memoryId) {
    var h = 0;
    for (final c in memoryId.codeUnits) {
      h = (h * 31 + c) & 0x3FFFFFFF;
    }
    return 100000 + (h % 800000);
  }
}
