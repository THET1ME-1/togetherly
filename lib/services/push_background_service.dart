import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'centrifugo_service.dart';
import 'home_widget_service.dart';
import 'pb_push_service.dart';
import 'pocketbase_service.dart';

/// Фоновая доставка пуш-уведомлений БЕЗ FCM (§5 cutover Firebase→PocketBase).
///
/// [PbPushService] держит SSE-подписку на активность партнёра (чат/настроение/
/// «скучаю») и поднимает локальные уведомления. Пока приложение открыто, эта
/// подписка живёт в главном изоляте (см. `home_screen`). Но когда приложение
/// свёрнуто или выгружено из недавних, главный изолят усыпляется/убивается и
/// SSE-сокет рвётся — пуши перестают доходить. Этот сервис закрывает разрыв:
/// держит Android foreground-сервис (тип `dataSync`) с ОТДЕЛЬНЫМ изолятом, в
/// котором тот же [PbPushService] продолжает слушать сервер, пока пара активна.
///
/// Сервис запускается, пока приложение НА ПЕРЕДНЕМ ПЛАНЕ (на home-экране после
/// привязки пары) — иначе Android 12+ заблокировал бы старт foreground-сервиса
/// из фона. Дальше он переживает сворачивание и свайп из недавних.
///
/// iOS НЕ поддерживается: постоянный фоновый сокет там не выживает (нужен
/// APNs — отдельная задача). На iOS пуши работают только пока приложение
/// открыто, через главный изолят (см. `home_screen._updatePartnerPush`).
class PushBackgroundService {
  PushBackgroundService._();
  static final PushBackgroundService instance = PushBackgroundService._();
  factory PushBackgroundService() => instance;

  bool _configured = false;
  // Защита от пересекающихся start(): без неё два вызова подряд (resume + смена
  // пары) ловят PlatformException(permissionRequestInProgress) на запросе
  // разрешения уведомлений. См. Bugsink: push_background_service.dart:start.
  bool _starting = false;

  void _ensureConfigured() {
    if (_configured) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'partner_push_service',
        channelName: 'Связь с сервером',
        channelDescription:
            'Держит соединение, чтобы доставлять сообщения, настроение и '
            '«скучаю» от партнёра, пока приложение свёрнуто.',
        // Каналу/баннеру по умолчанию LOW importance + без вибрации/бейджа —
        // постоянное уведомление сервиса не мозолит глаза.
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // SSE — событийный, поллинг не нужен. Раз в минуту будим обработчик как
        // watchdog: если подписки не поднялись (сервис стартовал раньше, чем
        // восстановилась PB-сессия), пробуем снова + освежаем виджеты.
        eventAction: ForegroundTaskEventAction.repeat(60000),
        // Перезапуск доставки после ребута устройства (RebootReceiver пакета уже
        // объявлен в манифесте). Контекст пары persist'ится через saveData, а
        // PB-сессия восстанавливается из SharedPreferences в onStart → доставка
        // и обновление виджетов оживают без открытия приложения.
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _configured = true;
  }

  /// Поднять фоновую доставку для активной пары. Идемпотентно, только Android.
  /// Зовётся, пока приложение на переднем плане (см. ограничение в доке класса).
  Future<void> start({
    required String groupId,
    required String myUid,
    required String partnerUid,
    String partnerName = 'Партнёр',
  }) async {
    if (!Platform.isAndroid) return;
    if (groupId.isEmpty || myUid.isEmpty || partnerUid.isEmpty) return;
    if (_starting) return; // параллельный старт уже идёт
    _starting = true;
    try {
      _ensureConfigured();

      // Суточный бюджет dataSync-FGS (Android 14+) мог быть исчерпан за день —
      // тогда старт бессмыслен: ОС всё равно быстро прибьёт сервис по таймауту
      // (а раньше это роняло приложение). Ждём следующих суток.
      if (await _dailyBudgetExhausted()) {
        debugPrint(
            'PushBackgroundService: суточный бюджет FGS исчерпан, старт отложен');
        return;
      }

      // Контекст пары для изолята обработчика — он прочитает его в onStart.
      await FlutterForegroundTask.saveData(key: _kGroupId, value: groupId);
      await FlutterForegroundTask.saveData(key: _kMyUid, value: myUid);
      await FlutterForegroundTask.saveData(key: _kPartnerUid, value: partnerUid);
      await FlutterForegroundTask.saveData(
          key: _kPartnerName, value: partnerName);

      if (await FlutterForegroundTask.isRunningService) return;

      // Разрешение на уведомления (А13+) — без него сервис не покажет ни иконку,
      // ни баннеры. Запрашиваем из главного изолята (UI), пока есть контекст.
      // Запрос бросает PlatformException, если юзер закрыл диалог или другой
      // запрос уже в процессе — это не повод падать: сервис всё равно стартует
      // (без разрешения на А13+ просто не будет видимого баннера).
      try {
        final perm = await FlutterForegroundTask.checkNotificationPermission();
        if (perm != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
      } catch (e) {
        debugPrint('PushBackgroundService: запрос разрешения не удался: $e');
      }

      // Старт foreground-сервиса тоже может бросить (напр. на А12+
      // "Service.startForeground() not allowed", если приложение успело уйти в
      // фон между проверкой и стартом) — глушим, чтобы не ронять приложение.
      try {
        await FlutterForegroundTask.startService(
          serviceId: 4711,
          serviceTypes: const [ForegroundServiceTypes.dataSync],
          notificationTitle: 'Togetherly на связи',
          notificationText: 'Получаем уведомления от партнёра',
          // Иконка-сердечко (та же, что у локальных уведомлений) — без неё
          // сервис ставит дефолт/чёрный квадрат в шторке.
          notificationIcon: const NotificationIcon(
            metaDataName: 'com.togetherly.love.notification_icon',
          ),
          callback: pushServiceCallback,
        );
      } catch (e) {
        debugPrint('PushBackgroundService: старт сервиса не удался: $e');
      }
    } finally {
      _starting = false;
    }
  }

  /// Остановить фоновую доставку (выход из аккаунта / распад пары).
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// true, если сервис уже выбрал суточный бюджет dataSync-FGS сегодня.
  Future<bool> _dailyBudgetExhausted() async {
    try {
      final day = await FlutterForegroundTask.getData<String>(key: _kRunDay);
      if (day != _pushDayKey()) return false; // другой день — бюджет сброшен
      final secs =
          await FlutterForegroundTask.getData<int>(key: _kRunSeconds) ?? 0;
      return secs >= _kDailyBudgetSeconds;
    } catch (_) {
      return false;
    }
  }
}

const String _kGroupId = 'push_group_id';
const String _kMyUid = 'push_my_uid';
const String _kPartnerUid = 'push_partner_uid';
const String _kPartnerName = 'push_partner_name';
const String _kRunDay = 'push_run_day'; // YYYY-MM-DD последнего учтённого дня
const String _kRunSeconds = 'push_run_seconds'; // накоплено секунд работы за день

/// Android 14+ отводит foreground-сервису типа dataSync ~6ч суммарно за 24ч,
/// после чего убивает его принудительно (ForegroundServiceDidNotStopInTime →
/// краш). Держим запас: тормозим сами на 5ч30м.
const int _kDailyBudgetSeconds = 5 * 3600 + 30 * 60;

/// Ключ текущих (локальных) суток для учёта бюджета работы сервиса.
String _pushDayKey() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

/// Точка входа изолята foreground-сервиса. ДОЛЖНА быть top-level + vm:entry-point
/// (её адрес передаётся нативной части при старте сервиса).
@pragma('vm:entry-point')
void pushServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_PushTaskHandler());
}

class _PushTaskHandler extends TaskHandler {
  bool _started = false;
  String _groupId = '';
  String _myUid = '';
  String _partnerUid = '';
  // Подписка на изменения партнёром widget_data → мгновенное обновление виджетов.
  RtUnsub? _widgetSub;
  Timer? _widgetDebounce;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _bootstrap();
  }

  /// Поднять PB-сессию и SSE-подписки В ИЗОЛЯТЕ СЕРВИСА. Идемпотентно —
  /// выходит сразу, если уже поднято.
  Future<void> _bootstrap() async {
    if (_started) return;
    try {
      final groupId =
          await FlutterForegroundTask.getData<String>(key: _kGroupId) ?? '';
      final myUid =
          await FlutterForegroundTask.getData<String>(key: _kMyUid) ?? '';
      final partnerUid =
          await FlutterForegroundTask.getData<String>(key: _kPartnerUid) ?? '';
      final partnerName =
          await FlutterForegroundTask.getData<String>(key: _kPartnerName) ??
              'Партнёр';
      if (groupId.isEmpty || partnerUid.isEmpty) return;

      // Изолят свежий — поднимаем клиент PB и восстанавливаем сессию из
      // SharedPreferences (тот же AsyncAuthStore, что и в главном изоляте;
      // токен уже на диске после входа). Свой getInstance читает с диска →
      // видит актуальную сессию.
      await PocketBaseService().init();
      if (!PocketBaseService().isLoggedIn) {
        return; // сессии ещё нет — повтор на watchdog (onRepeatEvent)
      }

      _groupId = groupId;
      _myUid = myUid;
      _partnerUid = partnerUid;

      await PbPushService().init();
      await PbPushService().start(
        groupId: groupId,
        myUid: myUid,
        partnerUid: partnerUid,
        partnerName: partnerName,
      );
      // Виджеты рабочего стола: пока приложение свёрнуто/выгружено, главный
      // изолят (где живёт WidgetService) спит и виджеты застывают. Здесь, в
      // живом изоляте сервиса, слушаем изменения партнёром widget_data и
      // мгновенно обновляем парный/фото/mood-виджеты прямо из PB — без FCM и
      // без открытия приложения.
      await _startWidgetRefresh();
      _started = true;
      debugPrint('PushBackgroundService: SSE-подписки подняты (group=$groupId)');
    } catch (e) {
      debugPrint('PushBackgroundService bootstrap failed: $e');
    }
  }

  Future<void> _startWidgetRefresh() async {
    try {
      _widgetSub = await CentrifugoService.instance.subscribeDelta(
        'pair:$_groupId',
        'widget_data',
        (_) => _scheduleWidgetRefresh(),
        match: (rec) => rec.data['user_uid'] == _partnerUid,
      );
      // Первичная синхронизация: данные могли измениться, пока сокет был мёртв.
      unawaited(_refreshWidgets());
    } catch (e) {
      debugPrint('PushBackgroundService: старт обновления виджетов не удался: $e');
    }
  }

  /// Дебаунс: партнёр за раз меняет несколько полей (статус+настроение+музыка) —
  /// несколько дельт подряд схлопываем в один рефреш виджетов.
  void _scheduleWidgetRefresh() {
    _widgetDebounce?.cancel();
    _widgetDebounce =
        Timer(const Duration(milliseconds: 600), () => unawaited(_refreshWidgets()));
  }

  Future<void> _refreshWidgets({bool refreshPhotos = true}) async {
    if (_groupId.isEmpty || _myUid.isEmpty) return;
    try {
      await HomeWidgetService.instance.backgroundRefreshAll(
        groupId: _groupId,
        myUid: _myUid,
        partnerUid: _partnerUid,
        refreshPhotos: refreshPhotos,
      );
    } catch (e) {
      debugPrint('PushBackgroundService: фоновый рефреш виджетов упал: $e');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Учёт суточного бюджета dataSync-FGS — тормозим до принудительного таймаута.
    unawaited(_tickRuntimeBudget());
    // watchdog: если не поднялись (старт раньше входа) — пробуем снова;
    // иначе раз в минуту дёшево освежаем парный/mood-виджет как страховку от
    // пропущенной дельты (без перекачивания фото — оно тянется на каждом вызове).
    if (!_started) {
      unawaited(_bootstrap());
    } else {
      unawaited(_refreshWidgets(refreshPhotos: false));
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _widgetDebounce?.cancel();
    _widgetDebounce = null;
    _started = false;
    final ws = _widgetSub;
    _widgetSub = null;

    // На таймауте (Android 14+ прибил сервис по лимиту dataSync) у нас считанные
    // секунды на остановку. Сетевой teardown на мёртвом сокете может зависнуть и
    // не дать сервису закрыться → ForegroundServiceDidNotStopInTimeException.
    // Поэтому на таймауте чистим в фоне, не блокируя onDestroy.
    if (isTimeout) {
      unawaited(_teardown(ws));
      return;
    }
    await _teardown(ws);
  }

  Future<void> _teardown(RtUnsub? ws) async {
    if (ws != null) {
      try {
        await ws();
      } catch (_) {}
    }
    try {
      await PbPushService().stop();
    } catch (_) {}
  }

  /// Копит суммарное время работы FGS за сутки (переживает рестарты через
  /// saveData) и штатно останавливает сервис до 6-часового лимита dataSync,
  /// чтобы Android 14+ не убил его принудительно с краш-исключением.
  Future<void> _tickRuntimeBudget() async {
    try {
      final today = _pushDayKey();
      final storedDay =
          await FlutterForegroundTask.getData<String>(key: _kRunDay);
      int seconds;
      if (storedDay == today) {
        seconds =
            await FlutterForegroundTask.getData<int>(key: _kRunSeconds) ?? 0;
      } else {
        seconds = 0;
        await FlutterForegroundTask.saveData(key: _kRunDay, value: today);
      }
      seconds += 60; // период eventAction.repeat(60000)
      await FlutterForegroundTask.saveData(key: _kRunSeconds, value: seconds);
      if (seconds >= _kDailyBudgetSeconds) {
        debugPrint('PushBackgroundService: суточный бюджет FGS исчерпан '
            '($seconds c) — останавливаемся штатно');
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('PushBackgroundService: watchdog бюджета упал: $e');
    }
  }
}
