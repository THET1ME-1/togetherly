import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import 'pocketbase_service.dart';

/// Результат вызова серверного атомарного group-роута: [ok] — выполнен;
/// [missing] — роута нет (404) → легитимный локальный RMW-фолбэк; [backpressure]
/// — сервер под нагрузкой (429/5xx/timeout/сеть) → НЕ откатываться на локальный
/// RMW (это ломало backpressure сервера и раскручивало retry-шторм).
enum _GroupRouteResult { ok, missing, backpressure }

/// Слой данных PocketBase (миграция Firebase→PB, Этап 6, слой Данные).
///
/// Заменяет Firestore-CRUD. Плоские коллекции, поля snake_case (схема Этапа 3).
/// Никакого Firebase: даты — ISO-строки/`DateTime`, не `Timestamp`. Входные карты
/// от приложения — camelCase (как в существующем коде), здесь маппятся в колонки.
///
/// Realtime-подписки (`watch*`) — отдельный слой (PB SSE), медиа — отдельный.
class PbDataService {
  PbDataService._();
  static final PbDataService instance = PbDataService._();
  factory PbDataService() => instance;

  PocketBase get _pb => PocketBaseService().pb;

  // ── helpers ────────────────────────────────────────────────────────────
  /// firestore-данные → JSON-safe для json-полей PB: DateTime→ISO, рекурсивно.
  static dynamic _jsonSafe(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toIso8601String();
    if (v is Map) {
      return v.map((k, val) => MapEntry(k.toString(), _jsonSafe(val)));
    }
    if (v is List) return v.map(_jsonSafe).toList();
    return v;
  }

  /// DateTime/String → ISO-строка для date-колонок, или null.
  static String? _iso(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toIso8601String();
    if (v is String) return v.isEmpty ? null : v;
    return null;
  }

  /// ISO-строка PB → DateTime, или null.
  static DateTime? _date(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String) {
      final s = v.trim();
      return s.isEmpty ? null : DateTime.tryParse(s);
    }
    // Firestore Timestamp из мигрированных данных: {_seconds,_nanoseconds}
    // (member_birthdays писались миграцией как есть, без конвертации в ISO).
    if (v is Map) {
      final sec = v['_seconds'] ?? v['seconds'];
      if (sec is num) {
        final ns = v['_nanoseconds'] ?? v['nanoseconds'] ?? 0;
        final ms = sec.toInt() * 1000 +
            ((ns is num ? ns.toInt() : 0) ~/ 1000000);
        return DateTime.fromMillisecondsSinceEpoch(ms);
      }
      return null;
    }
    // Эпоха числом: секунды или миллисекунды.
    if (v is num) {
      final n = v.toInt();
      return n > 100000000000
          ? DateTime.fromMillisecondsSinceEpoch(n)
          : DateTime.fromMillisecondsSinceEpoch(n * 1000);
    }
    return null;
  }

  /// Upsert по известному id: update → при 404 create с этим id.
  Future<bool> _upsertById(
    String col,
    String id,
    Map<String, dynamic> body, {
    String op = 'upsert',
  }) async {
    body.remove('id');
    try {
      // Таймаут: под нагрузкой запись на PB может висеть очень долго (один
      // SQLite-writer). Без него flush очереди залипал на одной операции →
      // плашка «Синхронизация…» не уходила. По таймауту → false → ограниченный
      // ретрай; повтор безопасен (идемпотентно по id: update→404→create).
      await _pb
          .collection(col)
          .update(id, body: body)
          .timeout(const Duration(seconds: 15));
      return true;
    } on ClientException catch (e) {
      if (e.statusCode == 404) {
        try {
          await _pb
              .collection(col)
              .create(body: {'id': id, ...body}).timeout(
                  const Duration(seconds: 15));
          return true;
        } catch (e2) {
          debugPrint('PbData.$op create($col/$id) failed: $e2');
          return false;
        }
      }
      debugPrint('PbData.$op update($col/$id) failed: $e');
      return false;
    } catch (e) {
      debugPrint('PbData.$op($col/$id) failed: $e');
      return false;
    }
  }

  /// Upsert по составному уникальному ключу (auto-id коллекции): найти по
  /// фильтру → update, иначе create.
  Future<bool> _upsertByFilter(
    String col,
    String filter,
    Map<String, dynamic> params,
    Map<String, dynamic> body, {
    String op = 'upsert',
  }) async {
    try {
      final f = _pb.filter(filter, params);
      try {
        final existing = await _pb.collection(col).getFirstListItem(f);
        await _pb.collection(col).update(existing.id, body: body);
      } on ClientException catch (e) {
        if (e.statusCode == 404) {
          try {
            await _pb.collection(col).create(body: body);
          } on ClientException catch (_) {
            // DATA-3: TOCTOU — между getFirstListItem(404) и create параллельный
            // вызов уже создал запись по тому же уникальному ключу (create падает
            // на unique-индексе). Перечитываем и обновляем существующую вместо
            // потери записи.
            final existing = await _pb.collection(col).getFirstListItem(f);
            await _pb.collection(col).update(existing.id, body: body);
          }
        } else {
          rethrow;
        }
      }
      return true;
    } catch (e) {
      debugPrint('PbData.$op($col) failed: $e');
      return false;
    }
  }

  /// POST на серверный АТОМАРНЫЙ group-роут (pb_hooks/groups.pb.js). true =
  /// сервер выполнил операцию в транзакции (ok:true). false на любой
  /// ошибке/недоступности роута → вызывающий откатывается на локальный RMW, так
  /// что версия-скью клиент/сервер безопасна. Закрывает гонки DATA-5/6/7/8/9.
  Future<_GroupRouteResult> _callGroupRoute(
      String path, Map<String, dynamic> body) async {
    try {
      final res = await _pb
          .send('/api/group/$path', method: 'POST', body: body)
          .timeout(const Duration(seconds: 12));
      if (res is Map && res['ok'] == true) return _GroupRouteResult.ok;
      // 200, но без ok:true — роут не подтвердил операцию → локальный фолбэк.
      return _GroupRouteResult.missing;
    } on ClientException catch (e) {
      // 404 — атомарного роута нет на этом сервере → легитимный локальный RMW.
      if (e.statusCode == 404) return _GroupRouteResult.missing;
      // 429/5xx/сеть(0) — сервер под нагрузкой. НЕ долбить локальным RMW: это
      // ровно то, что ломало backpressure сервера и раскручивало шторм.
      if (e.statusCode == 429 || e.statusCode == 0 || e.statusCode >= 500) {
        debugPrint('PbData._callGroupRoute($path) backpressure ${e.statusCode}');
        return _GroupRouteResult.backpressure;
      }
      // Прочие 4xx (400/403/422) — роут ответил отказом; локальный RMW не
      // поможет, но поведение сохраняем как раньше (фолбэк).
      debugPrint('PbData._callGroupRoute($path) ${e.statusCode}: ${e.response}');
      return _GroupRouteResult.missing;
    } on TimeoutException {
      debugPrint('PbData._callGroupRoute($path) timeout → backpressure');
      return _GroupRouteResult.backpressure;
    } catch (e) {
      // Сеть/неизвестное — транзиент, не амплифицируем повторами.
      debugPrint('PbData._callGroupRoute($path) transient: $e');
      return _GroupRouteResult.backpressure;
    }
  }

  // ══════════════════════════════════════════════ GROUP
  /// Зеркало группы из «сырого» firestore-документа (camelCase). Upsert по id.
  Future<bool> upsertGroupRaw(String groupId, Map<String, dynamic> raw) async {
    if (groupId.isEmpty) return false;
    final body = <String, dynamic>{
      'members': _jsonSafe(raw['members'] ?? []),
      'member_names': _jsonSafe(raw['memberNames'] ?? {}),
      'member_avatars': _jsonSafe(raw['memberAvatars'] ?? {}),
      'member_ailments': _jsonSafe(raw['memberAilments'] ?? {}),
      'max_members': raw['maxMembers'] ?? 2,
      'relationship_type': raw['relationshipType'] ?? 'couple',
      'custom_relationship_label': raw['customRelationshipLabel'],
      'custom_relationship_emoji': raw['customRelationshipEmoji'],
      'custom_relationship_types':
          _jsonSafe(raw['customRelationshipTypes'] ?? []),
      'start_date': _iso(raw['startDate']),
      'anniversary_date': _iso(raw['anniversaryDate']),
      'first_kiss_date': _iso(raw['firstKissDate']),
      'member_birthdays': _jsonSafe(raw['memberBirthdays'] ?? {}),
      'member_moods': _jsonSafe(raw['memberMoods'] ?? {}),
      'current_status': _jsonSafe(raw['currentStatus']),
      'custom_statuses': _jsonSafe(raw['customStatuses'] ?? []),
      'memories_count': raw['memoriesCount'] ?? 0,
      'drawings_count': raw['drawingsCount'] ?? 0,
      'active_session': _jsonSafe(raw['activeSession']),
      'disbanded': raw['disbanded'] ?? false,
      'disbanded_at': _iso(raw['disbandedAt']),
      'timers': _jsonSafe(raw['timers'] ?? []),
      'mascots': _jsonSafe(raw['mascots'] ?? []),
    }..removeWhere((k, v) => v == null);
    return _upsertById('groups', groupId, body, op: 'upsertGroupRaw');
  }

  /// Точечное обновление колонок группы (snake_case→значение). update-only
  /// (нет вставки): годится и для очистки полей в null.
  Future<bool> updateGroupFields(
    String groupId,
    Map<String, dynamic> columns,
  ) async {
    if (groupId.isEmpty || columns.isEmpty) return false;
    try {
      final rec = await _pb
          .collection('groups')
          .getFirstListItem(_pb.filter('id = {:id}', {'id': groupId}));
      await _pb.collection('groups').update(rec.id, body: columns);
      return true;
    } catch (e) {
      debugPrint('PbData.updateGroupFields($groupId) failed: $e');
      return false;
    }
  }

  Future<bool> setMemberMood(String groupId, String uid, dynamic mood) =>
      _patchGroupMapField(groupId, 'member_moods', uid, _jsonSafe(mood));
  Future<bool> clearMemberMood(String groupId, String uid) =>
      _patchGroupMapField(groupId, 'member_moods', uid, null);
  Future<bool> setMemberName(String groupId, String uid, String name) =>
      _patchGroupMapField(groupId, 'member_names', uid, name);
  Future<bool> setMemberAvatar(String groupId, String uid, String url) =>
      _patchGroupMapField(groupId, 'member_avatars', uid, url);

  /// RMW по json-полю-словарю группы (member_moods/names/avatars): прочитать,
  /// поменять ключ uid, записать целиком. null-значение удаляет ключ.
  /// Retry (до 3 попыток) спасает от ТРАНЗИЕНТНЫХ ошибок (сеть/5xx), но НЕ от
  /// lost-update: при настоящей гонке параллельная запись проходит УСПЕШНО (без
  /// исключения) и перетирает наше изменение, а ретрай срабатывает лишь на throw.
  /// Полностью race-free только серверная транзакция (DATA-5, см. groups.pb.js —
  /// TODO). Для редких правок member_* в паре из 2 человек риск низкий.
  Future<bool> _patchGroupMapField(
    String groupId,
    String col,
    String uid,
    dynamic value,
  ) async {
    // DATA-5: сперва атомарный серверный роут; при недоступности — локальный RMW.
    final r = await _callGroupRoute('patch-map',
        {'groupId': groupId, 'field': col, 'uid': uid, 'value': value});
    if (r == _GroupRouteResult.ok) return true;
    // Под нагрузкой (429/timeout) НЕ откатываемся на локальный RMW — это усиливало шторм.
    if (r == _GroupRouteResult.backpressure) return false;
    return _patchGroupMapFieldLocal(groupId, col, uid, value);
  }

  Future<bool> _patchGroupMapFieldLocal(
    String groupId,
    String col,
    String uid,
    dynamic value,
  ) async {
    const maxAttempts = 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final rec = await _pb
            .collection('groups')
            .getFirstListItem(_pb.filter('id = {:id}', {'id': groupId}));
        final cur = rec.data[col];
        final map = cur is Map ? Map<String, dynamic>.from(cur) : <String, dynamic>{};
        if (value == null) {
          map.remove(uid);
        } else {
          map[uid] = value;
        }
        await _pb.collection('groups').update(rec.id, body: {col: map});
        return true;
      } catch (e) {
        if (attempt == maxAttempts - 1) {
          debugPrint('PbData._patchGroupMapField($col,$uid) failed after ${attempt + 1} attempts: $e');
          return false;
        }
        // Небольшая задержка перед повтором (ponential backoff).
        await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
      }
    }
    return false;
  }

  /// Группа по id (raw данные записи, даты — DateTime). null если нет/распущена.
  Future<RecordModel?> loadGroupById(String groupId) async {
    if (groupId.isEmpty) return null;
    try {
      final rec = await _pb
          .collection('groups')
          .getFirstListItem(_pb.filter('id = {:id}', {'id': groupId}));
      if (rec.data['disbanded'] == true) return null;
      return rec;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return null;
      debugPrint('PbData.loadGroupById($groupId) failed: $e');
      return null;
    }
  }

  /// Группа, где currentUid в members и не распущена.
  Future<RecordModel?> loadPairForUser(String uid) async {
    if (uid.isEmpty) return null;
    try {
      final res = await _pb.collection('groups').getList(
            perPage: 1,
            filter: _pb.filter('members ~ {:u} && disbanded = false', {'u': uid}),
          );
      return res.items.isEmpty ? null : res.items.first;
    } catch (e) {
      debugPrint('PbData.loadPairForUser($uid) failed: $e');
      return null;
    }
  }

  /// НЕатомарный read-modify-write. Retry (до 3 попыток) закрывает только
  /// транзиентные ошибки; lost-update при одновременном инкременте с двух
  /// устройств ретрай НЕ ловит (конкурентная запись успешна, без исключения) →
  /// часть инкрементов теряется. Для точности нужен серверный atomic inc
  /// (DATA-7, PB-hook/транзакция — TODO).
  Future<bool> incrementGroupCounter(String groupId, String col, int by) async {
    // DATA-7: атомарный серверный инкремент; при недоступности — локальный RMW.
    final r = await _callGroupRoute(
        'increment', {'groupId': groupId, 'field': col, 'by': by});
    if (r == _GroupRouteResult.ok) return true;
    if (r == _GroupRouteResult.backpressure) return false;
    return _incrementGroupCounterLocal(groupId, col, by);
  }

  Future<bool> _incrementGroupCounterLocal(
      String groupId, String col, int by) async {
    const maxAttempts = 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final rec = await _pb
            .collection('groups')
            .getFirstListItem(_pb.filter('id = {:id}', {'id': groupId}));
        final cur = (rec.data[col] as num?)?.toInt() ?? 0;
        await _pb.collection('groups').update(rec.id, body: {col: cur + by});
        return true;
      } catch (e) {
        if (attempt == maxAttempts - 1) {
          debugPrint('PbData.incrementGroupCounter($col) failed after ${attempt + 1} attempts: $e');
          return false;
        }
        await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
      }
    }
    return false;
  }

  // ── pairing-слой (миграция ConnectionsManager/Connection на PB) ──────────
  //
  // PB-модель пары: членство = массив `groups.members` (uid-строки), имена и
  // аватары — отдельные map-поля. «Указателя» pairIds в users НЕТ — активная
  // группа находится запросом `members ~ uid && disbanded = false`.

  /// PB-запись группы → карта в форме старого Firestore-парсера
  /// (`Connection._applyPairData`/`_listenToPair`): camelCase-ключи, members —
  /// список объектов {uid,name,avatar}, даты — `DateTime`. [myUid] нужен для
  /// вычисления partnerName/partnerAvatar (первый участник, кроме себя).
  static Map<String, dynamic> groupRecordToPairMap(
    RecordModel rec,
    String myUid,
  ) {
    final data = rec.data;
    final rawMembers =
        (data['members'] as List?)?.map((e) => e.toString()).toList() ??
            <String>[];
    final members = rawMembers.toSet().toList(); // дедуп на всякий
    final names = data['member_names'] is Map
        ? Map<String, dynamic>.from(data['member_names'] as Map)
        : <String, dynamic>{};
    final avatars = data['member_avatars'] is Map
        ? Map<String, dynamic>.from(data['member_avatars'] as Map)
        : <String, dynamic>{};
    final others = members.where((m) => m != myUid).toList();
    final partnerUid = others.isNotEmpty ? others.first : '';

    // memberMoods/memberAilments: {uid:{..., updatedAt}} — updatedAt → DateTime.
    Map<String, dynamic> innerWithDate(dynamic raw) {
      if (raw is! Map) return <String, dynamic>{};
      return Map<String, dynamic>.from(raw).map((uid, v) {
        final inner = v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
        if (inner.containsKey('updatedAt')) {
          inner['updatedAt'] = _date(inner['updatedAt']);
        }
        return MapEntry(uid, inner);
      });
    }

    Map<String, DateTime?>? birthdays() {
      final raw = data['member_birthdays'];
      if (raw is! Map) return null;
      return Map<String, dynamic>.from(raw).map((k, v) => MapEntry(k, _date(v)));
    }

    return {
      'pairId': rec.id,
      'partnerName': names[partnerUid] ?? '',
      'partnerAvatar': avatars[partnerUid] ?? '',
      'startDate': _date(data['start_date']),
      'members': members
          .map((uid) => {
                'uid': uid,
                'name': names[uid] ?? '',
                'avatar': avatars[uid] ?? '',
              })
          .toList(),
      'maxMembers': data['max_members'] ?? 2,
      'memberMoods': innerWithDate(data['member_moods']),
      'memberAilments': innerWithDate(data['member_ailments']),
      'currentStatus': data['current_status'] is Map
          ? Map<String, dynamic>.from(data['current_status'] as Map)
          : null,
      'customStatuses':
          data['custom_statuses'] is List ? data['custom_statuses'] as List : null,
      'relationshipType': data['relationship_type'] as String?,
      'customRelationshipLabel': data['custom_relationship_label'] as String?,
      'customRelationshipEmoji': data['custom_relationship_emoji'] as String?,
      'customRelationshipTypes': data['custom_relationship_types'] is List
          ? data['custom_relationship_types'] as List
          : null,
      'anniversaryDate': _date(data['anniversary_date']),
      'firstKissDate': _date(data['first_kiss_date']),
      'memberBirthdays': birthdays(),
    };
  }

  /// Группа по id → pair-карта (или null, если нет/распущена).
  Future<Map<String, dynamic>?> loadPairMapById(
    String groupId,
    String myUid,
  ) async {
    final rec = await loadGroupById(groupId);
    return rec == null ? null : groupRecordToPairMap(rec, myUid);
  }

  /// Активная группа пользователя → pair-карта (или null).
  Future<Map<String, dynamic>?> loadPairMapForUser(String myUid) async {
    final rec = await loadPairForUser(myUid);
    return rec == null ? null : groupRecordToPairMap(rec, myUid);
  }

  /// Id всех живых групп, где [uid] состоит (discovery/self-heal).
  Future<List<String>> activeGroupIdsForUser(String uid) async {
    if (uid.isEmpty) return const [];
    try {
      final res = await _pb.collection('groups').getFullList(
            filter:
                _pb.filter('members ~ {:u} && disbanded = false', {'u': uid}),
          );
      return res.map((r) => r.id).toList();
    } catch (e) {
      debugPrint('PbData.activeGroupIdsForUser($uid) failed: $e');
      return const [];
    }
  }

  // ── внутригрупповые записи ───────────────────────────────────────────────
  Future<bool> setMemberAilment(
    String groupId,
    String uid,
    Map<String, dynamic> ail,
  ) =>
      _patchGroupMapField(groupId, 'member_ailments', uid, _jsonSafe(ail));
  Future<bool> clearMemberAilment(String groupId, String uid) =>
      _patchGroupMapField(groupId, 'member_ailments', uid, null);

  Future<bool> setGroupRelationshipType(
    String groupId, {
    required String type,
    int maxMembers = 2,
    String customLabel = '',
    String customEmoji = '',
  }) =>
      updateGroupFields(groupId, {
        'relationship_type': type,
        'max_members': maxMembers,
        'custom_relationship_label': customLabel,
        'custom_relationship_emoji': customEmoji,
      });

  Future<bool> setGroupStatus(String groupId, Map<String, dynamic> status) =>
      updateGroupFields(groupId, {'current_status': _jsonSafe(status)});
  Future<bool> clearGroupStatus(String groupId) =>
      updateGroupFields(groupId, {'current_status': null});

  Future<bool> addOrUpdateCustomStatus(
    String groupId,
    Map<String, dynamic> status,
  ) =>
      _patchGroupListById(groupId, 'custom_statuses', upsert: status);
  Future<bool> deleteCustomStatus(String groupId, String statusId) =>
      _patchGroupListById(groupId, 'custom_statuses', deleteId: statusId);

  Future<bool> addOrUpdateCustomRelationshipType(
    String groupId,
    Map<String, dynamic> entry,
  ) =>
      _patchGroupListById(groupId, 'custom_relationship_types', upsert: entry);
  Future<bool> deleteCustomRelationshipType(String groupId, String id) =>
      _patchGroupListById(groupId, 'custom_relationship_types', deleteId: id);

  /// RMW по json-полю-СПИСКУ группы: upsert/удаление элемента по ключу [idKey].
  Future<bool> _patchGroupListById(
    String groupId,
    String col, {
    Map<String, dynamic>? upsert,
    String? deleteId,
    String idKey = 'id',
  }) async {
    try {
      final rec = await _pb
          .collection('groups')
          .getFirstListItem(_pb.filter('id = {:id}', {'id': groupId}));
      final cur = rec.data[col];
      final list = cur is List
          ? cur.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : <Map<String, dynamic>>[];
      if (deleteId != null) list.removeWhere((e) => e[idKey] == deleteId);
      if (upsert != null) {
        final idx = list.indexWhere((e) => e[idKey] == upsert[idKey]);
        if (idx >= 0) {
          list[idx] = upsert;
        } else {
          list.add(upsert);
        }
      }
      await _pb.collection('groups').update(rec.id, body: {col: _jsonSafe(list)});
      return true;
    } catch (e) {
      debugPrint('PbData._patchGroupListById($col) failed: $e');
      return false;
    }
  }

  // ── жизненный цикл пары ──────────────────────────────────────────────────
  /// Распустить группу для всех (soft-delete: disbanded=true, восстановимо).
  Future<bool> disbandGroup(String groupId) => updateGroupFields(groupId, {
        'disbanded': true,
        'disbanded_at': DateTime.now().toIso8601String(),
      });

  /// Убрать [uid] из группы (members + имена + аватары + настроения + недуги).
  /// Если участников не осталось — помечаем распущенной. Retry (до 3 попыток)
  /// закрывает транзиентные ошибки, но НЕ lost-update: при одновременном выходе
  /// обоих участников обе записи успешны, вторая перетирает первую → ушедший может
  /// «воскреснуть» (DATA-6). Полный фикс — серверная транзакция (groups.pb.js,
  /// TODO). Одновременный выход обоих — крайне редкий сценарий.
  Future<bool> leaveGroup(String groupId, String uid) async {
    if (groupId.isEmpty || uid.isEmpty) return false;
    // DATA-6: атомарный серверный выход; при недоступности — локальный RMW.
    final r = await _callGroupRoute('leave', {'groupId': groupId, 'uid': uid});
    if (r == _GroupRouteResult.ok) return true;
    if (r == _GroupRouteResult.backpressure) return false;
    return _leaveGroupLocal(groupId, uid);
  }

  Future<bool> _leaveGroupLocal(String groupId, String uid) async {
    const maxAttempts = 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final rec = await _pb
            .collection('groups')
            .getFirstListItem(_pb.filter('id = {:id}', {'id': groupId}));
        final members =
            (rec.data['members'] as List?)?.map((e) => e.toString()).toList() ??
                <String>[];
        members.remove(uid);
        final names = rec.data['member_names'] is Map
            ? Map<String, dynamic>.from(rec.data['member_names'] as Map)
            : <String, dynamic>{};
        final avatars = rec.data['member_avatars'] is Map
            ? Map<String, dynamic>.from(rec.data['member_avatars'] as Map)
            : <String, dynamic>{};
        final moods = rec.data['member_moods'] is Map
            ? Map<String, dynamic>.from(rec.data['member_moods'] as Map)
            : <String, dynamic>{};
        final ailments = rec.data['member_ailments'] is Map
            ? Map<String, dynamic>.from(rec.data['member_ailments'] as Map)
            : <String, dynamic>{};
        names.remove(uid);
        avatars.remove(uid);
        moods.remove(uid);
        ailments.remove(uid);
        final body = <String, dynamic>{
          'members': members,
          'member_names': names,
          'member_avatars': avatars,
          'member_moods': moods,
          'member_ailments': ailments,
        };
        if (members.isEmpty) {
          body['disbanded'] = true;
          body['disbanded_at'] = DateTime.now().toIso8601String();
        }
        await _pb.collection('groups').update(rec.id, body: body);
        return true;
      } catch (e) {
        if (attempt == maxAttempts - 1) {
          debugPrint('PbData.leaveGroup($groupId,$uid) failed after ${attempt + 1} attempts: $e');
          return false;
        }
        await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
      }
    }
    return false;
  }

  /// Выйти из пары: пару (≤2 участника) распускаем для обоих (восстановимо),
  /// группу больше 2 — просто покидаем. = unpairById на Firebase.
  Future<bool> unpairGroup(String groupId, String uid) async {
    if (groupId.isEmpty) return false;
    try {
      final rec = await _pb
          .collection('groups')
          .getFirstListItem(_pb.filter('id = {:id}', {'id': groupId}));
      final members =
          (rec.data['members'] as List?)?.map((e) => e.toString()).toList() ??
              <String>[];
      if (members.length <= 2) return disbandGroup(groupId);
      return leaveGroup(groupId, uid);
    } catch (e) {
      debugPrint('PbData.unpairGroup($groupId) failed: $e');
      return false;
    }
  }

  /// Живые группы (записи) пользователя — для race-guard в создании пары.
  Future<List<RecordModel>> activeGroupRecordsForUser(String uid) async {
    if (uid.isEmpty) return const [];
    try {
      return await _pb.collection('groups').getFullList(
            filter:
                _pb.filter('members ~ {:u} && disbanded = false', {'u': uid}),
          );
    } catch (e) {
      debugPrint('PbData.activeGroupRecordsForUser($uid) failed: $e');
      return const [];
    }
  }

  // ══════════════════════════════════════════════ INVITE CODES (Фаза 2)
  // Коллекция invite_codes: code (uniq), owner_uid, group_id?. Аналог Firestore
  // inviteCodes/{code}. Приём кода создаёт/восстанавливает/входит в группу;
  // партнёр подхватывает её через watchMyGroups (members ~ uid). Правила PB
  // открыты для authed (тест-постура) — любой залогиненный может найти чужой
  // код для приёма; ужесточить до членства перед публикой.
  static const String _codeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  String _newCode() {
    final r = Random.secure();
    return List.generate(6, (_) => _codeChars[r.nextInt(_codeChars.length)])
        .join();
  }

  Future<RecordModel?> lookupInviteCode(String code) async {
    if (code.isEmpty) return null;
    try {
      return await _pb
          .collection('invite_codes')
          .getFirstListItem(_pb.filter('code = {:c}', {'c': code}));
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return null;
      debugPrint('PbData.lookupInviteCode($code) failed: $e');
      return null;
    }
  }

  Future<void> deleteInviteCode(String code) async {
    if (code.isEmpty) return;
    try {
      final rec = await _pb
          .collection('invite_codes')
          .getFirstListItem(_pb.filter('code = {:c}', {'c': code}));
      await _pb.collection('invite_codes').delete(rec.id);
    } catch (_) {
      // нет кода / уже удалён / гонка — некритично
    }
  }

  /// Сгенерировать уникальный код, зарегистрировать (owner_uid, опц. group_id),
  /// удалить [oldCode]. Возвращает код или '' при ошибке (вызывающий — локальный
  /// фолбэк).
  Future<String> generateInviteCode({
    required String ownerUid,
    String? groupId,
    String? oldCode,
  }) async {
    if (ownerUid.isEmpty) return '';
    if (oldCode != null && oldCode.isNotEmpty) await deleteInviteCode(oldCode);
    var refreshedSession = false;
    for (var attempt = 0; attempt < 8; attempt++) {
      final code = _newCode();
      // listRule invite_codes = owner-only (анти-enumeration) → этот pre-check
      // видит лишь СВОИ коды; реальный страж коллизий — уникальный индекс на
      // create. На провал create (коллизия/гонка) пробуем следующий код.
      if (await lookupInviteCode(code) != null) continue;
      try {
        await _pb.collection('invite_codes').create(body: {
          'code': code,
          'owner_uid': ownerUid,
          if (groupId != null && groupId.isNotEmpty) 'group_id': groupId,
        });
        return code;
      } catch (e) {
        debugPrint('PbData.generateInviteCode attempt ${attempt + 1} failed: $e');
        // ЧАСТАЯ ПРИЧИНА (подтверждено логами: auth='' на сервере): токен протух/
        // не приложен → createRule `owner_uid = @request.auth.id` не проходит →
        // 400 «create rule failure». Освежаем сессию ОДИН раз и продолжаем — тогда
        // следующий create уйдёт с валидным токеном. Если токен мёртв (401 на
        // refresh) — refresh молча упадёт, код не создастся, вызывающий покажет
        // ошибку (а не фейковый локальный код).
        if (!refreshedSession) {
          refreshedSession = true;
          try {
            await _pb
                .collection('users')
                .authRefresh()
                .timeout(const Duration(seconds: 8));
          } catch (_) {}
        }
        continue;
      }
    }
    return '';
  }

  /// Приём кода → создать/войти/восстановить пару. Делегирует серверному хуку
  /// `POST /api/invite/accept` (pb_hooks/invite.pb.js): он ищет код под $app
  /// (коды НЕ читаются клиентом кросс-юзерно — закрыт enumeration) и
  /// присоединяет к паре в обход ACL по членству (клиент не может дописать себя
  /// в чужую группу). Хук возвращает {success,message,pairId,restored} — группу
  /// дочитываем сами (теперь мы её член → правила пускают) и строим pair-карту
  /// в форме старого FirebaseService.acceptInviteCode.
  Future<Map<String, dynamic>> acceptInviteCode(
    String code, {
    required String myUid,
  }) async {
    if (myUid.isEmpty) return {'success': false, 'message': 'Не авторизован'};
    code = code.toUpperCase().trim();
    if (code.isEmpty) return {'success': false, 'message': 'Введите код'};
    try {
      final resp = await _pb.send(
        '/api/invite/accept',
        method: 'POST',
        body: {'code': code},
      );
      final map =
          resp is Map ? Map<String, dynamic>.from(resp) : <String, dynamic>{};
      if (map['success'] != true) {
        return {
          'success': false,
          'message': (map['message'] ?? 'Не удалось принять код').toString(),
        };
      }
      final pairId = (map['pairId'] ?? '').toString();
      if (pairId.isEmpty) {
        return {'success': false, 'message': 'Сервер не вернул пару'};
      }
      final g = await _pb.collection('groups').getOne(pairId);
      return _acceptResult(
        g,
        myUid,
        (map['message'] ?? 'Connected!').toString(),
        restored: map['restored'] == true,
      );
    } on ClientException catch (e) {
      // Хук вернул 4xx (код не найден / свой код / занято) — текст в response.
      final msg = (e.response['message'] ?? 'Ошибка приёма кода').toString();
      debugPrint('PbData.acceptInviteCode hook ${e.statusCode}: $msg');
      return {'success': false, 'message': msg};
    } catch (e) {
      debugPrint('PbData.acceptInviteCode failed: $e');
      return {'success': false, 'message': 'Ошибка: $e'};
    }
  }

  /// Результат-карта из (свежепрочитанной) записи группы.
  Map<String, dynamic> _acceptResult(
    RecordModel g,
    String myUid,
    String message, {
    bool restored = false,
  }) {
    final m = groupRecordToPairMap(g, myUid);
    return {
      'success': true,
      'message': message,
      'partnerName': m['partnerName'],
      'partnerAvatar': m['partnerAvatar'],
      'pairId': g.id,
      'startDate': m['startDate'] ?? DateTime.now(),
      'relationshipType': m['relationshipType'] ?? 'couple',
      'customRelationshipLabel': m['customRelationshipLabel'] ?? '',
      'customRelationshipEmoji': m['customRelationshipEmoji'] ?? '',
      'customRelationshipTypes': m['customRelationshipTypes'] ?? <dynamic>[],
      'members': m['members'],
      if (restored) 'restored': true,
    };
  }

  // ══════════════════════════════════════════════ MEMORIES
  Future<bool> upsertMemory(
    String groupId,
    String id,
    Map<String, dynamic> data,
  ) async {
    if (id.isEmpty) return false;
    return _upsertById('memories', id, {
      'group_id': groupId,
      'type': data['type'],
      'author_uid': data['authorUid'],
      'author_name': data['authorName'],
      'author_avatar': data['authorAvatar'],
      'created_at': _iso(data['createdAt']),
      'edited_at': _iso(data['editedAt']),
      'is_pinned': data['isPinned'] ?? false,
      'deleted': data['deleted'] ?? false,
      'data': _jsonSafe(data),
    }, op: 'upsertMemory');
  }

  Future<bool> patchMemory(String id, Map<String, dynamic> fb) async {
    if (id.isEmpty) return false;
    final cols = <String, dynamic>{};
    if (fb.containsKey('isPinned')) cols['is_pinned'] = fb['isPinned'];
    if (fb.containsKey('editedAt')) cols['edited_at'] = _iso(fb['editedAt']);
    if (fb.containsKey('createdAt')) cols['created_at'] = _iso(fb['createdAt']);
    if (cols.isEmpty) return true;
    return _upsertById('memories', id, cols, op: 'patchMemory');
  }

  Future<bool> deleteMemory(String id, {bool hard = false}) async {
    if (id.isEmpty) return false;
    try {
      if (hard) {
        await _pb.collection('memories').delete(id);
      } else {
        // DATA-16: soft-delete только через update. Раньше _upsertById делал
        // create-on-404 → удаление НЕсуществующего воспоминания создавало
        // ghost-tombstone {id, deleted:true}. Нечего удалять (404) ловит catch
        // ниже как успех.
        await _pb.collection('memories').update(id, body: {'deleted': true});
      }
      return true;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return true;
      debugPrint('PbData.deleteMemory($id) failed: $e');
      return false;
    }
  }

  /// Лента группы (новые сверху), soft-deleted отфильтрованы. [beforeIso] —
  /// курсор по created_at для пагинации. Возвращает raw-записи.
  Future<List<RecordModel>> loadMemories(
    String groupId, {
    int limit = 50,
    String? beforeIso,
  }) async {
    if (groupId.isEmpty) return const [];
    try {
      var filter = 'group_id = {:g} && deleted = false';
      final params = <String, dynamic>{'g': groupId};
      if (beforeIso != null) {
        filter += ' && created_at < {:b}';
        params['b'] = beforeIso;
      }
      final res = await _pb.collection('memories').getList(
            perPage: limit,
            filter: _pb.filter(filter, params),
            sort: '-created_at',
          );
      return res.items;
    } catch (e) {
      debugPrint('PbData.loadMemories($groupId) failed: $e');
      return const [];
    }
  }

  /// Создаёт воспоминание (PB генерирует id). [data] — camelCase-карта (как
  /// `Memory.toJson()`, ISO-даты). Возвращает запись или null. Используется
  /// репозиторием на cutover, когда id генерит сервер (а не клиент).
  Future<RecordModel?> createMemory(
    String groupId,
    Map<String, dynamic> data,
  ) async {
    if (groupId.isEmpty) return null;
    try {
      return await _pb.collection('memories').create(body: {
        'group_id': groupId,
        'type': data['type'],
        'author_uid': data['authorUid'],
        'author_name': data['authorName'],
        'author_avatar': data['authorAvatar'],
        'created_at': _iso(data['createdAt']),
        'edited_at': _iso(data['editedAt']),
        'is_pinned': data['isPinned'] ?? false,
        'deleted': data['deleted'] ?? false,
        'data': _jsonSafe(data),
      });
    } catch (e) {
      debugPrint('PbData.createMemory failed: $e');
      return null;
    }
  }

  /// Точечное чтение воспоминания по id (deep-link пина из чата). Уважает
  /// soft-delete: удалённое воспоминание возвращает null (как старый путь).
  Future<RecordModel?> loadMemoryById(String id) async {
    if (id.isEmpty) return null;
    try {
      return await _pb.collection('memories').getFirstListItem(
            _pb.filter('id = {:id} && deleted = false', {'id': id}),
          );
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return null;
      debugPrint('PbData.loadMemoryById($id) failed: $e');
      return null;
    }
  }

  // ══════════════════════════════════════════════ MOODS
  Future<bool> upsertMood(
    String groupId,
    String uid,
    Map<String, dynamic> entry,
  ) async {
    final id = entry['id'] as String?;
    if (id == null || id.isEmpty) return false;
    return _upsertById('mood_entries', id, {
      'group_id': groupId,
      'user_uid': uid,
      'mood_id': entry['moodId'],
      'image_path': entry['imagePath'],
      'label': entry['label'],
      'timestamp': _iso(entry['timestamp']) ?? DateTime.now().toIso8601String(),
    }, op: 'upsertMood');
  }

  /// Создаёт запись настроения (PB генерирует id, как [createMemory]). [entry] —
  /// camelCase-карта (moodId/imagePath/label/timestamp). Возвращает запись или
  /// null. Используется [MoodRepository] на cutover вместо client-id.
  Future<RecordModel?> createMood(
    String groupId,
    String uid,
    Map<String, dynamic> entry,
  ) async {
    if (groupId.isEmpty || uid.isEmpty) return null;
    try {
      return await _pb.collection('mood_entries').create(body: {
        'group_id': groupId,
        'user_uid': uid,
        'mood_id': entry['moodId'],
        'image_path': entry['imagePath'],
        'label': entry['label'],
        'timestamp':
            _iso(entry['timestamp']) ?? DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('PbData.createMood failed: $e');
      return null;
    }
  }

  Future<bool> deleteMood(String entryId) async {
    if (entryId.isEmpty) return false;
    try {
      await _pb.collection('mood_entries').delete(entryId);
      return true;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return true;
      debugPrint('PbData.deleteMood($entryId) failed: $e');
      return false;
    }
  }

  Future<List<RecordModel>> loadMoods(String groupId, String uid) async {
    if (groupId.isEmpty) return const [];
    try {
      final res = await _pb.collection('mood_entries').getFullList(
            filter: _pb.filter('group_id = {:g} && user_uid = {:u}',
                {'g': groupId, 'u': uid}),
          );
      return res;
    } catch (e) {
      debugPrint('PbData.loadMoods($groupId) failed: $e');
      return const [];
    }
  }

  // ══════════════════════════════════════════════ TIMERS
  // Групповые таймеры живут json-массивом в колонке `groups.timers`; соло —
  // в `users.solo_timers`. Гранулярные правки — RMW массива (PB без транзакций;
  // для редких правок таймеров гонка некритична).

  /// Записать весь массив групповых таймеров (saveTimers).
  Future<bool> setGroupTimers(String groupId, List<dynamic> timers) =>
      updateGroupFields(groupId, {'timers': _jsonSafe(timers)});

  /// RMW над `groups.timers`: прочитать массив, преобразовать, записать.
  Future<bool> _patchGroupTimers(
    String groupId,
    List<dynamic> Function(List<dynamic>) transform, {
    String op = 'patchGroupTimers',
  }) async {
    if (groupId.isEmpty) return false;
    try {
      final rec = await _pb
          .collection('groups')
          .getFirstListItem(_pb.filter('id = {:id}', {'id': groupId}));
      final cur = rec.data['timers'];
      final list = cur is List ? List<dynamic>.from(cur) : <dynamic>[];
      await _pb
          .collection('groups')
          .update(rec.id, body: {'timers': _jsonSafe(transform(list))});
      return true;
    } catch (e) {
      debugPrint('PbData.$op($groupId) failed: $e');
      return false;
    }
  }

  /// Вставить/обновить один таймер по id (детерминированный id системного
  /// схлопывает дубли при одновременном создании пары — паритет с Firebase).
  Future<bool> upsertGroupTimer(String groupId, Map<String, dynamic> timer) {
    final id = timer['id'];
    return _patchGroupTimers(groupId, (list) {
      final idx = list.indexWhere((e) => e is Map && e['id'] == id);
      if (idx >= 0) {
        list[idx] = timer;
      } else {
        list.add(timer);
      }
      return list;
    }, op: 'upsertGroupTimer');
  }

  Future<bool> deleteGroupTimer(String groupId, String timerId) =>
      _patchGroupTimers(groupId,
          (list) => list.where((e) => !(e is Map && e['id'] == timerId)).toList(),
          op: 'deleteGroupTimer');

  Future<bool> setDefaultGroupTimer(String groupId, String timerId) =>
      _patchGroupTimers(groupId, (list) {
        for (final e in list) {
          if (e is Map) e['isDefault'] = e['id'] == timerId;
        }
        return list;
      }, op: 'setDefaultGroupTimer');

  /// Соло-таймеры пользователя (users.solo_timers). null — нет/ошибка.
  Future<List<Map<String, dynamic>>?> loadSoloTimers(String uid) async {
    final rec = await loadUserProfile(uid);
    final raw = rec?.data['solo_timers'];
    return raw is List
        ? raw.map((e) => Map<String, dynamic>.from(e as Map)).toList()
        : null;
  }

  Future<bool> saveSoloTimers(String uid, List<dynamic> timers) =>
      updateUserProfile(uid, {'soloTimers': timers});

  // ══════════════════════════════════════════════ ACTIVE SESSION (co-watch invite)
  // Приглашение хранится json-полем `groups.active_session` (плеер co-watch —
  // отдельный RTDB-слой, мигрирует позже). Один write — партнёрский live-листенер
  // группы ловит его без доп. чтения.
  Future<bool> setActiveSession(
          String groupId, Map<String, dynamic> session) =>
      updateGroupFields(groupId, {'active_session': _jsonSafe(session)});

  /// Снять активный сеанс (null в json-колонке).
  Future<bool> clearActiveSession(String groupId) =>
      updateGroupFields(groupId, {'active_session': null});

  // ══════════════════════════════════════════════ LIVE LOCATION («Где мы»)
  // Точка участника в канале пары `pair_<a>_<b>` (json `data`). Upsert по
  // (channel,user_uid). Замена RTDB liveLocation/{channel}/points/{uid}.
  Future<bool> setLivePoint(
    String channel,
    String uid,
    Map<String, dynamic> point,
  ) async {
    if (channel.isEmpty || uid.isEmpty) return false;
    return _upsertByFilter(
      'live_location',
      'channel = {:c} && user_uid = {:u}',
      {'c': channel, 'u': uid},
      {'channel': channel, 'user_uid': uid, 'data': _jsonSafe(point)},
      op: 'setLivePoint',
    );
  }

  // ══════════════════════════════════════════════ CO-WATCH SESSION (плеер)
  // Состояние сеанса — запись live_sessions (id=pairId); презенс — live_session_
  // presence (heartbeat+TTL); чат — live_session_chat. Замена RTDB liveSessions.
  Future<bool> startSession(String pairId, Map<String, dynamic> data) =>
      _upsertById('live_sessions', pairId, {
        'activity': data['activity'],
        'media_id': data['mediaId'],
        'is_playing': data['isPlaying'] ?? false,
        'position_ms': data['positionMs'] ?? 0,
        'last_action_at':
            data['lastActionAt'] ?? DateTime.now().millisecondsSinceEpoch,
        'controller_uid': data['controllerUid'],
        'seq': data['seq'] ?? 0,
      }, op: 'startSession');

  /// Действие плеера (play/pause/seek/heartbeat). last_action_at — клиентский
  /// epoch (PB без serverTimestamp; heartbeat каждые ~8с пере-синкает дрейф).
  Future<bool> pushSessionAction(String pairId, Map<String, dynamic> a) {
    final body = <String, dynamic>{
      'is_playing': a['isPlaying'],
      'position_ms': a['positionMs'],
      'last_action_at': DateTime.now().millisecondsSinceEpoch,
      'controller_uid': a['controllerUid'],
      'seq': a['seq'],
      if (a['mediaId'] != null) 'media_id': a['mediaId'],
    };
    return _upsertById('live_sessions', pairId, body, op: 'pushSessionAction');
  }

  /// Завершить сеанс: удалить запись + презенс + чат пары.
  Future<bool> endSession(String pairId) async {
    if (pairId.isEmpty) return false;
    try {
      try {
        await _pb.collection('live_sessions').delete(pairId);
      } on ClientException catch (e) {
        if (e.statusCode != 404) rethrow;
      }
      for (final col in ['live_session_presence', 'live_session_chat']) {
        final rows = await _pb
            .collection(col)
            .getFullList(filter: _pb.filter('pair_id = {:p}', {'p': pairId}));
        for (final r in rows) {
          await _pb.collection(col).delete(r.id);
        }
      }
      return true;
    } catch (e) {
      debugPrint('PbData.endSession failed: $e');
      return false;
    }
  }

  Future<bool> touchSessionPresence(String pairId, String uid) =>
      _upsertByFilter('live_session_presence',
          'pair_id = {:p} && user_uid = {:u}', {'p': pairId, 'u': uid}, {
        'pair_id': pairId,
        'user_uid': uid,
        'seen_at': DateTime.now().millisecondsSinceEpoch,
      }, op: 'touchSessionPresence');

  /// Презенс «онлайн» (общий heartbeat, НЕ co-watch): обновить seen_at своего uid.
  Future<bool> touchPresence(String uid) {
    if (uid.isEmpty) return Future.value(false);
    return _upsertByFilter('user_presence', 'user_uid = {:u}', {'u': uid}, {
      'user_uid': uid,
      'seen_at': DateTime.now().millisecondsSinceEpoch,
    }, op: 'touchPresence');
  }

  Future<bool> removeSessionPresence(String pairId, String uid) async {
    if (pairId.isEmpty || uid.isEmpty) return false;
    try {
      final rec = await _pb.collection('live_session_presence').getFirstListItem(
          _pb.filter('pair_id = {:p} && user_uid = {:u}',
              {'p': pairId, 'u': uid}));
      await _pb.collection('live_session_presence').delete(rec.id);
      return true;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return true;
      debugPrint('PbData.removeSessionPresence failed: $e');
      return false;
    }
  }

  Future<RecordModel?> sendSessionChat(
      String pairId, Map<String, dynamic> msg) async {
    if (pairId.isEmpty) return null;
    try {
      return await _pb.collection('live_session_chat').create(body: {
        'pair_id': pairId,
        'uid': msg['uid'],
        'name': msg['name'],
        'text': msg['text'],
        'ts': msg['ts'] ?? DateTime.now().millisecondsSinceEpoch,
        'reply_to_id': msg['replyToId'],
        'reply_to_name': msg['replyToName'],
        'reply_to_text': msg['replyToText'],
      }..removeWhere((k, v) => v == null));
    } catch (e) {
      debugPrint('PbData.sendSessionChat failed: $e');
      return null;
    }
  }

  /// Реакция на сообщение session-чата (RMW json reactions). id = id записи.
  Future<bool> setSessionChatReaction(
      String messageId, String uid, String? emoji) async {
    if (messageId.isEmpty || uid.isEmpty) return false;
    try {
      final rec = await _pb.collection('live_session_chat').getOne(messageId);
      final cur = rec.data['reactions'];
      final r = cur is Map ? Map<String, dynamic>.from(cur) : <String, dynamic>{};
      if (emoji == null || emoji.isEmpty) {
        r.remove(uid);
      } else {
        r[uid] = emoji;
      }
      await _pb
          .collection('live_session_chat')
          .update(messageId, body: {'reactions': r});
      return true;
    } catch (e) {
      debugPrint('PbData.setSessionChatReaction failed: $e');
      return false;
    }
  }

  /// Удалить свою точку (явное выключение шеринга).
  Future<bool> clearLivePoint(String channel, String uid) async {
    if (channel.isEmpty || uid.isEmpty) return false;
    try {
      final rec = await _pb.collection('live_location').getFirstListItem(
          _pb.filter('channel = {:c} && user_uid = {:u}',
              {'c': channel, 'u': uid}));
      await _pb.collection('live_location').delete(rec.id);
      return true;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return true;
      debugPrint('PbData.clearLivePoint failed: $e');
      return false;
    }
  }

  // ══════════════════════════════════════════════ COMMENTS
  Future<bool> upsertComment(
    String groupId,
    String memoryId,
    String id,
    Map<String, dynamic> data,
  ) async {
    if (id.isEmpty) return false;
    return _upsertById('memory_comments', id, {
      'group_id': groupId,
      'memory_id': memoryId,
      'author_uid': data['authorUid'],
      'author_name': data['authorName'],
      'author_avatar': data['authorAvatar'],
      'text': data['text'],
      'created_at': _iso(data['createdAt']) ?? DateTime.now().toIso8601String(),
    }, op: 'upsertComment');
  }

  /// Создаёт комментарий (PB генерирует id). Возвращает запись или null.
  Future<RecordModel?> createComment(
    String groupId,
    String memoryId,
    Map<String, dynamic> data,
  ) async {
    if (memoryId.isEmpty) return null;
    try {
      return await _pb.collection('memory_comments').create(body: {
        'group_id': groupId,
        'memory_id': memoryId,
        'author_uid': data['authorUid'],
        'author_name': data['authorName'],
        'author_avatar': data['authorAvatar'],
        'text': data['text'],
        'created_at':
            _iso(data['createdAt']) ?? DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('PbData.createComment failed: $e');
      return null;
    }
  }

  Future<bool> deleteComment(String id) async {
    if (id.isEmpty) return false;
    try {
      // id комментария = id PB-записи (createComment отдаёт rec.id) → удаляем
      // напрямую, без лишнего getFirstListItem.
      await _pb.collection('memory_comments').delete(id);
      return true;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return true;
      debugPrint('PbData.deleteComment($id) failed: $e');
      return false;
    }
  }

  Future<List<RecordModel>> loadComments(String memoryId) async {
    if (memoryId.isEmpty) return const [];
    try {
      return await _pb.collection('memory_comments').getFullList(
            filter: _pb.filter(
                'memory_id = {:m} && deleted = false', {'m': memoryId}),
            sort: 'created_at',
          );
    } catch (e) {
      debugPrint('PbData.loadComments($memoryId) failed: $e');
      return const [];
    }
  }

  // ══════════════════════════════════════════════ WIDGET DATA (составной ключ)
  Future<bool> upsertWidget(
    String groupId,
    String uid,
    Map<String, dynamic> d,
  ) async {
    if (groupId.isEmpty || uid.isEmpty) return false;
    final body = <String, dynamic>{
      'group_id': groupId,
      'user_uid': uid,
      'display_name': d['displayName'],
      'avatar_url': d['avatarUrl'],
      'gender': d['gender'],
      'status': d['status'],
      'mood_emoji': d['moodEmoji'],
      'mood_label': d['moodLabel'],
      'message': d['message'],
      'music_title': d['musicTitle'],
      'music_artist': d['musicArtist'],
      'music_url': d['musicUrl'],
      'music_cover_url': d['musicCoverUrl'],
      'photo_url': d['photoUrl'],
      'photo_for_partner_url': d['photoForPartnerUrl'],
      'photo_for_partner_urls': _jsonSafe(d['photoForPartnerUrls'] ?? []),
      'photo_grid_count': d['photoGridCount'] ?? 1,
      'photo_grid_urls': _jsonSafe(d['photoGridUrls'] ?? []),
      'data': _jsonSafe(d['data'] ?? {}),
      'updated_at': DateTime.now().toIso8601String(),
    }..removeWhere((k, v) => v == null);
    return _upsertByFilter(
      'widget_data',
      'group_id = {:g} && user_uid = {:u}',
      {'g': groupId, 'u': uid},
      body,
      op: 'upsertWidget',
    );
  }

  Future<RecordModel?> loadWidget(String groupId, String uid) async {
    if (groupId.isEmpty || uid.isEmpty) return null;
    try {
      return await _pb.collection('widget_data').getFirstListItem(
            _pb.filter('group_id = {:g} && user_uid = {:u}',
                {'g': groupId, 'u': uid}),
          );
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return null;
      debugPrint('PbData.loadWidget failed: $e');
      return null;
    }
  }

  // ══════════════════════════════════════════════ CANVAS
  Future<bool> upsertStroke(
    String groupId,
    String canvasId,
    String id,
    Map<String, dynamic> data,
  ) async {
    if (id.isEmpty) return false;
    return _upsertById('canvas_strokes', id, {
      'group_id': groupId,
      'canvas_id': canvasId,
      'order_index': (data['orderIndex'] as num?)?.toInt() ?? 0,
      'data': _jsonSafe(data),
    }, op: 'upsertStroke');
  }

  /// Создаёт штрих (PB генерит id, как [createMemory]). [data] — camelCase-карта
  /// (`DrawStroke.toFirestore()`); вся геометрия в json `data` + индексируемый
  /// order_index. Возвращает запись или null.
  Future<RecordModel?> createStroke(
    String groupId,
    String canvasId,
    Map<String, dynamic> data,
  ) async {
    if (groupId.isEmpty) return null;
    try {
      return await _pb.collection('canvas_strokes').create(body: {
        'group_id': groupId,
        'canvas_id': canvasId,
        'order_index': (data['orderIndex'] as num?)?.toInt() ?? 0,
        'data': _jsonSafe(data),
      });
    } catch (e) {
      debugPrint('PbData.createStroke failed: $e');
      return null;
    }
  }

  /// Live-штрих (in-progress) пользователя: upsert по (group,canvas,user), вся
  /// геометрия в json `data` (`DrawStroke.toLiveMap()`). Замена эфемерного
  /// Firestore live-дока. Высокочастотно — но на PB записи бесплатны.
  Future<bool> setLiveStroke(
    String groupId,
    String canvasId,
    String uid,
    Map<String, dynamic> liveData,
  ) async {
    if (groupId.isEmpty || uid.isEmpty) return false;
    return _upsertByFilter(
      'canvas_live',
      'group_id = {:g} && canvas_id = {:c} && user_uid = {:u}',
      {'g': groupId, 'c': canvasId, 'u': uid},
      {
        'group_id': groupId,
        'canvas_id': canvasId,
        'user_uid': uid,
        'data': _jsonSafe(liveData),
      },
      op: 'setLiveStroke',
    );
  }

  /// Убрать свой live-штрих при отрыве пальца.
  Future<bool> clearLiveStroke(
      String groupId, String canvasId, String uid) async {
    if (groupId.isEmpty || uid.isEmpty) return false;
    try {
      final rec = await _pb.collection('canvas_live').getFirstListItem(
          _pb.filter('group_id = {:g} && canvas_id = {:c} && user_uid = {:u}',
              {'g': groupId, 'c': canvasId, 'u': uid}));
      await _pb.collection('canvas_live').delete(rec.id);
      return true;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return true;
      debugPrint('PbData.clearLiveStroke failed: $e');
      return false;
    }
  }

  Future<bool> patchStroke(String id, Map<String, dynamic> updates) async {
    if (id.isEmpty) return false;
    // RMW: PB не умеет json-merge на сервере → читаем, мёржим data, пишем.
    try {
      final rec = await _pb
          .collection('canvas_strokes')
          .getFirstListItem(_pb.filter('id = {:id}', {'id': id}));
      final cur = rec.data['data'];
      final merged = cur is Map
          ? (Map<String, dynamic>.from(cur)..addAll(_jsonSafe(updates) as Map<String, dynamic>))
          : _jsonSafe(updates);
      await _pb.collection('canvas_strokes').update(rec.id, body: {'data': merged});
      return true;
    } catch (e) {
      debugPrint('PbData.patchStroke($id) failed: $e');
      return false;
    }
  }

  Future<bool> deleteStroke(String id) async {
    if (id.isEmpty) return false;
    try {
      await _pb.collection('canvas_strokes').delete(id);
      return true;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return true;
      debugPrint('PbData.deleteStroke($id) failed: $e');
      return false;
    }
  }

  Future<bool> clearCanvas(String groupId, String canvasId, int version,
      {int? bgColor}) async {
    if (groupId.isEmpty) return false;
    try {
      final strokes = await _pb.collection('canvas_strokes').getFullList(
            filter: _pb.filter('group_id = {:g} && canvas_id = {:c}',
                {'g': groupId, 'c': canvasId}),
          );
      for (final s in strokes) {
        await _pb.collection('canvas_strokes').delete(s.id);
      }
      // Чистим и live-курсоры (паритет с Firebase clearDrawingCanvas).
      final live = await _pb.collection('canvas_live').getFullList(
            filter: _pb.filter('group_id = {:g} && canvas_id = {:c}',
                {'g': groupId, 'c': canvasId}),
          );
      for (final l in live) {
        await _pb.collection('canvas_live').delete(l.id);
      }
      final body = <String, dynamic>{
        'group_id': groupId,
        'canvas_id': canvasId,
        'clear_version': version,
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (bgColor != null) body['bg_color'] = bgColor;
      return _upsertByFilter('canvas_meta',
          'group_id = {:g} && canvas_id = {:c}', {'g': groupId, 'c': canvasId},
          body, op: 'clearCanvas');
    } catch (e) {
      debugPrint('PbData.clearCanvas($groupId/$canvasId) failed: $e');
      return false;
    }
  }

  Future<bool> upsertCanvasMeta(String groupId, String canvasId,
      {int? bgColor, int? rotation, int? clearVersion}) async {
    if (groupId.isEmpty) return false;
    final body = <String, dynamic>{
      'group_id': groupId,
      'canvas_id': canvasId,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (bgColor != null) body['bg_color'] = bgColor;
    if (rotation != null) body['canvas_rotation'] = rotation;
    if (clearVersion != null) body['clear_version'] = clearVersion;
    return _upsertByFilter('canvas_meta',
        'group_id = {:g} && canvas_id = {:c}', {'g': groupId, 'c': canvasId},
        body, op: 'upsertCanvasMeta');
  }

  Future<bool> upsertCanvasCatalogue(
      String groupId, String canvasId, Map<String, dynamic> data) async {
    if (groupId.isEmpty || canvasId.isEmpty) return false;
    final body = <String, dynamic>{'group_id': groupId, 'canvas_id': canvasId};
    if (data.containsKey('name')) body['name'] = data['name'];
    if (data.containsKey('createdAt')) body['created_at'] = data['createdAt'];
    if (data.containsKey('updatedAt')) body['updated_at'] = data['updatedAt'];
    if (data.containsKey('createdBy')) body['created_by'] = data['createdBy'];
    return _upsertByFilter('canvas_catalogue',
        'group_id = {:g} && canvas_id = {:c}', {'g': groupId, 'c': canvasId},
        body, op: 'upsertCanvasCatalogue');
  }

  Future<bool> deleteCanvasCatalogue(String groupId, String canvasId) async {
    if (groupId.isEmpty || canvasId.isEmpty) return false;
    try {
      final rec = await _pb.collection('canvas_catalogue').getFirstListItem(
          _pb.filter('group_id = {:g} && canvas_id = {:c}',
              {'g': groupId, 'c': canvasId}));
      await _pb.collection('canvas_catalogue').delete(rec.id);
      return true;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return true;
      debugPrint('PbData.deleteCanvasCatalogue failed: $e');
      return false;
    }
  }

  Future<List<RecordModel>> loadStrokes(String groupId, String canvasId) async {
    if (groupId.isEmpty) return const [];
    try {
      return await _pb.collection('canvas_strokes').getFullList(
            filter: _pb.filter('group_id = {:g} && canvas_id = {:c}',
                {'g': groupId, 'c': canvasId}),
            sort: 'order_index',
          );
    } catch (e) {
      debugPrint('PbData.loadStrokes failed: $e');
      return const [];
    }
  }

  Future<List<RecordModel>> loadCanvasCatalogue(String groupId) async {
    if (groupId.isEmpty) return const [];
    try {
      return await _pb.collection('canvas_catalogue').getFullList(
          filter: _pb.filter('group_id = {:g}', {'g': groupId}));
    } catch (e) {
      debugPrint('PbData.loadCanvasCatalogue failed: $e');
      return const [];
    }
  }

  // ══════════════════════════════════════════════ MASCOTS (составной group+mascot_id)
  Map<String, dynamic> _mascotBody(String groupId, Map<String, dynamic> m) => {
        'group_id': groupId,
        'mascot_id': m['id'], // SQL-поле id маскота → колонка mascot_id в PB
        'name': m['name'],
        'image_url': m['imageUrl'],
        'default_asset': m['defaultAsset'],
        'created_by': m['createdBy'],
        'created_at': _iso(m['createdAt']),
        'is_default': m['isDefault'] ?? false,
      }..removeWhere((k, v) => v == null);

  Future<bool> upsertMascot(String groupId, Map<String, dynamic> m) async {
    final mid = (m['id'] ?? '').toString();
    if (groupId.isEmpty || mid.isEmpty) return false;
    return _upsertByFilter('mascots',
        'group_id = {:g} && mascot_id = {:m}', {'g': groupId, 'm': mid},
        _mascotBody(groupId, m), op: 'upsertMascot');
  }

  Future<bool> upsertMascotsBatch(
      String groupId, List<Map<String, dynamic>> mascots) async {
    if (groupId.isEmpty || mascots.isEmpty) return false;
    var ok = true;
    for (final m in mascots) {
      ok = await upsertMascot(groupId, m) && ok;
    }
    return ok;
  }

  Future<bool> deleteMascot(String groupId, String mascotId) async {
    if (groupId.isEmpty || mascotId.isEmpty) return false;
    try {
      final rec = await _pb.collection('mascots').getFirstListItem(_pb.filter(
          'group_id = {:g} && mascot_id = {:m}', {'g': groupId, 'm': mascotId}));
      await _pb.collection('mascots').delete(rec.id);
      return true;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return true;
      debugPrint('PbData.deleteMascot failed: $e');
      return false;
    }
  }

  Future<bool> updateMascotFields(
      String groupId, String mascotId, Map<String, dynamic> cols) async {
    if (groupId.isEmpty || mascotId.isEmpty || cols.isEmpty) return false;
    try {
      final rec = await _pb.collection('mascots').getFirstListItem(_pb.filter(
          'group_id = {:g} && mascot_id = {:m}', {'g': groupId, 'm': mascotId}));
      await _pb.collection('mascots').update(rec.id, body: cols);
      return true;
    } catch (e) {
      debugPrint('PbData.updateMascotFields failed: $e');
      return false;
    }
  }

  Future<List<RecordModel>> loadMascots(String groupId) async {
    if (groupId.isEmpty) return const [];
    try {
      return await _pb.collection('mascots').getFullList(
          filter: _pb.filter('group_id = {:g}', {'g': groupId}));
    } catch (e) {
      debugPrint('PbData.loadMascots failed: $e');
      return const [];
    }
  }

  // ── Состояние маскота — колонки group-дока (active/position/streak) ─────────
  /// Активный маскот пары. `null` → очистка (пишем пустую строку: text-колонка
  /// PB не nullable; [GroupMascotState.fromPb] коэрсит `''`→null).
  Future<bool> setActiveMascot(String groupId, String? mascotId) =>
      updateGroupFields(groupId, {'active_mascot_id': mascotId ?? ''});

  /// Позиция/масштаб плавающего маскота на экране.
  Future<bool> updateMascotPosition(
    String groupId,
    double x,
    double y,
    double scale,
  ) =>
      updateGroupFields(groupId, {
        'mascot_position_x': x,
        'mascot_position_y': y,
        'mascot_scale': scale,
      });

  /// Отметить, что [uid] зашёл сегодня → ведение «огонька» пары. Порт логики
  /// Firebase.recordGroupActivity: серия растёт ТОЛЬКО когда за день зашли ОБА
  /// разных участника (первый фиксируется в streak_pending_*, второй поднимает
  /// streak_days). Retry (до 3 попыток) закрывает транзиентные ошибки, но НЕ
  /// lost-update: если оба заходят одновременно, оба читают пустой
  /// streak_pending_*, оба пишут себя — вторая запись успешна и перетирает первую,
  /// день серии может потеряться (DATA-9). Полный фикс — серверная транзакция
  /// (groups.pb.js, TODO). Точная одновременность первого захода обоих — редкость.
  Future<void> recordGroupActivity(String groupId, String uid) async {
    if (groupId.isEmpty || uid.isEmpty) return;
    final now = DateTime.now();
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    // DATA-9: атомарный серверный учёт стрика; today = локальная дата клиента
    // (сохраняет семантику). При недоступности роута — локальный RMW.
    final r = await _callGroupRoute('record-activity',
        {'groupId': groupId, 'uid': uid, 'today': today});
    if (r == _GroupRouteResult.ok) return;
    // Под нагрузкой не долбим локальным RMW (стрик до-учтётся при следующем заходе).
    if (r == _GroupRouteResult.backpressure) return;
    return _recordGroupActivityLocal(groupId, uid);
  }

  Future<void> _recordGroupActivityLocal(String groupId, String uid) async {
    const maxAttempts = 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final now = DateTime.now();
        final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')}';
        final rec = await _pb
            .collection('groups')
            .getFirstListItem(_pb.filter('id = {:id}', {'id': groupId}));
        final d = rec.data;
        String? nz(dynamic v) {
          final s = v?.toString();
          return (s == null || s.isEmpty) ? null : s;
        }

        final last = nz(d['streak_last_opened_date']);
        if (last == today) return; // уже засчитано сегодня (оба заходили)

        bool bothPresent() {
          final pUid = nz(d['streak_pending_uid']);
          return nz(d['streak_pending_date']) == today &&
              pUid != null &&
              pUid != uid;
        }

        if (bothPresent()) {
          final todayDate = DateTime(now.year, now.month, now.day);
          int daysSince(String? iso) {
            final dt = (iso != null && iso.isNotEmpty)
                ? DateTime.tryParse(iso)
                : null;
            return dt != null
                ? todayDate
                    .difference(DateTime(dt.year, dt.month, dt.day))
                    .inDays
                : 999;
          }

          final currentStreak = (d['streak_days'] as num?)?.toInt() ?? 0;
          final newStreak = daysSince(last) == 1 ? currentStreak + 1 : 1;

          // PER-MASCOT серия активного маскота (его собственная дата). Пропуск → 1.
          final activeMascotId = nz(d['active_mascot_id']);
          final raw = d['mascot_streaks'];
          final streaks =
              raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
          int mStreak = 0;
          if (activeMascotId != null) {
            final prev = streaks[activeMascotId];
            final prevS =
                (prev is Map ? (prev['s'] as num?)?.toInt() : 0) ?? 0;
            final prevD = prev is Map ? prev['d']?.toString() : null;
            mStreak = daysSince(prevD) == 1 ? prevS + 1 : 1;
            streaks[activeMascotId] = {'s': mStreak, 'd': today};
          }

          await _pb.collection('groups').update(rec.id, body: {
            'streak_days': newStreak,
            'streak_last_opened_date': today,
            if (activeMascotId != null) 'mascot_streaks': streaks,
          });
          if (activeMascotId != null) {
            try {
              final mascot = await _pb.collection('mascots').getFirstListItem(
                  _pb.filter('group_id = {:g} && mascot_id = {:m}',
                      {'g': groupId, 'm': activeMascotId}));
              final record = (mascot.data['record_streak'] as num?)?.toInt() ?? 0;
              if (mStreak > record) {
                await _pb
                    .collection('mascots')
                    .update(mascot.id, body: {'record_streak': mStreak});
              }
            } catch (_) {}
          }
          return;
        }

        final pendingDate = nz(d['streak_pending_date']);
        final pendingUid = nz(d['streak_pending_uid']);
        if (pendingDate != today || pendingUid == null) {
          await _pb.collection('groups').update(rec.id, body: {
            'streak_pending_date': today,
            'streak_pending_uid': uid,
          });
        }
        return; // успех — выходим
      } catch (e) {
        if (attempt == maxAttempts - 1) {
          debugPrint('PbData.recordGroupActivity failed after ${attempt + 1} attempts: $e');
          return;
        }
        await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
      }
    }
  }

  // ══════════════════════════════════════════════ MISS YOU (составной)
  /// Инкремент «скучаю» + тип вайба. При гонке (двойное нажатие) — retry с
  /// перечтением (до 3 попыток), чтобы счётчик рос корректно.
  Future<bool> incrementMissYou(
    String groupId,
    String uid, {
    String vibe = 'miss_you',
    String? text,
  }) async {
    if (groupId.isEmpty || uid.isEmpty) return false;
    // DATA-8: атомарный серверный инкремент; при недоступности — локальный RMW.
    // weekday шлём свой: сервер живёт в UTC, и вечерние нажатия у нас попадали
    // бы в следующий день недели.
    final r = await _callGroupRoute('miss-you', {
      'groupId': groupId,
      'uid': uid,
      'vibe': vibe,
      'text': text ?? '',
      'weekday': DateTime.now().weekday, // 1 = понедельник
    });
    if (r == _GroupRouteResult.ok) return true;
    if (r == _GroupRouteResult.backpressure) return false;
    return _incrementMissYouLocal(groupId, uid, vibe: vibe, text: text);
  }

  Future<bool> _incrementMissYouLocal(
    String groupId,
    String uid, {
    String vibe = 'miss_you',
    String? text,
  }) async {
    const maxAttempts = 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final f = _pb.filter('group_id = {:g} && user_uid = {:u}',
            {'g': groupId, 'u': uid});
        final extra = {'last_vibe': vibe, 'last_vibe_text': text ?? ''};
        try {
          final rec = await _pb.collection('miss_you').getFirstListItem(f);
          final cur = (rec.data['count'] as num?)?.toInt() ?? 0;
          await _pb.collection('miss_you').update(rec.id, body: {
            'count': cur + 1,
            'updated_at': DateTime.now().toIso8601String(),
            ...extra,
          });
        } on ClientException catch (e) {
          if (e.statusCode != 404) rethrow;
          await _pb.collection('miss_you').create(body: {
            'group_id': groupId,
            'user_uid': uid,
            'count': 1,
            'updated_at': DateTime.now().toIso8601String(),
            ...extra,
          });
        }
        return true;
      } catch (e) {
        if (attempt == maxAttempts - 1) {
          debugPrint('PbData.incrementMissYou failed after ${attempt + 1} attempts: $e');
          return false;
        }
        await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
      }
    }
    return false;
  }

  Future<bool> setMissYouCount(String groupId, String uid, int count) async {
    if (groupId.isEmpty || uid.isEmpty) return false;
    return _upsertByFilter('miss_you',
        'group_id = {:g} && user_uid = {:u}', {'g': groupId, 'u': uid}, {
      'group_id': groupId,
      'user_uid': uid,
      'count': count,
      'updated_at': DateTime.now().toIso8601String(),
    }, op: 'setMissYouCount');
  }

  Future<Map<String, int>> getMissYouCounts(String groupId) async {
    if (groupId.isEmpty) return const {};
    try {
      final rows = await _pb.collection('miss_you').getFullList(
          filter: _pb.filter('group_id = {:g}', {'g': groupId}));
      return {
        for (final r in rows)
          (r.data['user_uid'] ?? '').toString():
              (r.data['count'] as num?)?.toInt() ?? 0,
      };
    } catch (e) {
      debugPrint('PbData.getMissYouCounts failed: $e');
      return const {};
    }
  }

  // ══════════════════════════════════════════════ CHAT
  Future<bool> chatSend(String groupId, String id, Map<String, dynamic> msg) async {
    if (id.isEmpty) return false;
    final body = <String, dynamic>{
      'group_id': groupId,
      'user_uid': msg['uid'],
      'user_name': msg['name'],
      'text': msg['text'],
      'ts': msg['ts'],
      'pin_id': msg['pinId'],
      'pin_title': msg['pinTitle'],
      'pin_thumb': msg['pinThumb'],
      'reply_to_id': msg['replyToId'],
      'reply_to_name': msg['replyToName'],
      'reply_to_text': msg['replyToText'],
      'face': msg['face'],
      'color': msg['color'],
      'face_x': msg['faceX'],
      'face_y': msg['faceY'],
    }..removeWhere((k, v) => v == null);
    return _upsertById('chat_messages', id, body, op: 'chatSend');
  }

  /// Создаёт сообщение (PB генерирует id, как [createMemory]). [msg] —
  /// camelCase-карта (uid/name/text/ts/pin*/reply*/face/color/faceX/faceY).
  /// Возвращает запись или null. ts — клиентский epoch-ms (PB не пишет
  /// server-time в number-поле; для пары этого достаточно, как и в Supabase).
  Future<RecordModel?> createMessage(
    String groupId,
    Map<String, dynamic> msg,
  ) async {
    if (groupId.isEmpty) return null;
    try {
      final body = <String, dynamic>{
        'group_id': groupId,
        'user_uid': msg['uid'],
        'user_name': msg['name'],
        'text': msg['text'],
        'ts': msg['ts'],
        'pin_id': msg['pinId'],
        'pin_title': msg['pinTitle'],
        'pin_thumb': msg['pinThumb'],
        'reply_to_id': msg['replyToId'],
        'reply_to_name': msg['replyToName'],
        'reply_to_text': msg['replyToText'],
        'face': msg['face'],
        'color': msg['color'],
        'face_x': msg['faceX'],
        'face_y': msg['faceY'],
      }..removeWhere((k, v) => v == null);
      return await _pb.collection('chat_messages').create(body: body);
    } catch (e) {
      debugPrint('PbData.createMessage failed: $e');
      return null;
    }
  }

  Future<bool> chatUpdate(String id, Map<String, dynamic> fields) async {
    if (id.isEmpty) return false;
    return _upsertById('chat_messages', id, Map.of(fields), op: 'chatUpdate');
  }

  Future<bool> chatRead(String groupId, String uid, int ts) async {
    if (groupId.isEmpty || uid.isEmpty) return false;
    return _upsertByFilter('chat_reads',
        'group_id = {:g} && user_uid = {:u}', {'g': groupId, 'u': uid}, {
      'group_id': groupId,
      'user_uid': uid,
      'last_read_ts': ts,
      'updated_at': DateTime.now().toIso8601String(),
    }, op: 'chatRead');
  }

  /// Маркер «печатает…»: upsert по (group,uid). [typingAt] — epoch-ms текущего
  /// heartbeat'а либо 0, когда перестал печатать (партнёр считает по свежести).
  /// Замена RTDB typing с onDisconnect — маркер протухает по TTL (см. схему).
  Future<bool> setTyping(String groupId, String uid, int typingAt) async {
    if (groupId.isEmpty || uid.isEmpty) return false;
    return _upsertByFilter('chat_typing',
        'group_id = {:g} && user_uid = {:u}', {'g': groupId, 'u': uid}, {
      'group_id': groupId,
      'user_uid': uid,
      'typing_at': typingAt,
    }, op: 'setTyping');
  }

  /// Ставит/снимает реакцию uid на сообщение (RMW по json-полю reactions).
  Future<bool> setChatReaction(String id, String uid, String? emoji) async {
    if (id.isEmpty || uid.isEmpty) return false;
    try {
      final rec = await _pb
          .collection('chat_messages')
          .getFirstListItem(_pb.filter('id = {:id}', {'id': id}));
      final cur = rec.data['reactions'];
      final r = cur is Map ? Map<String, dynamic>.from(cur) : <String, dynamic>{};
      if (emoji == null || emoji.isEmpty) {
        r.remove(uid);
      } else {
        r[uid] = emoji;
      }
      await _pb.collection('chat_messages').update(rec.id, body: {'reactions': r});
      return true;
    } catch (e) {
      debugPrint('PbData.setChatReaction failed: $e');
      return false;
    }
  }

  /// Последние [limit] сообщений (новые сверху; разверни на стороне UI).
  Future<List<RecordModel>> loadMessages(String groupId, {int limit = 100}) async {
    if (groupId.isEmpty) return const [];
    try {
      final res = await _pb.collection('chat_messages').getList(
            perPage: limit,
            filter: _pb.filter('group_id = {:g} && deleted != true', {'g': groupId}),
            sort: '-ts',
          );
      return res.items;
    } catch (e) {
      debugPrint('PbData.loadMessages failed: $e');
      return const [];
    }
  }

  Future<Map<String, int>> loadChatReads(String groupId) async {
    if (groupId.isEmpty) return const {};
    try {
      final rows = await _pb.collection('chat_reads').getFullList(
          filter: _pb.filter('group_id = {:g}', {'g': groupId}));
      return {
        for (final r in rows)
          (r.data['user_uid'] ?? '').toString():
              (r.data['last_read_ts'] as num?)?.toInt() ?? 0,
      };
    } catch (e) {
      debugPrint('PbData.loadChatReads failed: $e');
      return const {};
    }
  }

  // ══════════════════════════════════════════════ USER PROFILE / CATALOG
  /// Профиль юзера = запись users по id (= uid). Возвращает raw-данные записи.
  Future<RecordModel?> loadUserProfile(String uid) async {
    if (uid.isEmpty) return null;
    try {
      return await _pb.collection('users').getOne(uid);
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return null;
      debugPrint('PbData.loadUserProfile($uid) failed: $e');
      return null;
    }
  }

  /// Профиль users как camelCase-карта (зеркало прежнего Firestore-формата) —
  /// чтобы UserData._syncFromFirestore/refreshCoinsFromServer читали без правок.
  /// json-поля Dart SDK уже отдаёт списками; birth_date — ISO-строка.
  Future<Map<String, dynamic>?> loadUserProfileMap(String uid) async {
    final rec = await loadUserProfile(uid);
    if (rec == null) return null;
    final d = rec.data;
    return {
      'displayName': d['display_name'],
      'email': d['email'],
      'avatarUrl': d['avatar_url'],
      'bannerUrl': d['banner_url'],
      'gender': d['gender'],
      'badge': d['badge'],
      'coins': d['coins'],
      'ownedThemes': d['owned_themes'],
      'ownedIcons': d['owned_icons'],
      'ownedFeatures': d['owned_features'],
      'grantedBadges': d['granted_badges'],
      'devCoinsGranted': d['dev_coins_granted'],
      'adRewardsToday': d['ad_rewards_today'],
      'adRewardsDate': d['ad_rewards_date'],
      // Серверные таймстампы кулдаунов (epoch-ms). Нужны клиенту, чтобы
      // восстановить статус «выполнено» для ежедневного бонуса/воспоминания
      // между сессиями — иначе ✓ держится только на сессионном флаге и
      // задание показывается невыполненным, хотя коин за период уже получен.
      'lastDailyBonusMs': d['last_daily_bonus_ms'],
      'lastMemoryRewardMs': d['last_memory_reward_ms'],
      'birthDate': d['birth_date'],
    };
  }

  /// Пропагировать значение в map-поле всех групп пользователя (member_names/
  /// member_avatars[uid]=value) — чтобы партнёры увидели свежее имя/аватар.
  Future<void> updateMemberFieldInGroups(
      String uid, String col, dynamic value) async {
    if (uid.isEmpty) return;
    try {
      final groups = await _pb.collection('groups').getFullList(
            filter: _pb.filter(
                'members ~ {:u} && disbanded = false', {'u': uid}),
          );
      for (final g in groups) {
        await _patchGroupMapField(g.id, col, uid, value);
      }
    } catch (e) {
      debugPrint('PbData.updateMemberFieldInGroups($col) failed: $e');
    }
  }

  /// Обновляет профильные поля users (camelCase→snake_case). id=uid должен
  /// существовать (создаётся при регистрации/импорте, не здесь).
  Future<bool> updateUserProfile(String uid, Map<String, dynamic> data) async {
    if (uid.isEmpty) return false;
    final row = <String, dynamic>{};
    void put(String key, String col, {bool json = false, bool ts = false}) {
      if (!data.containsKey(key)) return;
      final v = data[key];
      row[col] = ts ? _iso(v) : (json ? _jsonSafe(v) : v);
    }

    put('displayName', 'display_name');
    put('avatarUrl', 'avatar_url');
    put('bannerUrl', 'banner_url');
    put('gender', 'gender');
    put('birthDate', 'birth_date', ts: true);
    // ЭКОНОМИКА НЕ ПИШЕТСЯ КЛИЕНТОМ: coins/owned_themes/owned_icons/
    // owned_features/granted_badges и кулдауны ведут ТОЛЬКО серверные коин-роуты
    // (pb_hooks/coins.pb.js через $app.save). Прямой клиентский PATCH этих полей
    // отвергает pb_hooks/users_guard.pb.js. Клиент их только читает (см. UserData).
    put('badge', 'badge'); // выбранный к показу значок (косметика, не владение)
    put('pairId', 'pair_id');
    put('pairIds', 'pair_ids', json: true);
    put('inviteCode', 'invite_code');
    put('fcmToken', 'fcm_token');
    put('fcmTokens', 'fcm_tokens', json: true);
    put('notifMissYou', 'notif_miss_you');
    put('notifNewMemory', 'notif_new_memory');
    put('notifMood', 'notif_mood');
    put('notifChat', 'notif_chat');
    put('soloTimers', 'solo_timers', json: true);
    if (row.isEmpty) return true;
    row['updated_at'] = DateTime.now().toIso8601String();
    return _upsertById('users', uid, row, op: 'updateUserProfile');
  }

  /// Каталог (mood-паки/маскоты): включённые записи нужного типа.
  Future<List<RecordModel>> loadCatalog(String kind) async {
    try {
      return await _pb.collection('catalog_items').getFullList(
            filter: _pb.filter('kind = {:k} && enabled = true', {'k': kind}),
            sort: 'sort',
          );
    } catch (e) {
      debugPrint('PbData.loadCatalog($kind) failed: $e');
      return const [];
    }
  }

  /// Весь включённый каталог (любого типа), отсортированный по `sort`. Чтение
  /// публичное (viewRule/listRule = ''), вход не требуется. Заменяет
  /// чтение `catalog_items` из Supabase в [CatalogService] на cutover.
  Future<List<RecordModel>> loadCatalogAll() async {
    try {
      return await _pb.collection('catalog_items').getFullList(
            filter: 'enabled = true',
            sort: 'sort',
          );
    } catch (e) {
      debugPrint('PbData.loadCatalogAll failed: $e');
      return const [];
    }
  }

  /// Минимально поддерживаемая сборка (force-update) из коллекции `app_config`.
  /// 0 = не блокировать (нет записи / ошибка / пустое поле). Заменяет
  /// `SupabaseService.fetchMinSupportedBuild` на cutover.
  Future<int> fetchMinSupportedBuild() async {
    try {
      final res = await _pb.collection('app_config').getList(perPage: 1);
      if (res.items.isEmpty) return 0;
      final v = res.items.first.data['min_build'];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return 0;
    } catch (e) {
      debugPrint('PbData.fetchMinSupportedBuild failed: $e');
      return 0;
    }
  }

  /// Подарки, полученные участником [uid] в группе [groupId] — новые сверху.
  ///
  /// Возвращает сырые записи: полку из них собирает `tallyGifts`
  /// (`lib/models/partner_profile.dart`). Пустой список при любой ошибке —
  /// профиль партнёра не та страница, ради которой стоит показывать сбой.
  Future<List<Map<String, dynamic>>> fetchGiftsFor({
    required String groupId,
    required String uid,
    int limit = 200,
  }) async {
    if (groupId.isEmpty || uid.isEmpty) return const [];
    try {
      final res = await _pb.collection('gifts').getList(
            perPage: limit,
            filter: 'group_id = "$groupId" && recipient_uid = "$uid"',
            sort: '-created',
          );
      return res.items.map((r) => Map<String, dynamic>.from(r.data)).toList();
    } catch (e) {
      debugPrint('PbData.fetchGiftsFor failed: $e');
      return const [];
    }
  }

  /// Подарки, которые ждут действия получателя [uid] — свежие сверху.
  Future<List<Map<String, dynamic>>> fetchIncomingGifts({
    required String groupId,
    required String uid,
  }) async {
    if (groupId.isEmpty || uid.isEmpty) return const [];
    try {
      final res = await _pb.collection('gifts').getList(
            perPage: 20,
            // deliver_at отсекает письмо, которое ещё летит, и завтрак до утра
            filter: 'group_id = "$groupId" && recipient_uid = "$uid" && '
                'state = "sent" && deliver_at <= ${DateTime.now().millisecondsSinceEpoch}',
            sort: '-created',
          );
      return res.items
          .map((r) => {'id': r.id, ...Map<String, dynamic>.from(r.data)})
          .toList();
    } catch (e) {
      debugPrint('PbData.fetchIncomingGifts failed: $e');
      return const [];
    }
  }

  /// Запись «скучаю» участника [uid]: счётчик и карта дней недели.
  Future<Map<String, dynamic>?> fetchMissYouFor({
    required String groupId,
    required String uid,
  }) async {
    if (groupId.isEmpty || uid.isEmpty) return null;
    try {
      final rec = await _pb.collection('miss_you').getFirstListItem(
            'group_id = "$groupId" && user_uid = "$uid"',
          );
      return Map<String, dynamic>.from(rec.data);
    } catch (e) {
      debugPrint('PbData.fetchMissYouFor failed: $e');
      return null;
    }
  }

  /// Включён ли раздел подарков (поле `gifts_enabled` в той же единственной
  /// записи `app_config`, что и `min_build`).
  ///
  /// false при любой неопределённости — нет записи, нет поля, сбой сети:
  /// выключенный раздел безопаснее раздела, который наполовину работает.
  Future<bool> fetchGiftsEnabled() async {
    try {
      final res = await _pb.collection('app_config').getList(perPage: 1);
      if (res.items.isEmpty) return false;
      return res.items.first.data['gifts_enabled'] == true;
    } catch (e) {
      debugPrint('PbData.fetchGiftsEnabled failed: $e');
      return false;
    }
  }

  /// ISO-строка PB → DateTime (публичный хелпер для слоя моделей на cutover).
  static DateTime? parseDate(dynamic v) => _date(v);
}
