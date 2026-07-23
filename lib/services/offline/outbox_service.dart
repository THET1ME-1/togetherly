import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../pb_data_service.dart';
import '../pb_media_service.dart';
import 'backoff.dart';
import 'connectivity_service.dart';
import 'local_store.dart';

/// Очередь офлайн-записи (outbox).
///
/// Мутации сначала оптимистично попадают в локальный кэш (UI обновляется сразу),
/// затем кладутся СЮДА; при наличии сети очередь сливается на сервер по FIFO.
/// Хранится в том же sembast-файле, что и кэш (стор `outbox`, авто-инкрементный
/// ключ = порядок отправки), поэтому переживает перезапуск и чистится вместе с
/// кэшем при выходе/смене пользователя.
///
/// Идемпотентность: операции построены так, чтобы повтор после «ложного провала»
/// (ответ потерян, но сервер применил) не ломал данные — upsert по id, delete с
/// 404-как-успех, set-saved по желаемому состоянию. Исключение — counterInc
/// (инкремент счётчика-подсказки): возможен косметический дрейф, как и в текущем
/// онлайн-коде.
class OutboxService {
  OutboxService._();
  static final OutboxService instance = OutboxService._();
  factory OutboxService() => instance;

  final StoreRef<int, Map<String, Object?>> _store =
      intMapStoreFactory.store('outbox');
  final StoreRef<int, Map<String, Object?>> _poison =
      intMapStoreFactory.store('outbox_poison');
  // Раньше 8: обречённая запись жила 1,2,4,…,32 c ≈ 2-3 мин до «отравления»,
  // всё это время держала счётчик → плашка «Синхронизация…» не уходила.
  // 5 попыток (1+2+4+8+16 ≈ 31 c) — обречённая операция быстро уезжает в poison
  // (кликабельная плашка «повторить»), а не висит в лимбо. Записи идемпотентны,
  // так что при реальном транзиенте до 5 попыток обычно хватает.
  static const int _maxAttempts = 5;

  bool _flushing = false;
  int _retryAttempt = 0;
  Timer? _retryTimer;

  /// Когда очередь впервые перестала пустеть — чтобы отличить долгую отправку
  /// от залипания и один раз рассказать о нём в Bugsink.
  DateTime? _busySince;
  bool _stuckReported = false;
  StreamSubscription<bool>? _connSub;

  /// Число операций в очереди (для индикатора «ожидает синхронизации»).
  final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);

  /// Число «живых» операций — свежих (attempts == 0), ещё ни разу не падавших.
  /// Плашка-спиннер «Синхронизация…» завязана на ЭТО, а не на pendingCount:
  /// запись, зависшая в backoff после провала, больше НЕ держит спиннер (иначе
  /// одна обречённая операция крутила «вечную синхронизацию» до отравления).
  final ValueNotifier<int> activeCount = ValueNotifier<int>(0);

  /// Число «ядовитых» операций (сервер упорно отвергает) — для UI повтора.
  final ValueNotifier<int> poisonCount = ValueNotifier<int>(0);

  /// Ключи записей (collection:id) с НЕотправленными правками. Кэш-слой
  /// ([PbRealtimeService]) не перезатирает их серверными данными до подтверждения
  /// отправки — иначе оптимистичная правка «откатывается» серверным стейлом
  /// (маскот телепортируется назад, настроение/статус возвращается).
  final Set<String> _pendingKeys = <String>{};

  /// Есть ли в очереди неотправленная правка записи [id] коллекции [collection].
  bool isPending(String collection, String id) =>
      id.isNotEmpty && _pendingKeys.contains('$collection:$id');

  /// Ключи операций, которые прямо сейчас обрабатывает flush (сетевые вызовы
  /// параллельных полос) — коалесинг в них НЕ мёржит (иначе гонка: применилось
  /// бы старое, а новое потерялось при delete).
  final Set<int> _inflightKeys = <int>{};

  /// Максимум одновременных «полос» слива. Полоса = FIFO-цепочка операций одной
  /// записи (rkey); операции без rkey — каждая своя полоса. Полосы независимы по
  /// порядку → сливаем параллельно: очередь после офлайна уходит в ~K раз быстрее
  /// (N×RTT → N/K×RTT), а завистая операция тормозит только свою полосу. K
  /// маленькое, чтобы не штормить сервер (писатель SQLite всё равно один).
  static const int _maxParallelLanes = 4;

  Future<void> init() async {
    _connSub ??= ConnectivityService.instance.onOnlineChanged.listen((online) {
      if (online) unawaited(flush());
    });
    await _updatePending();
    unawaited(flush()); // дослать то, что осталось с прошлой офлайн-сессии
  }

  /// Поставить операцию в очередь. Онлайн → сразу пробуем слить.
  Future<void> enqueue(String type, Map<String, dynamic> payload) async {
    final db = await LocalStore.instance.database();
    if (db == null) return;
    // Коалесинг: склеиваем/заменяем совместимые операции, чтобы не копить дубли
    // (повторные инкременты, многократные правки одного поля и т.п.).
    final merged = await _coalesce(db, type, payload);
    if (!merged) {
      await _store.add(db, {'type': type, 'payload': payload, 'attempts': 0});
    }
    await _updatePending();
    if (ConnectivityService.instance.isOnline) unawaited(flush());
  }

  /// Слить очередь. Защищён от параллельного запуска.
  ///
  /// Очередь раскладывается на «полосы»: операции ОДНОЙ записи (rkey) образуют
  /// FIFO-цепочку (позднюю правку нельзя применить раньше ранней), операции без
  /// rkey ни с чем не конфликтуют — каждая в своей полосе. Полосы независимы →
  /// сливаются ПАРАЛЛЕЛЬНО (кап [_maxParallelLanes]): очередь после офлайна
  /// уходит в ~K раз быстрее, а упавшая/зависшая операция придерживает только
  /// СВОЮ полосу (раньше одна медленная операция — напр. группа через patch-map
  /// под нагрузкой — держала за собой настроение/чат/воспоминания, и плашка
  /// «Синхронизация…» залипала).
  Future<void> flush() async {
    if (_flushing || !ConnectivityService.instance.isOnline) return;
    final db = await LocalStore.instance.database();
    if (db == null) return;
    _flushing = true;
    var anyFailed = false;
    try {
      final all = await _store.find(
        db,
        finder: Finder(sortOrders: [SortOrder(Field.key)]),
      );
      // Раскладка на полосы. Разбор записи ЗАЩИЩЁН: одна повреждённая запись
      // (например, payload иной формы из старой версии приложения) не должна
      // абортить весь flush. Раньше брошенное здесь исключение вылетало во
      // внешний catch → НИ ОДНА операция не обрабатывалась, очередь замораживалась
      // навсегда. Битую запись просто выбрасываем — она невосстановима.
      final lanes = <List<int>>[]; // полоса = ключи операций в FIFO-порядке
      final laneByRkey = <String, List<int>>{};
      for (final snap in all) {
        final parsed = _parseOp(snap.value);
        if (parsed == null) {
          debugPrint('Outbox: повреждённая запись ${snap.key} удалена из очереди');
          await _store.record(snap.key).delete(db);
          continue;
        }
        final rkey = parsed.rkey;
        if (rkey == null) {
          lanes.add([snap.key]);
        } else {
          final lane = laneByRkey[rkey];
          if (lane != null) {
            lane.add(snap.key);
          } else {
            final l = [snap.key];
            laneByRkey[rkey] = l;
            lanes.add(l);
          }
        }
      }
      // Пул воркеров: до _maxParallelLanes полос одновременно. Dart однопоточен —
      // между await нет гонок по общему стейту, «параллелится» только ожидание
      // сети (K сетевых вызовов в полёте).
      var next = 0;
      Future<void> worker() async {
        while (next < lanes.length) {
          final lane = lanes[next++];
          if (await _flushLane(db, lane)) anyFailed = true;
        }
      }
      final n =
          lanes.length < _maxParallelLanes ? lanes.length : _maxParallelLanes;
      await Future.wait([for (var i = 0; i < n; i++) worker()]);
      if (anyFailed) {
        _scheduleRetry();
      } else {
        _retryAttempt = 0;
      }
    } catch (e) {
      debugPrint('Outbox.flush error: $e');
      _scheduleRetry();
    } finally {
      _inflightKeys.clear();
      _flushing = false;
      await _updatePending();
    }
  }

  /// Слить одну полосу (FIFO-цепочку операций одной записи). true → полоса
  /// не дослана (провал/обрыв сети) и нужен retry-проход.
  Future<bool> _flushLane(Database db, List<int> lane) async {
    for (var i = 0; i < lane.length; i++) {
      if (!ConnectivityService.instance.isOnline) {
        return true; // сеть пропала — остальное дошлём при возврате сети
      }
      final key = lane[i];
      // ПЕРЕЧИТЫВАЕМ операцию из БД непосредственно перед отправкой: пока полоса
      // ждала своей очереди, enqueue мог коалесингом смёржить в неё новую правку —
      // применение стейл-снапшота с начала flush тихо теряло бы смерженное
      // (применили старое → удалили запись вместе с новым payload).
      final value = await _store.record(key).get(db);
      if (value == null) continue; // уже удалена (аннигиляция create+delete)
      final parsed = _parseOp(value);
      if (parsed == null) {
        debugPrint('Outbox: повреждённая запись $key удалена из очереди');
        await _store.record(key).delete(db);
        continue;
      }
      _inflightKeys.add(key); // коалесинг не должен мёржить в обрабатываемую
      bool ok;
      try {
        // Жёсткий потолок на операцию: ни один зависший сетевой вызов не должен
        // заморозить полосу (был баг «Синхронизация…(N)» не уходила, пока flush
        // вечно ждал повисший без таймаута запрос). По таймауту/исключению →
        // как провал → ретрай; операции идемпотентны по id.
        ok = await _apply(parsed.type, parsed.payload)
            .timeout(const Duration(seconds: 20), onTimeout: () => false);
      } catch (_) {
        ok = false;
      } finally {
        _inflightKeys.remove(key);
      }
      if (ok) {
        await _store.record(key).delete(db);
        continue;
      }
      // Провал: считаем попытки. Сервис-методы PB глотают ошибку и возвращают
      // false (не отличить транзиент от перманента) → отправляем в «отравленные»
      // по лимиту попыток, чтобы одна битая операция не висела вечно.
      final next = parsed.attempts + 1;
      if (next >= _maxAttempts) {
        await _poison.add(db, {
          ...value,
          'attempts': next,
          'failedAt': DateTime.now().toIso8601String(),
        });
        await _store.record(key).delete(db);
        debugPrint('Outbox: операция «${parsed.type}» отравлена после $next попыток');
        continue; // запись разблокирована — даём ход следующим её правкам
      }
      await _store.record(key).update(db, {'attempts': next});
      // Не применяем позднюю правку раньше ранней: остаток полосы ждёт
      // следующего flush.
      return true;
    }
    return false;
  }

  /// Очередь, которая не пустеет минутами, — это дефект, а не «медленная сеть»:
  /// человек видит вечную плашку «Синхронизация…». Один раз сообщаем, что
  /// именно висит, иначе причину не найти.
  Future<void> _reportIfStuck() async {
    final active = activeCount.value;
    if (active == 0) {
      _busySince = null;
      _stuckReported = false;
      return;
    }
    _busySince ??= DateTime.now();
    if (_stuckReported) return;
    if (DateTime.now().difference(_busySince!) < const Duration(minutes: 2)) {
      return;
    }
    _stuckReported = true;

    final types = <String, int>{};
    try {
      final db = await LocalStore.instance.database();
      if (db == null) return;
      for (final snap in await _store.find(db)) {
        final t = (snap.value['type'] ?? '?').toString();
        types[t] = (types[t] ?? 0) + 1;
      }
    } catch (_) {}

    unawaited(Sentry.captureMessage(
      'outbox stuck: $active операций не уходят',
      withScope: (scope) {
        scope.level = SentryLevel.warning;
        scope.setExtra('active', active.toString());
        scope.setExtra('poison', poisonCount.value.toString());
        scope.setExtra('types', types.toString());
      },
    ));
  }

  /// Запись (collection:id), которую затрагивает операция — для сохранения
  /// порядка правок одной записи при не-блокирующем сливе. null → операция ни с
  /// чем не конфликтует по порядку (можно слать независимо).
  String? _recordKeyOf(String type, Map<String, dynamic> p) {
    String? k(String col, Object? id) {
      final s = id?.toString() ?? '';
      return s.isEmpty ? null : '$col:$s';
    }
    switch (type) {
      case 'memoryUpsert':
      case 'memoryDelete':
        return k('memories', p['id']);
      case 'memorySetSaved':
      case 'memoryBumpComments':
        return k('memories', p['memoryId']);
      case 'commentUpsert':
      case 'commentDelete':
        return k('memory_comments', p['id']);
      case 'moodUpsert':
        return k('mood_entries', (p['entry'] as Map?)?['id']);
      case 'moodDelete':
        return k('mood_entries', p['id']);
      case 'chatUpsert':
      case 'chatUpdate':
      case 'chatSetReaction':
        return k('chat_messages', p['id']);
      case 'mascotUpsert':
        return k('mascots', (p['mascot'] as Map?)?['id']);
      case 'mascotDelete':
      case 'mascotUpdateFields':
        return k('mascots', p['mascotId']);
      // все правки полей самой группы делят один ключ — их порядок важен.
      case 'counterInc':
      case 'groupUpdateFields':
      case 'groupSetMemberMood':
      case 'groupSetMemberAilment':
      case 'groupSetStatus':
        return k('groups', p['groupId']);
      default:
        return null;
    }
  }

  /// Безопасный разбор записи очереди. Возвращает null, если запись повреждена
  /// (payload не Map / неожиданная форма у moodUpsert/mascotUpsert и т.п.) —
  /// тогда вызывающий её выбрасывает, а не роняет весь проход очереди.
  _ParsedOp? _parseOp(Map<String, Object?> value) {
    try {
      final type = value['type'] as String? ?? '';
      final payload =
          Map<String, dynamic>.from((value['payload'] as Map?) ?? const {});
      final attempts = (value['attempts'] as num?)?.toInt() ?? 0;
      return _ParsedOp(type, payload, attempts, _recordKeyOf(type, payload));
    } catch (_) {
      return null;
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final ms = backoffMs(_retryAttempt);
    _retryAttempt++;
    _retryTimer = Timer(Duration(milliseconds: ms), () {
      if (ConnectivityService.instance.isOnline) unawaited(flush());
    });
  }

  Future<void> _updatePending() async {
    final db = await LocalStore.instance.database();
    if (db == null) {
      pendingCount.value = 0;
      activeCount.value = 0;
      poisonCount.value = 0;
      _pendingKeys.clear();
      return;
    }
    final snaps = await _store.find(db);
    pendingCount.value = snaps.length;
    // «Живые» = ещё не падавшие: спиннер должен реагировать на реальный синк, а
    // не на записи, застрявшие в backoff (attempts > 0).
    var active = 0;
    for (final s in snaps) {
      if (((s.value['attempts'] as num?)?.toInt() ?? 0) == 0) active++;
    }
    activeCount.value = active;
    unawaited(_reportIfStuck());
    poisonCount.value = await _poison.count(db);
    // Пересчитываем «грязные» ключи: записи с неотправленными правками, которые
    // кэш-слой не должен перезатирать серверным стейлом. Разбор защищён
    // (_parseOp) — битая запись не должна ронять пересчёт счётчика.
    final keys = <String>{};
    for (final s in snaps) {
      final k = _parseOp(s.value)?.rkey;
      if (k != null) keys.add(k);
    }
    _pendingKeys
      ..clear()
      ..addAll(keys);
  }

  /// Полная очистка очереди (logout/смена пользователя).
  Future<void> clear() async {
    final db = await LocalStore.instance.database();
    if (db != null) {
      await _store.delete(db);
      await _poison.delete(db);
    }
    pendingCount.value = 0;
    activeCount.value = 0;
    poisonCount.value = 0;
  }

  /// Повторить «ядовитые» операции (тап в индикаторе): вернуть в очередь со
  /// сбросом попыток и слить.
  Future<void> retryPoison() async {
    final db = await LocalStore.instance.database();
    if (db == null) return;
    final items = await _poison.find(db);
    for (final s in items) {
      await _store.add(db, {
        'type': s.value['type'],
        'payload': s.value['payload'],
        'attempts': 0,
      });
      await _poison.record(s.key).delete(db);
    }
    await _updatePending();
    unawaited(flush());
  }

  // ── коалесинг очереди ───────────────────────────────────────────────────────
  /// Склеить новую операцию с уже стоящей (если совместимы). true — смержили в
  /// существующую (новую добавлять не нужно). Операции, обрабатываемые flush
  /// (`_inflightKeys`), не трогаем.
  Future<bool> _coalesce(
      Database db, String type, Map<String, dynamic> p) async {
    switch (type) {
      case 'counterInc':
        return _replaceOrMerge(
          db,
          type,
          p,
          (a, b) => a['groupId'] == b['groupId'] && a['field'] == b['field'],
          merge: (o, n) => {
            ...o,
            'by': ((o['by'] as num?)?.toInt() ?? 0) +
                ((n['by'] as num?)?.toInt() ?? 0),
          },
        );
      case 'groupUpdateFields':
        return _replaceOrMerge(
          db,
          type,
          p,
          (a, b) => a['groupId'] == b['groupId'],
          merge: (o, n) => {
            ...o,
            'cols': {
              ...?(o['cols'] as Map?)?.cast<String, dynamic>(),
              ...?(n['cols'] as Map?)?.cast<String, dynamic>(),
            },
          },
        );
      case 'chatUpdate':
        return _replaceOrMerge(
          db,
          type,
          p,
          (a, b) => a['id'] == b['id'],
          merge: (o, n) => {
            ...o,
            'fields': {
              ...?(o['fields'] as Map?)?.cast<String, dynamic>(),
              ...?(n['fields'] as Map?)?.cast<String, dynamic>(),
            },
          },
        );
      case 'groupSetMemberMood':
      case 'groupSetMemberAilment':
        return _replaceOrMerge(db, type, p,
            (a, b) => a['groupId'] == b['groupId'] && a['uid'] == b['uid']);
      case 'groupSetStatus':
        return _replaceOrMerge(
            db, type, p, (a, b) => a['groupId'] == b['groupId']);
      case 'chatSetReaction':
        return _replaceOrMerge(db, type, p,
            (a, b) => a['id'] == b['id'] && a['uid'] == b['uid']);
      case 'memorySetSaved':
        return _replaceOrMerge(db, type, p,
            (a, b) => a['memoryId'] == b['memoryId'] && a['uid'] == b['uid']);
      case 'memoryUpsert':
        return _replaceOrMerge(db, type, p, (a, b) => a['id'] == b['id']);
      case 'memoryDelete':
        // create+delete аннигиляция: убрать ещё не отправленный memoryUpsert того
        // же id (создавать-затем-удалять на сервере не нужно). Сам delete ставим
        // (404 = успех, если записи на сервере уже/ещё нет).
        final pend = await _store.find(db);
        for (final s in pend) {
          if (_inflightKeys.contains(s.key)) continue;
          if (s.value['type'] == 'memoryUpsert') {
            final pp = _parseOp(s.value)?.payload;
            if (pp != null && pp['id'] == p['id']) {
              await _store.record(s.key).delete(db);
            }
          }
        }
        return false;
      default:
        return false;
    }
  }

  Future<bool> _replaceOrMerge(
    Database db,
    String type,
    Map<String, dynamic> payload,
    bool Function(Map<String, dynamic> existing, Map<String, dynamic> incoming)
        sameKey, {
    Map<String, dynamic> Function(
            Map<String, dynamic> old, Map<String, dynamic> incoming)?
        merge,
  }) async {
    final pend = await _store.find(db,
        finder: Finder(sortOrders: [SortOrder(Field.key)]));
    for (final s in pend) {
      if (_inflightKeys.contains(s.key) || s.value['type'] != type) continue;
      final parsed = _parseOp(s.value);
      if (parsed == null) continue; // битую запись пропускаем (flush её удалит)
      final existing = parsed.payload;
      if (sameKey(existing, payload)) {
        final next = merge != null ? merge(existing, payload) : payload;
        await _store.record(s.key).update(db, {'payload': next});
        return true;
      }
    }
    return false;
  }

  // ── исполнение операций ────────────────────────────────────────────────────
  Future<bool> _apply(String type, Map<String, dynamic> p) async {
    final data = PbDataService();
    switch (type) {
      case 'memoryUpsert':
        return data.upsertMemory(
          p['groupId'] as String? ?? '',
          p['id'] as String? ?? '',
          Map<String, dynamic>.from(p['data'] as Map? ?? const {}),
        );
      case 'memoryDelete':
        final media = PbMediaService();
        for (final ref in (p['mediaRefs'] as List? ?? const [])) {
          if (ref is String && media.isPbRef(ref)) {
            try {
              await media.delete(ref);
            } catch (_) {}
          }
        }
        return data.deleteMemory(p['id'] as String? ?? '', hard: true);
      case 'memorySetSaved':
        return _applySetSaved(
          p['memoryId'] as String? ?? '',
          p['uid'] as String? ?? '',
          p['saved'] == true,
        );
      case 'counterInc':
        return data.incrementGroupCounter(
          p['groupId'] as String? ?? '',
          p['field'] as String? ?? '',
          (p['by'] as num?)?.toInt() ?? 0,
        );
      // ── настроения ──
      case 'moodUpsert':
        return data.upsertMood(
          p['groupId'] as String? ?? '',
          p['uid'] as String? ?? '',
          Map<String, dynamic>.from(p['entry'] as Map? ?? const {}),
        );
      case 'moodDelete':
        return data.deleteMood(p['id'] as String? ?? '');
      // ── комментарии ──
      case 'commentUpsert':
        return data.upsertComment(
          p['groupId'] as String? ?? '',
          p['memoryId'] as String? ?? '',
          p['id'] as String? ?? '',
          Map<String, dynamic>.from(p['data'] as Map? ?? const {}),
        );
      case 'commentDelete':
        return data.deleteComment(p['id'] as String? ?? '');
      case 'memoryBumpComments':
        return _applyBumpComments(
          p['groupId'] as String? ?? '',
          p['memoryId'] as String? ?? '',
          (p['by'] as num?)?.toInt() ?? 0,
        );
      // ── чат ──
      case 'chatUpsert':
        return data.chatSend(
          p['groupId'] as String? ?? '',
          p['id'] as String? ?? '',
          Map<String, dynamic>.from(p['msg'] as Map? ?? const {}),
        );
      case 'chatUpdate':
        return data.chatUpdate(
          p['id'] as String? ?? '',
          Map<String, dynamic>.from(p['fields'] as Map? ?? const {}),
        );
      case 'chatSetReaction':
        return data.setChatReaction(
          p['id'] as String? ?? '',
          p['uid'] as String? ?? '',
          p['emoji'] as String?, // null/'' → снять (setChatReaction идемпотентен)
        );
      // ── маскоты ──
      case 'mascotUpsert':
        return data.upsertMascot(p['groupId'] as String? ?? '',
            Map<String, dynamic>.from(p['mascot'] as Map? ?? const {}));
      case 'mascotDelete':
        return data.deleteMascot(
            p['groupId'] as String? ?? '', p['mascotId'] as String? ?? '');
      case 'mascotUpdateFields':
        return data.updateMascotFields(
            p['groupId'] as String? ?? '',
            p['mascotId'] as String? ?? '',
            Map<String, dynamic>.from(p['cols'] as Map? ?? const {}));
      // ── поля группы (настроение/самочувствие/статус/маскот) ──
      case 'groupSetMemberMood':
        final gid = p['groupId'] as String? ?? '';
        final uid = p['uid'] as String? ?? '';
        final mood = p['mood'];
        return mood == null
            ? data.clearMemberMood(gid, uid)
            : data.setMemberMood(gid, uid, mood);
      case 'groupSetMemberAilment':
        final gid = p['groupId'] as String? ?? '';
        final uid = p['uid'] as String? ?? '';
        final ail = p['ailment'];
        return ail == null
            ? data.clearMemberAilment(gid, uid)
            : data.setMemberAilment(
                gid, uid, Map<String, dynamic>.from(ail as Map));
      case 'groupSetStatus':
        final gid = p['groupId'] as String? ?? '';
        final st = p['status'];
        return st == null
            ? data.clearGroupStatus(gid)
            : data.setGroupStatus(gid, Map<String, dynamic>.from(st as Map));
      case 'groupUpdateFields':
        return data.updateGroupFields(p['groupId'] as String? ?? '',
            Map<String, dynamic>.from(p['cols'] as Map? ?? const {}));
      default:
        debugPrint('Outbox: неизвестный тип «$type» — пропускаю');
        return true; // не зацикливаем неизвестное
    }
  }

  /// RMW счётчика комментариев в json `data` воспоминания (бейдж в ленте).
  /// Не идемпотентен (как и counterInc) — возможен косметический дрейф бейджа.
  Future<bool> _applyBumpComments(
      String groupId, String memoryId, int by) async {
    if (memoryId.isEmpty || by == 0) return true;
    final data = PbDataService();
    final rec = await data.loadMemoryById(memoryId);
    if (rec == null) return true;
    final raw = rec.data['data'];
    final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    map['commentsCount'] = ((map['commentsCount'] as num?)?.toInt() ?? 0) + by;
    return data.upsertMemory(
        rec.data['group_id'] as String? ?? groupId, memoryId, map);
  }

  /// Идемпотентный RMW «избранное»: читаем АКТУАЛЬНОЕ серверное состояние и
  /// приводим присутствие своего uid к желаемому [saved] (а не пишем стейл-список
  /// из кэша) — не затираем правку партнёра, и повтор операции безопасен.
  Future<bool> _applySetSaved(String memoryId, String uid, bool saved) async {
    if (memoryId.isEmpty || uid.isEmpty) return true;
    final data = PbDataService();
    final rec = await data.loadMemoryById(memoryId);
    if (rec == null) return true; // удалено на сервере — считаем выполненным
    final raw = rec.data['data'];
    final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final list = (map['savedBy'] is List)
        ? List<String>.from((map['savedBy'] as List).map((e) => e.toString()))
        : <String>[];
    final has = list.contains(uid);
    if (saved && !has) {
      list.add(uid);
    } else if (!saved && has) {
      list.remove(uid);
    } else {
      return true; // уже в нужном состоянии — идемпотентно
    }
    map['savedBy'] = list;
    return data.upsertMemory(
        rec.data['group_id'] as String? ?? '', memoryId, map);
  }
}

/// Разобранная запись очереди (см. [OutboxService._parseOp]).
class _ParsedOp {
  final String type;
  final Map<String, dynamic> payload;
  final int attempts;
  final String? rkey;
  const _ParsedOp(this.type, this.payload, this.attempts, this.rkey);
}
