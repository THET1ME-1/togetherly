import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sembast/sembast_memory.dart';

import 'package:love_app/models/chat_msg.dart';
import 'package:love_app/models/comment.dart';
import 'package:love_app/models/mood_entry.dart';
import 'package:love_app/services/offline/local_store.dart';
import 'package:love_app/services/offline/media_cache.dart';
import 'package:love_app/services/offline/record_scope.dart';

/// Сборка «сырой» записи `memories` (как кладёт кэш/сеть).
RecordModel mem(
  String id,
  String g, {
  bool deleted = false,
  String updated = '2026-01-01 00:00:00.000Z',
}) =>
    RecordModel.fromJson({
      'id': id,
      'group_id': g,
      'deleted': deleted,
      'created': updated,
      'updated': updated,
      'data': {'id': id, 'caption': 'c-$id', 'type': 'text'},
    });

void main() {
  group('RecordScope', () {
    test('equals: совпадение и расхождение', () {
      final s = RecordScope('t', equals: {'group_id': 'g1', 'deleted': false});
      expect(s.matches({'group_id': 'g1', 'deleted': false}), isTrue);
      expect(s.matches({'group_id': 'g2', 'deleted': false}), isFalse);
      expect(s.matches({'group_id': 'g1', 'deleted': true}), isFalse);
    });

    test('contains: членство в списке (members ~ uid)', () {
      final s = RecordScope('t', contains: {'members': 'u1'});
      expect(s.matches({'members': ['u1', 'u2']}), isTrue);
      expect(s.matches({'members': ['u2']}), isFalse);
      expect(s.matches({'members': 'not-a-list'}), isFalse);
    });
  });

  group('LocalStore', () {
    final store = LocalStore.instance;
    final memScope = RecordScope('memories:g=g1',
        equals: {'group_id': 'g1', 'deleted': false});

    setUp(() async {
      await store.initWith(databaseFactoryMemory, 'test_pb_cache.db');
      await store.clearAll(); // свежая БД на каждый тест
    });

    test('upsert + getScope фильтрует по области', () async {
      await store.upsert('memories', mem('m1', 'g1'));
      await store.upsert('memories', mem('m2', 'g1'));
      await store.upsert('memories', mem('m3', 'g2')); // другая группа
      await store.upsert('memories', mem('m4', 'g1', deleted: true)); // надгробие

      final got = await store.getScope('memories', memScope);
      expect(got.map((r) => r.id).toSet(), {'m1', 'm2'});
    });

    test('deleteRecord убирает из кэша', () async {
      await store.upsert('memories', mem('m1', 'g1'));
      await store.deleteRecord('memories', 'm1');
      final got = await store.getScope('memories', memScope);
      expect(got, isEmpty);
    });

    test('reconcileScope: добавляет, обновляет и удаляет осиротевшие в области',
        () async {
      await store.upsert('memories', mem('m1', 'g1'));
      await store.upsert('memories', mem('m2', 'g1'));
      await store.upsert('memories', mem('keepOther', 'g2'));

      // Сервер вернул m1 (обновл.) и m3; m2 на сервере нет → должно удалиться.
      await store.reconcileScope('memories', memScope, [
        mem('m1', 'g1', updated: '2026-02-02 00:00:00.000Z'),
        mem('m3', 'g1'),
      ]);

      final inScope = await store.getScope('memories', memScope);
      expect(inScope.map((r) => r.id).toSet(), {'m1', 'm3'});
      // Чужая область не тронута.
      final other = await store.getRecord('memories', 'keepOther');
      expect(other, isNotNull);
    });

    test('reconcileScope: protectIds спасает не-отправленный локальный create',
        () async {
      await store.upsert('memories', mem('local1', 'g1')); // создан офлайн
      await store.reconcileScope('memories', memScope, [mem('srv1', 'g1')],
          protectIds: {'local1'});
      final inScope = await store.getScope('memories', memScope);
      expect(inScope.map((r) => r.id).toSet(), {'local1', 'srv1'});
    });

    test('водяной знак: set/bump монотонны', () async {
      const t = 'memories:g=g1';
      expect(await store.lastUpdated(t), isNull);
      await store.setLastUpdated(t, '2026-01-01 00:00:00.000Z');
      expect(await store.lastUpdated(t), '2026-01-01 00:00:00.000Z');
      await store.bumpWatermark(t, '2026-03-03 00:00:00.000Z'); // вперёд
      expect(await store.lastUpdated(t), '2026-03-03 00:00:00.000Z');
      await store.bumpWatermark(t, '2026-02-02 00:00:00.000Z'); // назад — игнор
      expect(await store.lastUpdated(t), '2026-03-03 00:00:00.000Z');
    });

    test('ensureOwner: смена владельца чистит кэш', () async {
      await store.upsert('memories', mem('m1', 'g1'));
      await store.ensureOwner('userA');
      expect((await store.getScope('memories', memScope)).length, 1);

      await store.ensureOwner('userB'); // другой пользователь → очистка
      expect(await store.getScope('memories', memScope), isEmpty);

      // Тот же владелец повторно — данные не трогаются.
      await store.upsert('memories', mem('m2', 'g1'));
      await store.ensureOwner('userB');
      expect((await store.getScope('memories', memScope)).length, 1);
    });

    test('clearAll очищает всё', () async {
      await store.upsert('memories', mem('m1', 'g1'));
      await store.setLastUpdated('memories:g=g1', '2026-01-01 00:00:00.000Z');
      await store.clearAll();
      expect(await store.getScope('memories', memScope), isEmpty);
      expect(await store.lastUpdated('memories:g=g1'), isNull);
    });
  });

  // Контракт: ряд, который кладёт в кэш репозиторий (snake_case колонки), должен
  // попадать в свою область и корректно парситься соответствующим fromPb.
  group('Фаза 2b: формы кэш-рядов ↔ scope/fromPb', () {
    final store = LocalStore.instance;
    setUp(() async {
      await store.initWith(databaseFactoryMemory, 'test_pb_cache.db');
      await store.clearAll();
    });

    test('mood: ряд матчит scope и парсится MoodEntry.fromPb', () async {
      await store.upsertRaw('mood_entries', 'mm1', {
        'id': 'mm1',
        'group_id': 'g1',
        'user_uid': 'u1',
        'mood_id': 'happy',
        'image_path': 'p.webp',
        'label': 'Счастье',
        'timestamp': '2026-01-01T00:00:00.000Z',
      });
      final scope = RecordScope('moods:g=g1:u=u1',
          equals: {'group_id': 'g1', 'user_uid': 'u1'});
      final got = await store.getScope('mood_entries', scope);
      expect(got.length, 1);
      final e = MoodEntry.fromPb(got.first);
      expect(e.id, 'mm1');
      expect(e.moodId, 'happy');
    });

    test('chat: ряд матчит scope и парсится ChatMsg.fromPb', () async {
      await store.upsertRaw('chat_messages', 'c1', {
        'id': 'c1',
        'group_id': 'g1',
        'user_uid': 'u1',
        'user_name': 'A',
        'text': 'привет',
        'ts': 1700000000000,
        'deleted': false,
      });
      final scope = RecordScope('chat:g=g1', equals: {'group_id': 'g1'});
      final got = await store.getScope('chat_messages', scope);
      expect(got.length, 1);
      final m = ChatMsg.fromPb(got.first);
      expect(m.uid, 'u1');
      expect(m.text, 'привет');
      expect(m.ts, 1700000000000);
    });

    test('comment: ряд матчит scope и парсится MemoryComment.fromPb', () async {
      await store.upsertRaw('memory_comments', 'k1', {
        'id': 'k1',
        'group_id': 'g1',
        'memory_id': 'mem1',
        'deleted': false,
        'author_uid': 'u1',
        'author_name': 'A',
        'author_avatar': '',
        'text': 'комм',
        'created_at': '2026-01-01T00:00:00.000Z',
      });
      final scope = RecordScope('comments:m=mem1',
          equals: {'memory_id': 'mem1', 'deleted': false});
      final got = await store.getScope('memory_comments', scope);
      expect(got.length, 1);
      final c = MemoryComment.fromPb(got.first);
      expect(c.authorUid, 'u1');
      expect(c.text, 'комм');
    });
  });

  group('Фаза 4: MediaCache', () {
    test('isLocalRef/localPath', () {
      final mc = MediaCache.instance;
      expect(mc.isLocalRef('localfile:///a/b.webp'), isTrue);
      expect(mc.isLocalRef('pb://media/x/y.webp'), isFalse);
      expect(mc.isLocalRef(null), isFalse);
      expect(mc.localPath('localfile:///a/b.webp'), '/a/b.webp');
      expect(mc.localPath('pb://x'), isNull);
    });

    test('deepReplaceRefs: подмена ссылки рекурсивно (список + вложенность)', () {
      final data = {
        'imageUrl': 'localfile:///x/a.webp',
        'imageUrls': ['localfile:///x/a.webp', 'pb://media/keep/k.webp'],
        'nested': {'musicUrl': 'localfile:///x/a.webp'},
        'caption': 'текст',
      };
      final changed = MediaCache.deepReplaceRefs(
          data, 'localfile:///x/a.webp', 'pb://media/1/a.webp');
      expect(changed, isTrue);
      expect(data['imageUrl'], 'pb://media/1/a.webp');
      expect((data['imageUrls'] as List)[0], 'pb://media/1/a.webp');
      expect((data['imageUrls'] as List)[1], 'pb://media/keep/k.webp'); // не тронут
      expect((data['nested'] as Map)['musicUrl'], 'pb://media/1/a.webp');
      expect(data['caption'], 'текст');
    });

    test('deepReplaceRefs: нет совпадения → false', () {
      final data = {'imageUrl': 'pb://media/x/y.webp'};
      expect(
          MediaCache.deepReplaceRefs(data, 'localfile:///z', 'pb://q'), isFalse);
    });
  });
}
