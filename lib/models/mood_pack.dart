import 'package:flutter/material.dart';
import '../services/locale_service.dart';
import 'level.dart';
import 'mood_entry.dart';

/// Набор настроений («пак») — например классические эмодзи или розовые каваи.
///
/// Настроение хранит в записи свой [MoodOption.imagePath], поэтому партнёр
/// видит выбранную картинку независимо от того, какой пак выбран у него. Выбор
/// пака — это только то, из какого набора пользователь выбирает у себя
/// (хранится локально в [MoodPackService]).
class MoodPack {
  /// Идентификатор пака (для сохранения выбора).
  final String id;

  /// Бесплатные паки доступны всем без покупки. Pink и Classic — бесплатные.
  /// Флаг оставлен ради будущих платных паков.
  final bool isFree;

  /// Настроения пака (порядок = порядок в пикере).
  final List<MoodOption> moods;

  /// Мягкая подложка под прозрачными стикерами в пикере (от/до для градиента).
  /// null — картинки пака непрозрачные (классические), фон не нужен.
  final List<Color>? tileGradient;

  final String _nameRu;
  final String _nameEn;

  /// Требование разблокировки (для каталожных паков). Встроенные — free.
  final Unlock unlock;

  const MoodPack({
    required this.id,
    required this.isFree,
    required this.moods,
    required String nameRu,
    required String nameEn,
    this.tileGradient,
    this.unlock = const Unlock.free(),
  })  : _nameRu = nameRu,
        _nameEn = nameEn;

  String get name => LocaleService.instance.isRussian ? _nameRu : _nameEn;

  /// Картинка для превью пака в селекторе (первое настроение).
  String get previewImage => moods.isNotEmpty ? moods.first.imagePath : '';

  // ── Каталог ────────────────────────────────────────────────────────────────

  static const MoodPack classic = MoodPack(
    id: 'classic',
    isFree: true,
    nameRu: 'Классические',
    nameEn: 'Classic',
    moods: MoodOption.all,
  );

  static const MoodPack pink = MoodPack(
    id: 'pink',
    isFree: true,
    nameRu: 'Розовые',
    nameEn: 'Pink',
    moods: MoodOption.pinkPack,
    tileGradient: [Color(0xFFFFF2F8), Color(0xFFFFDCEC)],
  );

  static const List<MoodPack> all = [classic, pink];

  /// Пак по id; неизвестный/`null` → классический (безопасный дефолт).
  static MoodPack byId(String? id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return classic;
  }
}
