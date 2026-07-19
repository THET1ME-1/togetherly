import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/memory.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Pure filter helpers — mirrors the logic from _MemoryLaneScreenState
// ─────────────────────────────────────────────────────────────────────────────

/// Filter memories by exact day (month + day) across all years.
List<Memory> filterByDay(List<Memory> all, DateTime now) {
  return all
      .where(
        (m) => m.createdAt.month == now.month && m.createdAt.day == now.day,
      )
      .toList();
}

/// Filter memories by month across all years.
List<Memory> filterByMonth(List<Memory> all, DateTime now) {
  return all.where((m) => m.createdAt.month == now.month).toList();
}

/// Group memories by year (string key), sorted newest first.
Map<String, List<Memory>> groupByYear(List<Memory> memories) {
  final sorted = [...memories]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final Map<String, List<Memory>> grouped = {};
  for (final m in sorted) {
    grouped.putIfAbsent('${m.createdAt.year}', () => []).add(m);
  }
  return grouped;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper to build a Memory quickly
// ─────────────────────────────────────────────────────────────────────────────
Memory _mem(String id, DateTime createdAt, {bool isPinned = false}) {
  return Memory(
    id: id,
    groupId: 'g1',
    authorUid: 'u1',
    authorName: 'Alice',
    type: MemoryType.photo,
    createdAt: createdAt,
    isPinned: isPinned,
  );
}

void main() {
  // ── filterByDay ──────────────────────────────────────────────────────────────
  group('filterByDay', () {
    // Fixed "today" for deterministic tests
    final today = DateTime(2026, 4, 10);

    final memories = [
      _mem('same-day-2026', DateTime(2026, 4, 10, 9, 0)),
      _mem('same-day-2025', DateTime(2025, 4, 10, 18, 30)),
      _mem('same-day-2024', DateTime(2024, 4, 10, 0, 0)),
      _mem('diff-month', DateTime(2026, 3, 10)),
      _mem('diff-day', DateTime(2026, 4, 11)),
      _mem('completely-off', DateTime(2023, 1, 1)),
    ];

    test('includes memories from same month+day in different years', () {
      final result = filterByDay(memories, today);
      final ids = result.map((m) => m.id).toSet();
      expect(
        ids,
        containsAll(['same-day-2026', 'same-day-2025', 'same-day-2024']),
      );
    });

    test('excludes memories with different month', () {
      final result = filterByDay(memories, today);
      expect(result.map((m) => m.id), isNot(contains('diff-month')));
    });

    test('excludes memories with different day', () {
      final result = filterByDay(memories, today);
      expect(result.map((m) => m.id), isNot(contains('diff-day')));
    });

    test('excludes completely unrelated memories', () {
      final result = filterByDay(memories, today);
      expect(result.map((m) => m.id), isNot(contains('completely-off')));
    });

    test('returns exactly 3 memories', () {
      final result = filterByDay(memories, today);
      expect(result.length, 3);
    });

    test('returns empty list when no match', () {
      final result = filterByDay([
        _mem('m', DateTime(2025, 6, 15)),
      ], DateTime(2026, 4, 10));
      expect(result, isEmpty);
    });

    test('includes pinned and non-pinned equally', () {
      final mixed = [
        _mem('pinned', DateTime(2026, 4, 10), isPinned: true),
        _mem('not-pinned', DateTime(2026, 4, 10), isPinned: false),
      ];
      final result = filterByDay(mixed, today);
      expect(result.length, 2);
    });
  });

  // ── filterByMonth ────────────────────────────────────────────────────────────
  group('filterByMonth', () {
    final april = DateTime(2026, 4, 10);

    final memories = [
      _mem('apr-2026-1', DateTime(2026, 4, 1)),
      _mem('apr-2026-30', DateTime(2026, 4, 30)),
      _mem('apr-2025', DateTime(2025, 4, 15)),
      _mem('apr-2024', DateTime(2024, 4, 8)),
      _mem('mar-2026', DateTime(2026, 3, 31)),
      _mem('may-2026', DateTime(2026, 5, 1)),
      _mem('jan-2020', DateTime(2020, 1, 1)),
    ];

    test('includes all April memories across years', () {
      final result = filterByMonth(memories, april);
      final ids = result.map((m) => m.id).toSet();
      expect(
        ids,
        containsAll(['apr-2026-1', 'apr-2026-30', 'apr-2025', 'apr-2024']),
      );
    });

    test('excludes March', () {
      final result = filterByMonth(memories, april);
      expect(result.map((m) => m.id), isNot(contains('mar-2026')));
    });

    test('excludes May', () {
      final result = filterByMonth(memories, april);
      expect(result.map((m) => m.id), isNot(contains('may-2026')));
    });

    test('returns exactly 4 memories', () {
      final result = filterByMonth(memories, april);
      expect(result.length, 4);
    });

    test('returns empty when no match', () {
      final result = filterByMonth([
        _mem('m', DateTime(2025, 7, 10)),
      ], DateTime(2026, 4, 10));
      expect(result, isEmpty);
    });
  });

  // ── groupByYear ──────────────────────────────────────────────────────────────
  group('groupByYear', () {
    test('groups by year string key', () {
      final memories = [
        _mem('a', DateTime(2026, 4, 10)),
        _mem('b', DateTime(2025, 4, 10)),
        _mem('c', DateTime(2024, 4, 10)),
      ];
      final grouped = groupByYear(memories);
      expect(grouped.keys, containsAll(['2026', '2025', '2024']));
    });

    test('multiple memories in same year grouped together', () {
      final memories = [
        _mem('a', DateTime(2026, 4, 10)),
        _mem('b', DateTime(2026, 4, 8)),
        _mem('c', DateTime(2025, 4, 10)),
      ];
      final grouped = groupByYear(memories);
      expect(grouped['2026']!.length, 2);
      expect(grouped['2025']!.length, 1);
    });

    test('within a year, sorted newest first', () {
      final memories = [
        _mem('old', DateTime(2026, 4, 1)),
        _mem('new', DateTime(2026, 4, 30)),
      ];
      final grouped = groupByYear(memories);
      expect(grouped['2026']!.first.id, 'new');
      expect(grouped['2026']!.last.id, 'old');
    });

    test('empty list returns empty map', () {
      expect(groupByYear([]), isEmpty);
    });

    test('single memory produces single-entry map', () {
      final grouped = groupByYear([_mem('x', DateTime(2025, 6, 15))]);
      expect(grouped.length, 1);
      expect(grouped['2025']!.length, 1);
    });
  });

  // ── Combined pipeline: filterByDay + groupByYear ───────────────────────────
  group('filterByDay + groupByYear pipeline', () {
    final today = DateTime(2026, 4, 10);

    final allMemories = [
      _mem('a2026', DateTime(2026, 4, 10, 10, 0)),
      _mem('a2025', DateTime(2025, 4, 10, 9, 0)),
      _mem('a2024', DateTime(2024, 4, 10, 20, 0)),
      _mem('unrelated', DateTime(2026, 5, 5)),
    ];

    test('pipeline produces correct years and counts', () {
      final filtered = filterByDay(allMemories, today);
      final grouped = groupByYear(filtered);

      expect(grouped.keys, containsAll(['2026', '2025', '2024']));
      expect(grouped['2026']!.length, 1);
      expect(grouped['2025']!.length, 1);
      expect(grouped['2024']!.length, 1);
      expect(grouped.containsKey('2026'), isTrue);
      // unrelated not present
      final allIds = grouped.values.expand((l) => l).map((m) => m.id).toSet();
      expect(allIds, isNot(contains('unrelated')));
    });
  });
}
