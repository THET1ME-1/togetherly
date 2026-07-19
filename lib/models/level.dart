import 'package:flutter/material.dart';
import '../services/locale_service.dart';

/// Чистая модель уровней/рангов ПАРЫ. Level и Rank выводятся из общего XP и
/// нигде не хранятся — кривую/ранги/цвета можно менять без миграции данных.
///
/// XP — один групповой счётчик (растёт как memoriesCount, дуал-райт). Здесь
/// только математика и справочники; накопление XP — в LevelService.

/// Шаг кривой: XP, нужный чтобы из уровня L шагнуть в L+1, = kXpStep·L.
/// Накопительно до уровня L: kXpStep·L·(L−1)/2.
const int kXpStep = 100;

/// Накопленный XP, нужный чтобы ДОСТИЧЬ [level] (level 1 = 0).
int xpForLevel(int level) {
  if (level <= 1) return 0;
  return kXpStep * level * (level - 1) ~/ 2;
}

/// Текущий уровень по накопленному [xp].
int levelForXp(int xp) {
  if (xp <= 0) return 1;
  var level = 1;
  while (xpForLevel(level + 1) <= xp) {
    level++;
  }
  return level;
}

/// Снимок прогресса для UI (полоска опыта, номер уровня, ранг).
class LevelProgress {
  final int xp;
  final int level;

  /// XP, набранный ВНУТРИ текущего уровня.
  final int xpIntoLevel;

  /// XP на весь шаг текущий→следующий уровень.
  final int xpForNext;

  final Rank rank;

  const LevelProgress({
    required this.xp,
    required this.level,
    required this.xpIntoLevel,
    required this.xpForNext,
    required this.rank,
  });

  /// 0..1 — заполнение полоски до следующего уровня.
  double get progress =>
      xpForNext <= 0 ? 1.0 : (xpIntoLevel / xpForNext).clamp(0.0, 1.0);

  factory LevelProgress.fromXp(int xp) {
    final safeXp = xp < 0 ? 0 : xp;
    final level = levelForXp(safeXp);
    final base = xpForLevel(level);
    final next = xpForLevel(level + 1);
    return LevelProgress(
      xp: safeXp,
      level: level,
      xpIntoLevel: safeXp - base,
      xpForNext: next - base,
      rank: Rank.forLevel(level),
    );
  }
}

/// Ранг — группа уровней с именем и цветом бордера. Позже добавим [frameAsset]
/// (рисованная рамка) — UI отрисует её вместо цветного кольца.
class Rank {
  final int minLevel;
  final String _nameRu;
  final String _nameEn;
  final Color color;
  final String? frameAsset;

  const Rank({
    required this.minLevel,
    required String nameRu,
    required String nameEn,
    required this.color,
    this.frameAsset,
  })  : _nameRu = nameRu,
        _nameEn = nameEn;

  String get name => LocaleService.instance.isRussian ? _nameRu : _nameEn;

  /// Ранги по возрастанию minLevel. Добавить ранг = одна строка.
  static const List<Rank> all = [
    Rank(minLevel: 1, nameRu: 'Знакомство', nameEn: 'Acquaintance', color: Color(0xFF9CA3AF)),
    Rank(minLevel: 3, nameRu: 'Симпатия', nameEn: 'Affection', color: Color(0xFF22C55E)),
    Rank(minLevel: 6, nameRu: 'Влюблённость', nameEn: 'Infatuation', color: Color(0xFFEC4899)),
    Rank(minLevel: 10, nameRu: 'Гармония', nameEn: 'Harmony', color: Color(0xFFA855F7)),
    Rank(minLevel: 15, nameRu: 'Крепкая связь', nameEn: 'Strong Bond', color: Color(0xFF3B82F6)),
    Rank(minLevel: 20, nameRu: 'Родственные души', nameEn: 'Soulmates', color: Color(0xFFF59E0B)),
  ];

  static Rank forLevel(int level) {
    var result = all.first;
    for (final r in all) {
      if (level >= r.minLevel) {
        result = r;
      } else {
        break;
      }
    }
    return result;
  }
}

/// Тип требования для разблокировки элемента каталога.
enum UnlockType { free, level, premium }

/// УНИВЕРСАЛЬНОЕ требование разблокировки — на любом элементе каталога
/// (маскот, пак настроений, в будущем темы/рамки). Один механизм для всего.
class Unlock {
  final UnlockType type;

  /// Требуемый уровень (для [UnlockType.level]).
  final int requiredLevel;

  const Unlock.free()
      : type = UnlockType.free,
        requiredLevel = 0;
  const Unlock.level(this.requiredLevel) : type = UnlockType.level;
  const Unlock.premium()
      : type = UnlockType.premium,
        requiredLevel = 0;

  /// Разобрать поле `unlock` из манифеста каталога. null/неизвестное → free.
  factory Unlock.fromJson(Map<String, dynamic>? json) {
    switch (json?['type']) {
      case 'level':
        return Unlock.level((json!['level'] as num?)?.toInt() ?? 1);
      case 'premium':
        return const Unlock.premium();
      default:
        return const Unlock.free();
    }
  }

  bool get isFree => type == UnlockType.free;
  bool get isPremium => type == UnlockType.premium;

  /// Открыт ли элемент при текущем [level] пары и факте покупки [owned].
  bool isUnlocked({required int level, required bool owned}) {
    switch (type) {
      case UnlockType.free:
        return true;
      case UnlockType.level:
        return level >= requiredLevel;
      case UnlockType.premium:
        return owned;
    }
  }
}
