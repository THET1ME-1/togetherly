import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:pocketbase/pocketbase.dart';

import '../models/gift.dart';
import '../models/gift_effect.dart';
import 'centrifugo_service.dart';
import 'locale_service.dart';
import 'pocketbase_service.dart';

/// Пуш-уведомления БЕЗ Firebase (миграция Firebase→PB, Этап 6, слой Пуш).
///
/// Заменяет связку «event-документ → Cloud Function → FCM → клиент». Теперь:
/// партнёр пишет в PB (chat_messages / mood_entries / miss_you / memories) → PB
/// публикует дельту в Centrifugo → подписчик её получает по WebSocket →
/// приложение поднимает ЛОКАЛЬНОЕ уведомление. Ноль FCM/Google. Для доставки в
/// фоне сервис крутится в Android foreground-сервисе (держит WS живым) — см.
/// cutover-интеграцию.
///
/// Тексты уведомлений зеркалят прежние Cloud Functions (onMissYouEvent/
/// onWidgetDataEvent/onChatMessageEvent).
class PbPushService {
  PbPushService._();
  static final PbPushService instance = PbPushService._();
  factory PbPushService() => instance;

  /// Группа открытого сейчас чата — пуш о новом сообщении этой группы не
  /// показываем (чат и так на экране). Раньше жил в FirebaseService.
  static String? activeChatGroupId;

  final FlutterLocalNotificationsPlugin _ln = FlutterLocalNotificationsPlugin();
  static const String _channelId = 'partner_notifications';
  static const String _channelName = 'Уведомления от партнёра';

  bool _inited = false;
  final List<UnsubscribeFunc> _subs = [];
  // дедуп: последний показанный счётчик «скучаю» и настроение партнёра
  int? _lastMissCount;
  String? _lastMood;

  /// Инициализация плагина локальных уведомлений + канал + разрешение (А13+).
  Future<void> init() async {
    if (_inited) return;
    const android = AndroidInitializationSettings('@drawable/ic_notification');
    const ios = DarwinInitializationSettings();
    await _ln.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
    );
    final androidImpl = _ln.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Сообщения, настроение и «скучаю» от партнёра',
        importance: Importance.high,
      ),
    );
    await androidImpl?.requestNotificationsPermission();
    _inited = true;
  }

  /// Настройки уведомлений текущего юзера (его профиль решает, что показывать).
  bool _pref(String col) {
    final v = PocketBaseService().currentUser?.data[col];
    return v is bool ? v : true; // по умолчанию включено
  }

  /// Тихая ночь: подарок «Сладких снов» гасит уведомления до восьми утра.
  /// Партнёр дарит тишину, а не просто картинку.
  bool get _muted {
    final until =
        (PocketBaseService().currentUser?.data['mute_until'] as num?)?.toInt();
    return isEffectActive(until, DateTime.now());
  }

  // Сериализация start/stop. Подписки в _subs мутируются и из start(), и из
  // stop(), а stop() итерирует список с `await` внутри. Без взаимоблокировки
  // два пересекающихся start() (быстрая смена пары, повторный resume, гонка
  // главного изолята и foreground-сервиса) роняли ConcurrentModificationError
  // (см. Bugsink: pb_push_service.dart:stop) и плодили дубли подписок.
  // Цепочка-мьютекс гарантирует строго последовательное выполнение операций.
  Future<void> _lock = Future<void>.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final prev = _lock;
    _lock = completer.future.then((_) {}, onError: (_) {});
    prev.whenComplete(() async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Запускает подписки на события партнёра в группе. [partnerUid] — чей
  /// активности уведомляем (только не свои). Сериализовано с [stop].
  Future<void> start({
    required String groupId,
    required String myUid,
    required String partnerUid,
    String partnerName = 'Партнёр',
  }) =>
      _synchronized(() => _startLocked(
            groupId: groupId,
            myUid: myUid,
            partnerUid: partnerUid,
            partnerName: partnerName,
          ));

  Future<void> _startLocked({
    required String groupId,
    required String myUid,
    required String partnerUid,
    String partnerName = 'Партнёр',
  }) async {
    if (groupId.isEmpty) return;
    await init();
    await _stopLocked();

    // 1) Чат
    _subs.add(await CentrifugoService.instance
        .subscribeDelta('pair:$groupId', 'chat_messages', (e) {
      try {
        if (e.action != 'create') return;
        final r = e.record;
        if (r == null || r.data['user_uid'] != partnerUid) return;
        if (activeChatGroupId == groupId) return; // чат открыт — не дублируем
        if (r.data['deleted'] == true || !_pref('notif_chat')) return;
        final name = (r.data['user_name'] ?? partnerName).toString();
        final text = (r.data['text'] ?? '').toString();
        _notify(r.id.hashCode, name, text.isEmpty ? '✉️' : text);
      } catch (err) {
        debugPrint('PbPush chat callback error: $err');
      }
    }));

    // 2) Реакция/настроение дня (mood_entries партнёра). Раньше слушали
    //    widget_data.mood_label, но «реакцию на день» правит mood_entries —
    //    его и слушаем (источник истины календаря настроений; ловит и смену
    //    реакции прошлого дня, а не только текущей на виджете).
    _subs.add(await CentrifugoService.instance
        .subscribeDelta('pair:$groupId', 'mood_entries', (e) {
      try {
        if (e.action != 'create' && e.action != 'update') return;
        final r = e.record;
        if (r == null || r.data['user_uid'] != partnerUid) return;
        if (!_pref('notif_mood')) return;
        final label = (r.data['label'] ?? '').toString();
        final key = '${r.id}|$label';
        if (key == _lastMood) return; // дедуп повторных эмитов того же
        _lastMood = key;
        _notify(('mood$partnerUid').hashCode, partnerName,
            label.isEmpty ? 'Отметил реакцию дня 🗓️' : 'Реакция дня: $label');
      } catch (err) {
        debugPrint('PbPush mood callback error: $err');
      }
    }));

    // 3) «Скучаю» (miss_you партнёра)
    _subs.add(await CentrifugoService.instance
        .subscribeDelta('pair:$groupId', 'miss_you', (e) {
      try {
        final r = e.record;
        if (r == null || r.data['user_uid'] != partnerUid) return;
        final cnt = (r.data['count'] as num?)?.toInt() ?? 0;
        if (_lastMissCount != null && cnt <= _lastMissCount!) return; // только рост
        final vibe = (r.data['last_vibe'] ?? 'miss_you').toString();
        final custom = (r.data['last_vibe_text'] ?? '').toString();
        // custom доставляется всегда; остальное — по настройке notif_miss_you
        if (vibe != 'custom' && !_pref('notif_miss_you')) return; // check BEFORE state mutation
        _lastMissCount = cnt;
        _notify(('miss$partnerUid$cnt').hashCode, partnerName, _vibeBody(vibe, custom));
      } catch (err) {
        debugPrint('PbPush miss_you callback error: $err');
      }
    }));

    // 4) Новое воспоминание (memories партнёра)
    _subs.add(await CentrifugoService.instance
        .subscribeDelta('pair:$groupId', 'memories', (e) {
      try {
        if (e.action != 'create') return;
        final r = e.record;
        if (r == null || r.data['author_uid'] != partnerUid) return;
        if (r.data['deleted'] == true || !_pref('notif_new_memory')) return;
        final name = (r.data['author_name'] ?? partnerName).toString();
        _notify(('mem${r.id}').hashCode, name, 'Добавил новое воспоминание 📸');
      } catch (err) {
        debugPrint('PbPush memory callback error: $err');
      }
    }));

    // 5) Подарок от партнёра (gifts). Слушаем только доставку: отклик меняет ту
    //    же запись на state=reacted, и повторное уведомление там не нужно.
    _subs.add(await CentrifugoService.instance
        .subscribeDelta('pair:$groupId', 'gifts', (e) {
      try {
        if (e.action != 'create') return;
        final r = e.record;
        if (r == null || r.data['recipient_uid'] != myUid) return;
        if (r.data['state'] != 'sent') return;
        if (!_pref('notif_gifts')) return; // поля нет в профиле → _pref даёт true
        final gift = GiftCatalog.byKey((r.data['gift_key'] ?? '').toString());
        if (gift == null) return; // подарок из будущей версии приложения
        _notify(('gift${r.id}').hashCode, partnerName,
            LocaleService.current.giftPushBody(gift.title));
      } catch (err) {
        debugPrint('PbPush gift callback error: $err');
      }
    }));

    debugPrint('PbPush: подписки запущены (group=$groupId, partner=$partnerUid)');
  }


  /// Тело уведомления по типу вайба (зеркало Cloud Functions buildVibePayload).
  String _vibeBody(String vibe, String text) {
    switch (vibe) {
      case 'thinking_of_you':
        return 'Думает о тебе 💭';
      case 'want_hug':
        return 'Хочет обнять тебя 🤗';
      case 'custom':
        return text.isNotEmpty ? text : '✉️';
      default:
        return 'Думает о тебе и вспоминает 💭';
    }
  }

  /// Публичный показ локального уведомления (бейджи, награды и т.п.).
  /// Заменяет прежний FirebaseService.showLocalNotification. Гарантирует
  /// инициализацию плагина перед показом.
  Future<void> showLocal({
    required int id,
    required String title,
    required String body,
  }) async {
    await init();
    await _notify(id, title, body);
  }

  Future<void> _notify(int id, String title, String body) async {
    if (_muted) {
      debugPrint('PbPush: тихая ночь — уведомление не показываем');
      return;
    }
    await _ln.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Сообщения, настроение и «скучаю» от партнёра',
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
    );
  }

  Future<void> stop() => _synchronized(_stopLocked);

  Future<void> _stopLocked() async {
    // Снимок + немедленная очистка живого списка ДО итерации: даже если новый
    // start() как-то добавит подписку в _subs, мы итерируем неизменяемую копию,
    // а он пишет уже в свежий список — ConcurrentModificationError невозможен.
    final subs = List<UnsubscribeFunc>.of(_subs);
    _subs.clear();
    for (final u in subs) {
      try {
        await u();
      } catch (err) {
        debugPrint('PbPush unsubscribe error: $err');
      }
    }
    _lastMissCount = null;
    _lastMood = null;
  }
}
