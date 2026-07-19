import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sembast/sembast_io.dart';

import 'record_scope.dart';

/// Локальное офлайн-хранилище (sembast) — «домашняя копия» данных PocketBase
/// прямо на устройстве (offline-first).
///
/// Модель: PB-записи — это JSON-документы (`{id, ...колонки, data:{...}}`).
/// sembast — чистый Dart NoSQL-стор документов, поэтому кладём `rec.toJson()`
/// КАК ЕСТЬ (id + system-поля `created`/`updated` + индексные колонки + json
/// `data`), а восстанавливаем `RecordModel.fromJson(map)` — round-trip lossless,
/// и все `Model.fromPb(RecordModel)` продолжают работать без изменений.
///
/// Одна sembast-«таблица» (store) на коллекцию PB: `col_<collection>`, ключ =
/// id записи. Предикаты области (scope) считаем В DART (см. [RecordScope]) —
/// данных у пары немного, это проще и надёжнее вложенных sembast-фильтров.
///
/// fail-open: если БД не открылась — методы становятся no-op/пустыми, и
/// приложение работает как раньше (онлайн, без кэша), не падая.
class LocalStore {
  LocalStore._();
  static final LocalStore instance = LocalStore._();
  factory LocalStore() => instance;

  static const int _dbVersion = 1;

  Database? _db;
  Completer<void>? _opening;
  DatabaseFactory? _factory;
  String? _path;

  StoreRef<String, Map<String, Object?>> _col(String collection) =>
      stringMapStoreFactory.store('col_$collection');

  /// Водяные знаки дельта-синхронизации: token области → {updated, fullSyncAt}.
  StoreRef<String, Map<String, Object?>> get _meta =>
      stringMapStoreFactory.store('sync_meta');

  bool get isReady => _db != null;

  /// Низкоуровневый доступ к открытой БД (для очереди отправки, живущей в том же
  /// файле БД). Гарантирует, что БД открыта.
  Future<Database?> database() async {
    await init();
    return _db;
  }

  /// ТОЛЬКО для тестов: открыть на переданной фабрике (напр. in-memory), без
  /// path_provider. Последующие init() — no-op (БД уже открыта).
  @visibleForTesting
  Future<void> initWith(DatabaseFactory factory, String path) async {
    if (_db != null) return;
    _factory = factory;
    _path = path;
    _db = await factory.openDatabase(path, version: _dbVersion);
  }

  /// Открывает БД (идемпотентно). Параллельные вызовы ждут один и тот же future.
  Future<void> init() async {
    if (_db != null) return;
    final pending = _opening;
    if (pending != null) return pending.future;
    final c = Completer<void>();
    _opening = c;
    try {
      final dir = await getApplicationSupportDirectory();
      final folder = Directory('${dir.path}/offline');
      if (!await folder.exists()) await folder.create(recursive: true);
      _factory = databaseFactoryIo;
      _path = '${folder.path}/pb_cache.db';
      _db = await _factory!.openDatabase(_path!, version: _dbVersion);
      debugPrint('LocalStore: открыт $_path');
    } catch (e) {
      debugPrint('LocalStore.init failed (работаем без кэша): $e');
      _db = null; // fail-open
    } finally {
      c.complete();
      _opening = null;
    }
  }

  // ── чтение ────────────────────────────────────────────────────────────────
  /// Реактивный поток записей области: пере-эмитит при ЛЮБОМ изменении кэша
  /// (оптимистичная запись / дельта / сверка). [compare] сортирует снапшот
  /// (как в [PbRealtimeService]). Это и есть «единственный источник» для UI.
  Stream<List<RecordModel>> watchScope(
    String collection,
    RecordScope scope, {
    int Function(RecordModel, RecordModel)? compare,
  }) async* {
    await init();
    final db = _db;
    if (db == null) {
      yield const [];
      return;
    }
    yield* _col(collection).query().onSnapshots(db).map(
          (snaps) => _materialize(snaps, scope, compare),
        );
  }

  /// Разовая выборка записей области из кэша.
  Future<List<RecordModel>> getScope(
    String collection,
    RecordScope scope, {
    int Function(RecordModel, RecordModel)? compare,
  }) async {
    await init();
    final db = _db;
    if (db == null) return const [];
    final snaps = await _col(collection).find(db);
    return _materialize(snaps, scope, compare);
  }

  /// Реактивный одиночный документ по id (delete → null).
  Stream<RecordModel?> watchRecord(String collection, String id) async* {
    await init();
    final db = _db;
    if (db == null) {
      yield null;
      return;
    }
    yield* _col(collection).record(id).onSnapshot(db).map(
          (snap) =>
              snap == null ? null : RecordModel.fromJson(_copy(snap.value)),
        );
  }

  Future<RecordModel?> getRecord(String collection, String id) async {
    await init();
    final db = _db;
    if (db == null) return null;
    final v = await _col(collection).record(id).get(db);
    return v == null ? null : RecordModel.fromJson(_copy(v));
  }

  /// Все записи коллекции (без фильтра по области) — для обслуживающих обходов
  /// (напр. подмена localfile://→pb:// в медиа после отложенной заливки).
  Future<List<RecordModel>> allRecords(String collection) async {
    await init();
    final db = _db;
    if (db == null) return const [];
    final snaps = await _col(collection).find(db);
    return snaps.map((s) => RecordModel.fromJson(_copy(s.value))).toList();
  }

  List<RecordModel> _materialize(
    List<RecordSnapshot<String, Map<String, Object?>>> snaps,
    RecordScope scope,
    int Function(RecordModel, RecordModel)? compare,
  ) {
    final list = <RecordModel>[];
    for (final s in snaps) {
      final map = _copy(s.value);
      if (scope.matches(map)) list.add(RecordModel.fromJson(map));
    }
    if (compare != null) list.sort(compare);
    return list;
  }

  // ── запись (используется realtime-сверкой, SSE-дельтами и очередью) ─────────
  /// Вставить/обновить запись (из сети или оптимистично).
  Future<void> upsert(String collection, RecordModel rec) =>
      upsertRaw(collection, rec.id, rec.toJson());

  Future<void> upsertRaw(
    String collection,
    String id,
    Map<String, dynamic> data,
  ) async {
    await init();
    final db = _db;
    if (db == null || id.isEmpty) return;
    await _col(collection).record(id).put(db, _sanitize(data));
  }

  Future<void> deleteRecord(String collection, String id) async {
    await init();
    final db = _db;
    if (db == null || id.isEmpty) return;
    await _col(collection).record(id).delete(db);
  }

  /// Оптимистичная правка одной записи map-поля (member_moods[uid] и т.п.).
  /// value==null → удалить ключ. Нет записи → создаёт частичную {id, field}.
  Future<void> patchRecordMapEntry(
    String collection,
    String id,
    String field,
    String key,
    dynamic value,
  ) async {
    await init();
    final db = _db;
    if (db == null || id.isEmpty) return;
    final cur = await _col(collection).record(id).get(db);
    final row = cur != null ? _copy(cur) : <String, dynamic>{'id': id};
    final m = row[field] is Map
        ? Map<String, dynamic>.from(row[field] as Map)
        : <String, dynamic>{};
    if (value == null) {
      m.remove(key);
    } else {
      m[key] = value;
    }
    row[field] = m;
    await _col(collection).record(id).put(db, _sanitize(row));
  }

  /// Оптимистичная правка набора колонок записи (current_status, active_mascot_id,
  /// mascot_position_* …). Нет записи → создаёт частичную.
  Future<void> patchRecordFields(
    String collection,
    String id,
    Map<String, dynamic> cols,
  ) async {
    await init();
    final db = _db;
    if (db == null || id.isEmpty) return;
    final cur = await _col(collection).record(id).get(db);
    final row = cur != null ? _copy(cur) : <String, dynamic>{'id': id};
    row.addAll(cols);
    await _col(collection).record(id).put(db, _sanitize(row));
  }

  /// Применить дельту (изменившиеся/новые записи) — точечный upsert. Мягко
  /// удалённые приезжают сюда же как upsert с `deleted=true`; из ленты их
  /// прячет [RecordScope] (scope с `deleted=false`).
  Future<void> applyDelta(String collection, List<RecordModel> changed) async {
    await init();
    final db = _db;
    if (db == null || changed.isEmpty) return;
    await db.transaction((txn) async {
      final store = _col(collection);
      for (final r in changed) {
        await store.record(r.id).put(txn, _sanitize(r.toJson()));
      }
    });
  }

  /// ПОЛНАЯ сверка области (для нечастого «обновить всё» / маленьких коллекций):
  /// upsert всех серверных записей + удаление локальных строк ВНУТРИ области,
  /// которых на сервере нет (пропущенные жёсткие удаления). [protectIds] спасает
  /// строки с ещё не отправленным локальным create от удаления сверкой.
  Future<void> reconcileScope(
    String collection,
    RecordScope scope,
    List<RecordModel> serverRecords, {
    Set<String> protectIds = const {},
  }) async {
    await init();
    final db = _db;
    if (db == null) return;
    await db.transaction((txn) async {
      final store = _col(collection);
      final serverIds = <String>{};
      for (final r in serverRecords) {
        serverIds.add(r.id);
        await store.record(r.id).put(txn, _sanitize(r.toJson()));
      }
      final locals = await store.find(txn);
      for (final s in locals) {
        if (serverIds.contains(s.key) || protectIds.contains(s.key)) continue;
        if (scope.matches(_copy(s.value))) {
          await store.record(s.key).delete(txn);
        }
      }
    });
  }

  // ── водяные знаки дельта-синхронизации ──────────────────────────────────────
  /// Последний известный `updated` для области (ISO). null — ни разу не
  /// синхронизировались (нужна первая страница/полная загрузка).
  Future<String?> lastUpdated(String token) async {
    await init();
    final db = _db;
    if (db == null) return null;
    final m = await _meta.record(token).get(db);
    return m?['updated'] as String?;
  }

  Future<void> setLastUpdated(String token, String updated) async {
    await init();
    final db = _db;
    if (db == null) return;
    await _meta.record(token).put(db, {'updated': updated}, merge: true);
  }

  /// Поднять водяной знак ТОЛЬКО вперёд (для SSE-дельт: не откатываем назад).
  Future<void> bumpWatermark(String token, String updated) async {
    await init();
    final db = _db;
    if (db == null || updated.isEmpty) return;
    final cur = (await _meta.record(token).get(db))?['updated'] as String?;
    if (cur == null || updated.compareTo(cur) > 0) {
      await _meta.record(token).put(db, {'updated': updated}, merge: true);
    }
  }

  // ── инвалидация (logout / смена пользователя) ──────────────────────────────
  /// Полная очистка кэша — ОБЯЗАТЕЛЬНА при выходе/смене пользователя, иначе
  /// новый юзер увидит данные предыдущего.
  Future<void> clearAll() async {
    await init();
    final db = _db;
    final f = _factory;
    final p = _path;
    if (db == null || f == null || p == null) return;
    try {
      // Удаляем файл БД и переоткрываем чистым (той же фабрикой — IO в проде,
      // in-memory в тестах) — надёжнее ручного обхода всех стораджей.
      await db.close();
      _db = null;
      await f.deleteDatabase(p);
      _db = await f.openDatabase(p, version: _dbVersion);
    } catch (e) {
      debugPrint('LocalStore.clearAll failed: $e');
    }
  }

  /// Привязывает кэш к владельцу [uid]. Если владелец сменился (другой uid) —
  /// полностью чистит кэш (защита от утечки данных между аккаунтами на одном
  /// устройстве, в т.ч. при «тихой» смене аккаунта без явного logout). Пустой
  /// uid (не вошёл) — no-op.
  Future<void> ensureOwner(String? uid) async {
    if (uid == null || uid.isEmpty) return;
    await init();
    var db = _db;
    if (db == null) return;
    final cur = (await _meta.record('_owner').get(db))?['uid'] as String?;
    if (cur != null && cur != uid) {
      await clearAll(); // другой пользователь → стираем всё (clearAll переоткрывает БД)
      db = _db;
      if (db == null) return;
    }
    await _meta.record('_owner').put(db, {'uid': uid}, merge: true);
  }

  // ── утилиты ────────────────────────────────────────────────────────────────
  /// Свежая мутабельная копия снапшота sembast (его значения иммутабельны).
  static Map<String, dynamic> _copy(Map<String, Object?> v) =>
      Map<String, dynamic>.from(v);

  /// Гарантирует JSON-совместимость значения для sembast (DateTime→ISO,
  /// рекурсивно по Map/List) — на случай оптимистичных карт с `DateTime`.
  static Map<String, dynamic> _sanitize(Map<String, dynamic> input) =>
      _clean(input) as Map<String, dynamic>;

  static dynamic _clean(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toIso8601String();
    if (v is Map) {
      return v.map((k, val) => MapEntry(k.toString(), _clean(val)));
    }
    if (v is List) return v.map(_clean).toList();
    return v; // String / num / bool
  }
}
