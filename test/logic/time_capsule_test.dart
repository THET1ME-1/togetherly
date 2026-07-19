import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/memory.dart';
import 'package:love_app/services/capsule_notification_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Логика «Капсулы времени»: флаги модели переживают сериализацию, запечатанность
// корректно зависит от даты открытия, id уведомления стабилен и в диапазоне.
// ─────────────────────────────────────────────────────────────────────────────

Memory _capsule({DateTime? openAt, bool sealed = true}) => Memory(
      id: 'm1',
      groupId: 'g1',
      authorUid: 'u1',
      authorName: 'Аня',
      type: MemoryType.text,
      createdAt: DateTime(2024, 1, 1),
      caption: 'секрет',
      sealed: sealed,
      openAt: openAt,
    );

void main() {
  group('Memory: флаги капсулы и секрета в сериализации', () {
    test('sealed/openAt/isSecret переживают toJson → fromJson', () {
      final open = DateTime(2030, 6, 1, 9);
      final m = Memory(
        id: 'x',
        groupId: 'g',
        authorUid: 'u',
        authorName: 'n',
        type: MemoryType.photo,
        createdAt: DateTime(2024, 1, 1),
        imageUrl: 'pb://media/1/a.webp',
        caption: 'letter',
        sealed: true,
        openAt: open,
        isSecret: true,
      );

      final round = Memory.fromJson(m.toJson());

      expect(round.sealed, isTrue);
      expect(round.openAt, open);
      expect(round.isSecret, isTrue);
      expect(round.caption, 'letter');
      expect(round.imageUrl, 'pb://media/1/a.webp');
    });

    test('дефолты: не запечатано / не секрет / без openAt', () {
      final m = Memory(
        id: 'x',
        groupId: 'g',
        authorUid: 'u',
        authorName: 'n',
        type: MemoryType.text,
        createdAt: DateTime(2024),
      );
      expect(m.sealed, isFalse);
      expect(m.isSecret, isFalse);
      expect(m.openAt, isNull);

      final r = Memory.fromJson(m.toJson());
      expect(r.sealed, isFalse);
      expect(r.isSecret, isFalse);
      expect(r.openAt, isNull);
    });
  });

  group('Memory.sealedNow / openedCapsuleAt', () {
    final open = DateTime(2030, 1, 1);

    test('до даты — запечатано (не открыто)', () {
      final m = _capsule(openAt: open);
      final before = DateTime(2029, 12, 31, 23, 59);
      expect(m.sealedNow(before), isTrue);
      expect(m.openedCapsuleAt(before), isFalse);
    });

    test('в момент даты и после — открыто (граница = открыта)', () {
      final m = _capsule(openAt: open);
      expect(m.sealedNow(open), isFalse);
      expect(m.openedCapsuleAt(open), isTrue);

      final after = DateTime(2030, 1, 2);
      expect(m.sealedNow(after), isFalse);
      expect(m.openedCapsuleAt(after), isTrue);
    });

    test('не sealed — никогда не запечатано, даже до даты', () {
      final m = _capsule(openAt: open, sealed: false);
      expect(m.sealedNow(DateTime(2029)), isFalse);
      expect(m.openedCapsuleAt(DateTime(2029)), isFalse);
    });

    test('sealed, но openAt == null — не запечатано', () {
      final m = _capsule(openAt: null);
      expect(m.sealedNow(DateTime(2029)), isFalse);
      expect(m.openedCapsuleAt(DateTime(2029)), isFalse);
    });
  });

  group('CapsuleNotificationService.idForMemory', () {
    test('детерминирован, положителен, в диапазоне [100000, 900000)', () {
      final a = CapsuleNotificationService.idForMemory('abc123');
      final b = CapsuleNotificationService.idForMemory('abc123');
      expect(a, b);
      expect(a, greaterThanOrEqualTo(100000));
      expect(a, lessThan(900000));
    });

    test('разные memoryId → разные id; не совпадает с 9991', () {
      final ids = <int>{};
      for (final s in [
        'a',
        'b',
        'c',
        'mem_1',
        'mem_2',
        'xyz',
        'pb_9f8',
        'together',
      ]) {
        final id = CapsuleNotificationService.idForMemory(s);
        expect(id, isNot(9991));
        ids.add(id);
      }
      expect(ids.length, greaterThan(6));
    });
  });
}
