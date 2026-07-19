import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';
import 'package:workmanager/workmanager.dart';

import 'home_widget_service.dart';
import 'pocketbase_service.dart';

/// Периодический фоновый ФОЛБЭК обновления виджетов через WorkManager (Android).
///
/// Мгновенное обновление виджетов при закрытом приложении держит
/// [PushBackgroundService] — foreground-сервис с Centrifugo-сокетом в отдельном
/// изоляте. Но на агрессивных OEM (Xiaomi/MIUI/HyperOS, Samsung One UI) система
/// усыпляет или убивает foreground-сервис ДАЖЕ с отключённой оптимизацией
/// батареи (у MIUI поверх батареи есть отдельный «Автозапуск» + своя чистка
/// памяти). Сокет рвётся → события партнёра не приходят → виджеты застывают до
/// открытия приложения.
///
/// Этот сервис — ВТОРОЙ, живучий канал: периодическая задача WorkManager
/// (минимум платформы — 15 мин), которая переживает убийство процесса и
/// запускается даже в Doze maintenance-окнах. Она сама тянет свежий widget_data
/// из PocketBase и перерисовывает виджеты — без сокета и без открытия
/// приложения. Не мгновенно (шаг ~15 мин), но гарантирует, что виджет не
/// застрянет навсегда, если foreground-сервис убили.
///
/// Android-only: на iOS WorkManager недоступен (там свой BGTaskScheduler —
/// отдельная задача). Контекст пары читается тем же способом, что и нативный
/// фоновый колбэк / изолят foreground-сервиса: PB-сессия с диска даёт myUid, а
/// groupId/partnerUid лежат в HomeWidget data (`love_widget_*`).
class WidgetBackgroundRefreshService {
  WidgetBackgroundRefreshService._();
  static final WidgetBackgroundRefreshService instance =
      WidgetBackgroundRefreshService._();

  static const String _taskUnique = 'togetherly_widget_refresh';
  static const String _taskName = 'widgetRefresh';

  bool _initialized = false;

  /// Инициализация диспетчера WorkManager. Вызывать один раз из main() (Android).
  Future<void> init() async {
    if (!Platform.isAndroid || _initialized) return;
    try {
      await Workmanager().initialize(widgetRefreshDispatcher);
      _initialized = true;
    } catch (e) {
      debugPrint('WidgetBackgroundRefreshService.init failed: $e');
    }
  }

  /// Запланировать периодический рефреш. Идемпотентно: политика KEEP не сбивает
  /// 15-минутный отсчёт на каждом открытии приложения (иначе при частых заходах
  /// задача никогда не дошла бы до срабатывания в фоне). Вызывать при активной
  /// паре (см. home_screen._updatePartnerPush).
  Future<void> ensureScheduled() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().registerPeriodicTask(
        _taskUnique,
        _taskName,
        frequency: const Duration(minutes: 15), // минимум, разрешённый WorkManager
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.linear,
        backoffPolicyDelay: const Duration(minutes: 1),
      );
    } catch (e) {
      debugPrint('WidgetBackgroundRefreshService.ensureScheduled failed: $e');
    }
  }

  /// Отменить периодический рефреш (выход из аккаунта / распад пары).
  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().cancelByUniqueName(_taskUnique);
    } catch (e) {
      debugPrint('WidgetBackgroundRefreshService.cancel failed: $e');
    }
  }
}

/// Точка входа фонового изолята WorkManager. ДОЛЖНА быть top-level +
/// vm:entry-point (её адрес передаётся нативной части при initialize).
@pragma('vm:entry-point')
void widgetRefreshDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (!Platform.isAndroid) return true;
    try {
      // Фоновый изолят свежий — регистрируем плагины, иначе MethodChannel
      // (home_widget / shared_preferences / path_provider) недоступны.
      WidgetsFlutterBinding.ensureInitialized();
      // На Android no-op, но home_widget требует до первого saveWidgetData.
      await HomeWidget.setAppGroupId('group.com.togetherly.love');

      // Восстанавливаем PB-сессию с диска (widget_data protected — нужен токен).
      await PocketBaseService().init();
      final myUid = PocketBaseService().userId ?? '';
      if (myUid.isEmpty) return true; // не залогинен — тихо выходим

      final groupId =
          await HomeWidget.getWidgetData<String>('love_widget_group_id') ?? '';
      final partnerUid =
          await HomeWidget.getWidgetData<String>('love_widget_partner_uid') ??
              '';
      if (groupId.isEmpty) return true;

      // Единая точка фонового обновления всех виджетов из PB (та же, что в
      // изоляте foreground-сервиса).
      await HomeWidgetService.instance.backgroundRefreshAll(
        groupId: groupId,
        myUid: myUid,
        partnerUid: partnerUid,
        refreshPhotos: true,
      );
    } catch (e) {
      debugPrint('widgetRefreshDispatcher failed: $e');
    }
    // Всегда true: не помечаем задачу проваленной, чтобы WorkManager не уходил
    // в агрессивный backoff-ретрай — периодическое расписание и так вернётся.
    return true;
  });
}
