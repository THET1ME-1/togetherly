import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import 'centrifugo_service.dart';
import 'offline/connectivity_service.dart';
import 'offline/local_store.dart';
import 'offline/outbox_service.dart';
import 'offline/record_scope.dart';
import 'pocketbase_service.dart';

/// Realtime-слой (миграция Firebase→PB, Этап 6; транспорт перенесён с SSE PB на
/// Centrifugo, см. [CentrifugoService] и серверный хук centrifugo.pb.js).
///
/// Начальная загрузка и инкрементальная синхронизация остаются на REST PB (чтения
/// на self-hosted БЕСПЛАТНЫ → списки без лимитов/пагинации; кнопки «обновить» не
/// нужны, см. memory togetherly_pb_realtime_no_limits). А ЖИВЫЕ ДЕЛЬТЫ теперь
/// приходят через Centrifugo (WebSocket): PB на изменение записи публикует дельту
/// в канал пары, клиент её получает. ЗАЧЕМ перенос: SSE PB держал долгоживущие
/// read-транзакции SQLite → WAL не чекпойнтился, PB упирался в CPU.
///
/// Дженерики:
///  • [watchList]   — начальная полная загрузка (`getFullList`) + дельты Centrifugo
///    (create/update/delete мёржатся в локальный список → `Stream<List>`).
///  • [watchRecord] — один документ по id (напр. группа) → `Stream<RecordModel?>`.
///  Обёртки передают `rtChannel` (канал Centrifugo) и `rtMatch` (клиентский фильтр
///  дельт: канал `pair:<id>` несёт изменения всей пары, лишнее отсекаем).
///
/// Ограничение (RT-10): события, пропущенные за время обрыва WebSocket, не
/// переигрываются (history каналов выключен ради экономии RAM). Для кэш-вариантов
/// это закрывает ре-синхронизация по возврату сети (`conn.onOnlineChanged` →
/// `syncOnce`); для in-memory-вариантов список может быть устаревшим до следующей
/// дельты — как и прежде на SSE.
class PbRealtimeService {
  PbRealtimeService._();
  static final PbRealtimeService instance = PbRealtimeService._();
  factory PbRealtimeService() => instance;

  PocketBase get _pb => PocketBaseService().pb;

  // RT-3 / Фикс #1: общий джиттер-backoff для авто-ретрая подписок. Джиттер
  // критичен — без него после рестарта/моргания PB все клиенты ломятся
  // переподключаться синхронно (thundering herd). 429 (сервер просит
  // притормозить) обрабатывается отдельным длинным полом в самих start().
  static final _rnd = Random();
  static int _backoffMs(int attempt) {
    final base = 1000 * (1 << (attempt > 5 ? 5 : attempt)); // 1,2,4,…,32с
    return base ~/ 2 + _rnd.nextInt(base ~/ 2 + 1); // равный джиттер: [base/2, base]
  }

  // ── сравнители для сортировки ───────────────────────────────────────────
  /// ISO-строки сравниваются лексикографически = хронологически.
  static int _strAsc(dynamic a, dynamic b) =>
      (a ?? '').toString().compareTo((b ?? '').toString());
  static int _strDesc(dynamic a, dynamic b) => _strAsc(b, a);
  /// RT-7: безопасное приведение к числу — PB-значение может прийти строкой
  /// (json-колонка, коэрсинг), поэтому жёсткий `as num?` падал. Не-числа → 0.
  static num _asNum(dynamic v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v) ?? 0;
    return 0;
  }

  static int _numAsc(dynamic a, dynamic b) => _asNum(a).compareTo(_asNum(b));

  /// Живой список записей коллекции по [filter]: полная загрузка + SSE-дельты.
  /// [compare] — сортировка снапшота (по умолчанию без сортировки).
  Stream<List<RecordModel>> watchList(
    String collection, {
    String? filter,
    RecordScope? scope,
    int Function(RecordModel, RecordModel)? compare,
    String? rtChannel,
    bool Function(RecordModel)? rtMatch,
    int? windowLimit,
    String? windowSort,
  }) {
    // Offline-first: при наличии [scope] поток обслуживается из локального кэша
    // (sembast), а сеть лишь досыпает изменения. Без [scope] — прежнее in-memory
    // поведение (не-переведённые обёртки + live-only коллекции).
    // [rtChannel]/[rtMatch] — канал Centrifugo и клиентский фильтр дельт (канал
    // pair:<id> несёт изменения всей пары, лишнее отсекаем по collection+match).
    // [windowLimit]/[windowSort] — «ленивый» режим (чат): начальная выборка лишь
    // новейших windowLimit записей (sort=windowSort), а не всей истории; догрузка
    // старых — повторная подписка с бо́льшим лимитом (см. chat_screen `_loadMore`).
    if (scope != null) {
      return _watchCached(collection, filter, scope, compare, rtChannel, rtMatch,
          windowLimit, windowSort);
    }
    final byId = <String, RecordModel>{};
    UnsubscribeFunc? unsub;
    // Гонка: слушатель может отписаться (onCancel), пока ещё идёт начальная
    // загрузка/подписка в start(). Тогда unsub ещё null → onCancel ничего не
    // отменяет, а subscribe() резолвится позже и оставляет живую SSE-подписку
    // навсегда (утечка). Флаг закрывает гонку: если отменили во время старта,
    // только что созданную подписку рвём и не сохраняем.
    var cancelled = false;
    var attempt = 0; // RT-3: счётчик попыток для backoff-ретрая
    late StreamController<List<RecordModel>> ctrl;

    List<RecordModel> snapshot() {
      final list = byId.values.toList();
      if (compare != null) list.sort(compare);
      return list;
    }

    Future<void> start() async {
      cancelled = false;
      try {
        // Фикс #1: начальную ПОЛНУЮ загрузку делаем только если снапшота ещё нет.
        // На ретрае (подписка отвалилась, но данные уже есть) НЕ перекачиваем весь
        // список заново — лишь переподписываемся. Убирает «перекачать всё» при
        // каждом обрыве и снимает часть нагрузки thundering herd после рестарта PB.
        if (byId.isEmpty) {
          final initial =
              await _pb.collection(collection).getFullList(filter: filter);
          if (cancelled) return;
          byId
            ..clear()
            ..addEntries(initial.map((r) => MapEntry(r.id, r)));
          if (!ctrl.isClosed) ctrl.add(snapshot());
        }
        // Дельты из Centrifugo (вместо SSE PB). Канал несёт изменения всей пары;
        // фильтр по collection+match делает CentrifugoService. Без rtChannel —
        // только начальная загрузка (realtime не подключаем).
        if (rtChannel == null) {
          attempt = 0;
          return;
        }
        final u = await CentrifugoService.instance.subscribeDelta(
          rtChannel,
          collection,
          (e) {
            final rec = e.record;
            if (rec == null) return;
            if (e.action == 'delete') {
              byId.remove(rec.id);
            } else {
              byId[rec.id] = rec;
            }
            if (!ctrl.isClosed) ctrl.add(snapshot());
          },
          match: rtMatch,
        );
        if (cancelled) {
          await u(); // отменили, пока подписывались — рвём и не сохраняем
          return;
        }
        unsub = u;
        attempt = 0; // успех — сбрасываем backoff
      } catch (err) {
        // RT-3: вместо «застрять в ошибке навсегда» — авто-ретрай с экспоненциальным
        // backoff (1,2,4,…,32с), пока стрим жив и не отменён. Транзиентные сетевые
        // сбои/недоступность PB самовосстанавливаются без ручного «обновить».
        debugPrint('PbRealtime.watchList($collection) failed (attempt $attempt): $err');
        if (cancelled || ctrl.isClosed || !ctrl.hasListener) return;
        // Фикс #1: backoff с джиттером (не синхронно); на 429 — длинный пол 30–60с.
        final is429 = err is ClientException && err.statusCode == 429;
        final delayMs =
            is429 ? 30000 + _rnd.nextInt(30000) : _backoffMs(attempt);
        attempt++;
        Future.delayed(Duration(milliseconds: delayMs), () {
          if (!cancelled && !ctrl.isClosed && ctrl.hasListener) start();
        });
      }
    }

    ctrl = StreamController<List<RecordModel>>.broadcast(
      onListen: start,
      onCancel: () async {
        cancelled = true;
        await unsub?.call();
        unsub = null;
      },
    );
    return ctrl.stream;
  }

  /// Живой одиночный документ по id (напр. group-doc). delete → null.
  /// [useCache]=true → offline-first кэш-вариант (sembast + сеть в фоне).
  Stream<RecordModel?> watchRecord(String collection, String id,
      {bool useCache = false, String? rtChannel}) {
    if (useCache) return _watchRecordCached(collection, id, rtChannel);
    UnsubscribeFunc? unsub;
    var cancelled = false; // та же гонка отписки-во-время-старта, что в watchList
    var attempt = 0; // RT-3: счётчик попыток для backoff-ретрая
    var loaded = false; // Фикс #1: начальный getOne уже сделан — на ретрае пропускаем
    late StreamController<RecordModel?> ctrl;

    Future<void> start() async {
      cancelled = false;
      try {
        // Фикс #1: начальный getOne только если ещё не грузили. На ретрае
        // (подписка отвалилась, запись уже есть) — лишь переподписываемся.
        if (!loaded) {
          try {
            final rec = await _pb.collection(collection).getOne(id);
            if (cancelled) return;
            if (!ctrl.isClosed) ctrl.add(rec);
            loaded = true;
          } on ClientException catch (e) {
            if (e.statusCode == 404) {
              if (!ctrl.isClosed) ctrl.add(null);
              loaded = true;
            } else {
              rethrow;
            }
          }
        }
        if (cancelled) return;
        // Дельты одного документа из Centrifugo. match по id — на канале пары
        // может быть несколько записей коллекции, нам нужна ровно эта.
        if (rtChannel == null) {
          attempt = 0;
          return;
        }
        final u = await CentrifugoService.instance.subscribeDelta(
          rtChannel,
          collection,
          (e) {
            if (e.action == 'delete') {
              if (!ctrl.isClosed) ctrl.add(null);
            } else {
              final rec = e.record;
              if (rec != null && !ctrl.isClosed) ctrl.add(rec);
            }
          },
          match: (r) => r.id == id,
        );
        if (cancelled) {
          await u();
          return;
        }
        unsub = u;
        attempt = 0; // успех — сбрасываем backoff
      } catch (err) {
        // RT-3: авто-ретрай с backoff (1,2,4,…,32с) вместо застревания в ошибке.
        debugPrint('PbRealtime.watchRecord($collection/$id) failed (attempt $attempt): $err');
        if (cancelled || ctrl.isClosed || !ctrl.hasListener) return;
        // Фикс #1: backoff с джиттером; на 429 — длинный пол 30–60с.
        final is429 = err is ClientException && err.statusCode == 429;
        final delayMs =
            is429 ? 30000 + _rnd.nextInt(30000) : _backoffMs(attempt);
        attempt++;
        Future.delayed(Duration(milliseconds: delayMs), () {
          if (!cancelled && !ctrl.isClosed && ctrl.hasListener) start();
        });
      }
    }

    ctrl = StreamController<RecordModel?>.broadcast(
      onListen: start,
      onCancel: () async {
        cancelled = true;
        await unsub?.call();
        unsub = null;
      },
    );
    return ctrl.stream;
  }

  // ── offline-first: кэш-ориентированные варианты ───────────────────────────
  /// Кэш-бэкенд для [watchList]: поток из локального кэша (sembast) + фоновая
  /// инкрементальная синхронизация (дельта по `updated` — уже загруженное
  /// повторно НЕ качаем) + SSE-дельты прямо в кэш. UI всегда читает из кэша →
  /// мгновенно и офлайн. [networkFilter] — «контейнерный» фильтр (шире scope:
  /// без soft-delete-флагов), чтобы мягкие удаления долетали дельтой как
  /// надгробия; из выдачи их прячет [scope].
  Stream<List<RecordModel>> _watchCached(
    String collection,
    String? networkFilter,
    RecordScope scope,
    int Function(RecordModel, RecordModel)? compare,
    String? rtChannel,
    bool Function(RecordModel)? rtMatch,
    int? windowLimit,
    String? windowSort,
  ) {
    final store = LocalStore.instance;
    final conn = ConnectivityService.instance;
    UnsubscribeFunc? unsub;
    StreamSubscription<List<RecordModel>>? cacheSub;
    StreamSubscription<bool>? connSub;
    var cancelled = false;
    var attempt = 0;
    late StreamController<List<RecordModel>> ctrl;

    // Инкрементальная синхронизация: при первом разе — постранично всё (по
    // `updated`), далее — только `updated > водяной_знак` (страницами). Каждую
    // страницу сразу применяем в кэш (прогрессивно, не одним блобом).
    Future<void> syncOnce() async {
      // Ленивый режим (чат): тянем ТОЛЬКО новейшие windowLimit записей (sort по
      // windowSort, напр. '-ts'), без пагинации всей истории и без водяного знака.
      // Догрузку старых делает UI повторной подпиской с бо́льшим лимитом
      // (chat_screen `_loadMore` → `_limit += _kPageSize`). Живые новые приходят
      // дельтой Centrifugo (подписка ниже). Кэш накапливает просмотренное.
      if (windowLimit != null) {
        // Per-request таймаут: если writer сервера придушен (столл до 30с — см.
        // p99-инцидент), getList не должен висеть на ПЕРВОЙ загрузке (пустой кэш).
        // По таймауту бросаем → ловит catch в startNetwork → backoff-ретрай; стрим
        // жив, а cache-first эмиссия уже показала кэш.
        final res = await _pb
            .collection(collection)
            .getList(
              page: 1,
              perPage: windowLimit,
              filter: networkFilter ?? '',
              sort: windowSort ?? '-updated',
            )
            .timeout(const Duration(seconds: 12));
        if (cancelled) return;
        final toApply = res.items
            .where((r) => !OutboxService.instance.isPending(collection, r.id))
            .toList();
        if (toApply.isNotEmpty) await store.applyDelta(collection, toApply);
        return;
      }
      final token = scope.token;
      final wm = await store.lastUpdated(token);
      final baseFilter = networkFilter ?? '';
      String maxU = wm ?? '';
      final String pageFilter;
      if (wm == null) {
        pageFilter = baseFilter;
      } else {
        final wmCond = _pb.filter('updated > {:w}', {'w': wm});
        pageFilter = baseFilter.isEmpty ? wmCond : '($baseFilter) && ($wmCond)';
      }
      var page = 1;
      while (!cancelled) {
        // Per-request таймаут (как выше): застрявший getList → таймаут → ретрай,
        // а не вечный hang страницы под серверным столлом.
        final res = await _pb
            .collection(collection)
            .getList(
              page: page,
              perPage: 200,
              filter: pageFilter,
              sort: 'updated',
            )
            .timeout(const Duration(seconds: 12));
        if (res.items.isEmpty) break;
        // Не перезатираем записи с неотправленными локальными правками
        // (водяной знак двигаем по ВСЕМ, т.к. их серверный `updated` всё равно
        // старый — после отправки правки строка получит новый `updated` и
        // до-синхронизируется инкрементом).
        final toApply = res.items
            .where((r) => !OutboxService.instance.isPending(collection, r.id))
            .toList();
        if (toApply.isNotEmpty) await store.applyDelta(collection, toApply);
        for (final r in res.items) {
          final u = r.data['updated'];
          if (u is String && u.compareTo(maxU) > 0) maxU = u;
        }
        if (page >= res.totalPages) break;
        page++;
      }
      if (maxU.isNotEmpty && (wm == null || maxU.compareTo(wm) > 0)) {
        await store.setLastUpdated(token, maxU);
      }
    }

    Future<void> startNetwork() async {
      if (cancelled || !conn.isOnline) return;
      try {
        await syncOnce();
        if (cancelled) return;
        if (unsub == null && rtChannel != null) {
          final u = await CentrifugoService.instance.subscribeDelta(
            rtChannel,
            collection,
            (e) {
              final rec = e.record;
              if (rec == null) return;
              // Запись с неотправленной правкой не трогаем (и водяной знак по ней
              // не двигаем — до-синхронизируется после отправки правки).
              if (OutboxService.instance.isPending(collection, rec.id)) return;
              if (e.action == 'delete') {
                unawaited(store.deleteRecord(collection, rec.id));
              } else {
                unawaited(store.upsert(collection, rec));
                final upd = rec.data['updated'];
                if (upd is String && upd.isNotEmpty) {
                  unawaited(store.bumpWatermark(scope.token, upd));
                }
              }
            },
            match: rtMatch,
          );
          if (cancelled) {
            await u();
            return;
          }
          unsub = u;
        }
        attempt = 0;
      } catch (err) {
        debugPrint(
            'PbRealtime._watchCached($collection) failed (attempt $attempt): $err');
        if (cancelled || ctrl.isClosed || !ctrl.hasListener) return;
        final is429 = err is ClientException && err.statusCode == 429;
        final delayMs =
            is429 ? 30000 + _rnd.nextInt(30000) : _backoffMs(attempt);
        attempt++;
        Future.delayed(Duration(milliseconds: delayMs), () {
          if (!cancelled && !ctrl.isClosed && ctrl.hasListener) startNetwork();
        });
      }
    }

    ctrl = StreamController<List<RecordModel>>.broadcast(
      onListen: () {
        cancelled = false;
        cacheSub =
            store.watchScope(collection, scope, compare: compare).listen((list) {
          if (!ctrl.isClosed) ctrl.add(list);
        });
        startNetwork();
        // Переподключение сети → догоняем пропущенные изменения (дельта) и при
        // необходимости пере-подписываемся (закрывает RT-10 на офлайн-окне).
        connSub = conn.onOnlineChanged.listen((online) {
          if (online && !cancelled) startNetwork();
        });
      },
      onCancel: () async {
        cancelled = true;
        await cacheSub?.cancel();
        cacheSub = null;
        await connSub?.cancel();
        connSub = null;
        await unsub?.call();
        unsub = null;
      },
    );
    return ctrl.stream;
  }

  /// Кэш-бэкенд для [watchRecord] (одиночный документ, напр. группа).
  Stream<RecordModel?> _watchRecordCached(
      String collection, String id, String? rtChannel) {
    final store = LocalStore.instance;
    final conn = ConnectivityService.instance;
    UnsubscribeFunc? unsub;
    StreamSubscription<RecordModel?>? cacheSub;
    StreamSubscription<bool>? connSub;
    var cancelled = false;
    var attempt = 0;
    late StreamController<RecordModel?> ctrl;

    Future<void> startNetwork() async {
      if (cancelled || !conn.isOnline) return;
      try {
        try {
          final rec = await _pb
              .collection(collection)
              .getOne(id)
              .timeout(const Duration(seconds: 12));
          if (cancelled) return;
          // Не перезатираем локальную запись серверным стейлом, пока её правка
          // ещё не отправлена из очереди — иначе оптимистичное изменение
          // «откатывается» (маскот телепортируется назад, настроение/статус
          // возвращается). После подтверждения отправки isPending снимется и
          // следующий getOne/дельта принесёт согласованное значение.
          if (!OutboxService.instance.isPending(collection, id)) {
            await store.upsert(collection, rec);
          }
        } on ClientException catch (e) {
          if (e.statusCode == 404) {
            if (!OutboxService.instance.isPending(collection, id)) {
              await store.deleteRecord(collection, id);
            }
          } else {
            rethrow;
          }
        }
        if (cancelled) return;
        if (unsub == null && rtChannel != null) {
          final u = await CentrifugoService.instance.subscribeDelta(
            rtChannel,
            collection,
            (e) {
              // Не перезатираем запись с неотправленной локальной правкой.
              if (OutboxService.instance.isPending(collection, id)) return;
              if (e.action == 'delete') {
                unawaited(store.deleteRecord(collection, id));
              } else {
                final rec = e.record;
                if (rec != null) unawaited(store.upsert(collection, rec));
              }
            },
            match: (r) => r.id == id,
          );
          if (cancelled) {
            await u();
            return;
          }
          unsub = u;
        }
        attempt = 0;
      } catch (err) {
        debugPrint(
            'PbRealtime._watchRecordCached($collection/$id) failed (attempt $attempt): $err');
        if (cancelled || ctrl.isClosed || !ctrl.hasListener) return;
        final is429 = err is ClientException && err.statusCode == 429;
        final delayMs =
            is429 ? 30000 + _rnd.nextInt(30000) : _backoffMs(attempt);
        attempt++;
        Future.delayed(Duration(milliseconds: delayMs), () {
          if (!cancelled && !ctrl.isClosed && ctrl.hasListener) startNetwork();
        });
      }
    }

    ctrl = StreamController<RecordModel?>.broadcast(
      onListen: () {
        cancelled = false;
        cacheSub = store.watchRecord(collection, id).listen((rec) {
          if (!ctrl.isClosed) ctrl.add(rec);
        });
        startNetwork();
        connSub = conn.onOnlineChanged.listen((online) {
          if (online && !cancelled) startNetwork();
        });
      },
      onCancel: () async {
        cancelled = true;
        await cacheSub?.cancel();
        cacheSub = null;
        await connSub?.cancel();
        connSub = null;
        await unsub?.call();
        unsub = null;
      },
    );
    return ctrl.stream;
  }

  // ── типизированные обёртки (фильтр+сортировка под каждую сущность) ───────
  /// Группа (метаданные пары) — live. Замена listenToPair.
  Stream<RecordModel?> watchGroup(String groupId) =>
      watchRecord('groups', groupId, useCache: true, rtChannel: 'pair:$groupId');

  /// Живой список всех активных групп пользователя — замена Firestore user-doc
  /// листенера (pairIds). Членство в PB = массив `groups.members`, поэтому новые
  /// пары и выход партнёра приезжают как create/delete в этом отфильтрованном
  /// списке. Используется ConnectionsManager для обнаружения пар.
  Stream<List<RecordModel>> watchMyGroups(String uid) => watchList(
        'groups',
        // Сетевой фильтр шире scope: тянем и распущенные (как надгробия), чтобы
        // офлайн-роспуск долетал дельтой; из списка их прячет scope.
        filter: _pb.filter('members ~ {:u}', {'u': uid}),
        scope: RecordScope('mygroups:u=$uid',
            contains: {'members': uid}, equals: {'disbanded': false}),
        // Изменения групп сервер шлёт в user:<member> (см. centrifugo.pb.js) →
        // появление новой пары/выход партнёра приезжает на свой user-канал.
        rtChannel: 'user:$uid',
      );

  /// Состояние co-watch сеанса (id=pairId) → запись|null (null = сеанс завершён).
  Stream<RecordModel?> watchSession(String pairId) =>
      watchRecord('live_sessions', pairId, rtChannel: 'pair:$pairId');

  /// Презенс сеанса — записи участников (свежесть оценивает вызывающий).
  Stream<List<RecordModel>> watchSessionPresence(String pairId) => watchList(
        'live_session_presence',
        filter: _pb.filter('pair_id = {:p}', {'p': pairId}),
        rtChannel: 'pair:$pairId',
      );

  /// Чат сеанса — старые сверху (по ts).
  Stream<List<RecordModel>> watchSessionChat(String pairId) => watchList(
        'live_session_chat',
        filter: _pb.filter('pair_id = {:p}', {'p': pairId}),
        compare: (a, b) => _numAsc(a.data['ts'], b.data['ts']),
        rtChannel: 'pair:$pairId',
      );

  /// Точка live-локации участника [uid] в канале пары → запись|null.
  Stream<RecordModel?> watchLivePoint(String channel, String uid) => watchList(
        'live_location',
        filter: _pb.filter(
            'channel = {:c} && user_uid = {:u}', {'c': channel, 'u': uid}),
        rtChannel: 'loc:$channel',
        rtMatch: (r) => r.data['user_uid'] == uid,
      ).map((rows) => rows.isEmpty ? null : rows.first);

  /// Презенс «онлайн» пользователя [uid] → запись|null (seen_at, heartbeat+TTL).
  Stream<RecordModel?> watchPresence(String uid) => watchList(
        'user_presence',
        filter: _pb.filter('user_uid = {:u}', {'u': uid}),
        rtChannel: 'user:$uid',
      ).map((rows) => rows.isEmpty ? null : rows.first);

  /// Активное приглашение co-watch (json-поле `groups.active_session`) → Map|null.
  /// Де-дуп по сырому значению: group-док шлёт событие на любое изменение, а
  /// баннер приглашения должен реагировать только на смену active_session.
  Stream<Map<String, dynamic>?> watchActiveSession(String groupId) {
    String? prevSig;
    return watchGroup(groupId).map((rec) => rec?.data['active_session']).where((raw) {
      final sig = raw?.toString() ?? '';
      if (sig == prevSig) return false;
      prevSig = sig;
      return true;
    }).map((raw) => raw is Map ? Map<String, dynamic>.from(raw) : null);
  }

  /// Лента воспоминаний — БЕЗ лимита, новые сверху, soft-deleted скрыты.
  Stream<List<RecordModel>> watchMemories(String groupId) => watchList(
        'memories',
        // Шире scope (без deleted): мягкое удаление долетает дельтой как
        // надгробие, из ленты его прячет scope (deleted=false).
        filter: _pb.filter('group_id = {:g}', {'g': groupId}),
        scope: RecordScope('memories:g=$groupId',
            equals: {'group_id': groupId, 'deleted': false}),
        compare: (a, b) =>
            _strDesc(a.data['created_at'], b.data['created_at']),
        rtChannel: 'pair:$groupId',
      );

  /// Комментарии воспоминания — старые сверху. [groupId] нужен для канала пары
  /// (комменты группы летят на `pair:<groupId>`, нужный memory фильтруем клиентом).
  Stream<List<RecordModel>> watchComments(String groupId, String memoryId) =>
      watchList(
        'memory_comments',
        filter: _pb.filter('memory_id = {:m}', {'m': memoryId}),
        scope: RecordScope('comments:m=$memoryId',
            equals: {'memory_id': memoryId, 'deleted': false}),
        compare: (a, b) => _strAsc(a.data['created_at'], b.data['created_at']),
        rtChannel: 'pair:$groupId',
        rtMatch: (r) => r.data['memory_id'] == memoryId,
      );

  /// Настроения пользователя в группе.
  Stream<List<RecordModel>> watchMoods(String groupId, String uid) => watchList(
        'mood_entries',
        filter: _pb.filter(
            'group_id = {:g} && user_uid = {:u}', {'g': groupId, 'u': uid}),
        scope: RecordScope('moods:g=$groupId:u=$uid',
            equals: {'group_id': groupId, 'user_uid': uid}),
        compare: (a, b) => _strDesc(a.data['timestamp'], b.data['timestamp']),
        rtChannel: 'pair:$groupId',
        rtMatch: (r) => r.data['user_uid'] == uid,
      );

  /// Чат группы — старые сверху (по ts). [limit] (ленивый режим): начальная
  /// выборка лишь новейших [limit] сообщений (по убыванию ts), а не всей истории;
  /// догрузка старых — повторный вызов с бо́льшим [limit] (UI: chat_screen
  /// `_loadMore`). null → вся история (прежнее поведение). Кэш накапливает
  /// просмотренное; живые новые сообщения приходят дельтой Centrifugo.
  Stream<List<RecordModel>> watchMessages(String groupId, {int? limit}) =>
      watchList(
        'chat_messages',
        filter: _pb.filter('group_id = {:g}', {'g': groupId}),
        scope: RecordScope('chat:g=$groupId', equals: {'group_id': groupId}),
        compare: (a, b) => _numAsc(a.data['ts'], b.data['ts']),
        rtChannel: 'pair:$groupId',
        windowLimit: limit,
        windowSort: '-ts',
      );

  /// Маскоты группы — дефолтные первыми, затем по дате.
  Stream<List<RecordModel>> watchMascots(String groupId) => watchList(
        'mascots',
        filter: _pb.filter('group_id = {:g}', {'g': groupId}),
        scope: RecordScope('mascots:g=$groupId', equals: {'group_id': groupId}),
        compare: (a, b) {
          final ad = a.data['is_default'] == true;
          final bd = b.data['is_default'] == true;
          if (ad != bd) return ad ? -1 : 1;
          return _strAsc(a.data['created_at'], b.data['created_at']);
        },
        rtChannel: 'pair:$groupId',
      );

  /// Штрихи холста — по order_index.
  Stream<List<RecordModel>> watchCanvasStrokes(String groupId, String canvasId) =>
      watchList(
        'canvas_strokes',
        filter: _pb.filter('group_id = {:g} && canvas_id = {:c}',
            {'g': groupId, 'c': canvasId}),
        compare: (a, b) => _numAsc(a.data['order_index'], b.data['order_index']),
        rtChannel: 'pair:$groupId',
        rtMatch: (r) => r.data['canvas_id'] == canvasId,
      );

  /// Виджет-данные группы (оба слота: свой + партнёрский).
  Stream<List<RecordModel>> watchWidgetData(String groupId) => watchList(
        'widget_data',
        filter: _pb.filter('group_id = {:g}', {'g': groupId}),
        scope: RecordScope('widget:g=$groupId', equals: {'group_id': groupId}),
        rtChannel: 'pair:$groupId',
      );

  /// Виджет-данные ОДНОГО участника (свой слот или партнёрский) → запись|null.
  Stream<RecordModel?> watchWidgetOne(String groupId, String uid) => watchList(
        'widget_data',
        filter: _pb.filter(
            'group_id = {:g} && user_uid = {:u}', {'g': groupId, 'u': uid}),
        scope: RecordScope('widget:g=$groupId:u=$uid',
            equals: {'group_id': groupId, 'user_uid': uid}),
        rtChannel: 'pair:$groupId',
        rtMatch: (r) => r.data['user_uid'] == uid,
      ).map((rows) => rows.isEmpty ? null : rows.first);

  /// Каталог холстов группы.
  Stream<List<RecordModel>> watchCanvasCatalogue(String groupId) => watchList(
        'canvas_catalogue',
        filter: _pb.filter('group_id = {:g}', {'g': groupId}),
        rtChannel: 'pair:$groupId',
      );

  /// Мета холста (bg/rotation/clear_version) — одна запись на (group,canvas).
  Stream<List<RecordModel>> watchCanvasMeta(String groupId, String canvasId) =>
      watchList(
        'canvas_meta',
        filter: _pb.filter('group_id = {:g} && canvas_id = {:c}',
            {'g': groupId, 'c': canvasId}),
        rtChannel: 'pair:$groupId',
        rtMatch: (r) => r.data['canvas_id'] == canvasId,
      );

  /// Live-штрихи (in-progress) на холсте — запись на участника, исключение
  /// своего uid делает вызывающий (как listenToLiveDrawingStrokes).
  Stream<List<RecordModel>> watchCanvasLive(String groupId, String canvasId) =>
      watchList(
        'canvas_live',
        filter: _pb.filter('group_id = {:g} && canvas_id = {:c}',
            {'g': groupId, 'c': canvasId}),
        rtChannel: 'pair:$groupId',
        rtMatch: (r) => r.data['canvas_id'] == canvasId,
      );

  /// Статусы прочтения чата {uid: lastReadTs} — live.
  Stream<Map<String, int>> watchChatReads(String groupId) => watchList(
        'chat_reads',
        filter: _pb.filter('group_id = {:g}', {'g': groupId}),
        scope:
            RecordScope('chatreads:g=$groupId', equals: {'group_id': groupId}),
        rtChannel: 'pair:$groupId',
      ).map((rows) => {
            for (final r in rows)
              (r.data['user_uid'] ?? '').toString():
                  (r.data['last_read_ts'] as num?)?.toInt() ?? 0,
          });

  /// Маркеры «печатает…» {uid: typing_at_ms} — live. Свежесть оценивает
  /// вызывающий (ChatService): партнёр печатает, если его метка моложе ~8с.
  Stream<Map<String, int>> watchTyping(String groupId) => watchList(
        'chat_typing',
        filter: _pb.filter('group_id = {:g}', {'g': groupId}),
        rtChannel: 'pair:$groupId',
      ).map((rows) => {
            for (final r in rows)
              (r.data['user_uid'] ?? '').toString():
                  (r.data['typing_at'] as num?)?.toInt() ?? 0,
          });

  /// Счётчики «Я скучаю» {uid: count} — live.
  Stream<Map<String, int>> watchMissYou(String groupId) => watchList(
        'miss_you',
        filter: _pb.filter('group_id = {:g}', {'g': groupId}),
        scope: RecordScope('missyou:g=$groupId', equals: {'group_id': groupId}),
        rtChannel: 'pair:$groupId',
      ).map((rows) => {
            for (final r in rows)
              (r.data['user_uid'] ?? '').toString():
                  (r.data['count'] as num?)?.toInt() ?? 0,
          });
}
