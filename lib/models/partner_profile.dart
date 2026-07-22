import 'dart:convert';

import 'gift.dart';

/// Сколько раз партнёру дарили один и тот же подарок.
class GiftTally {
  const GiftTally(this.gift, this.count);

  final Gift gift;
  final int count;

  String get key => gift.key;
}

/// Полка подарков: одинаковые сложены вместе, частые — впереди.
///
/// [records] — записи коллекции `gifts` как есть, с полем `gift_key`.
/// Подарок, которого нет в каталоге (запись от новой версии приложения),
/// пропускается: показать его всё равно нечем.
List<GiftTally> tallyGifts(List<Map<String, dynamic>> records) {
  final counts = <String, int>{};
  for (final r in records) {
    final key = (r['gift_key'] ?? '').toString();
    if (key.isEmpty || GiftCatalog.byKey(key) == null) continue;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final out = counts.entries
      .map((e) => GiftTally(GiftCatalog.byKey(e.key)!, e.value))
      .toList();
  out.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    // при равенстве — порядок каталога, чтобы полка не прыгала между заходами
    return byCount != 0 ? byCount : _catalogIndex(a.key) - _catalogIndex(b.key);
  });
  return out;
}

int _catalogIndex(String key) =>
    GiftCatalog.all.indexWhere((g) => g.key == key);

/// «Я скучаю» в разрезе дней недели.
class WeekStats {
  const WeekStats(this.byDay);

  /// Семь чисел, начиная с понедельника.
  final List<int> byDay;

  int get total => byDay.fold(0, (s, v) => s + v);

  bool get isEmpty => total == 0;

  /// День недели с максимумом (1 = понедельник). При равенстве — более ранний.
  /// null, если истории ещё нет.
  int? get topDay {
    if (isEmpty) return null;
    var best = 0;
    for (var i = 1; i < byDay.length; i++) {
      if (byDay[i] > byDay[best]) best = i;
    }
    return best + 1;
  }
}

/// Разбирает поле `by_weekday` записи `miss_you`: карта «день → количество».
///
/// История копится с релиза: у пар, заведённых раньше, поле пустое, и экран
/// честно показывает, что данных пока нет.
WeekStats parseWeekdays(String? raw) {
  final days = List<int>.filled(7, 0);
  if (raw == null || raw.trim().isEmpty) return WeekStats(days);
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      decoded.forEach((k, v) {
        final day = int.tryParse(k.toString());
        final count = v is num ? v.toInt() : int.tryParse(v.toString());
        if (day == null || count == null || day < 1 || day > 7) return;
        days[day - 1] = count;
      });
    }
  } catch (_) {
    return WeekStats(List<int>.filled(7, 0));
  }
  return WeekStats(days);
}
