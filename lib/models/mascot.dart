import 'package:pocketbase/pocketbase.dart';
import 'package:love_app/services/locale_service.dart';
import 'level.dart';

enum MascotMoodState { happy, sad, verySad }

/// One mascot in the group gallery.
class Mascot {
  final String id;
  String name;

  /// Remote URL (Firebase Storage) for user-drawn mascots. Null for defaults.
  final String? imageUrl;

  /// Asset path for default company mascots. Null for user-drawn.
  final String? defaultAsset;

  /// Public CDN URL for catalog mascots (Supabase bucket `catalog`). Эти маскоты
  /// приходят из удалённого каталога, рендерятся напрямую по публичному URL
  /// (CachedNetworkImage, НЕ signed-URL StorageImage) и НЕ пишутся в Firestore
  /// группы — добавляются в галерею «поверх». Null для всех остальных.
  final String? catalogUrl;

  /// Английское имя каталожного маскота (для localizedName). Null для остальных.
  final String? nameEn;

  /// Требование разблокировки (для каталожных). Бандл/рисованные — всегда free.
  final Unlock unlock;

  final String createdBy;
  final DateTime createdAt;
  final bool isDefault;

  /// Maximum streak days while this mascot was active (all-time record).
  int recordStreak;

  Mascot({
    required this.id,
    required this.name,
    this.imageUrl,
    this.defaultAsset,
    this.catalogUrl,
    this.nameEn,
    this.unlock = const Unlock.free(),
    required this.createdBy,
    required this.createdAt,
    this.isDefault = false,
    this.recordStreak = 0,
  });

  /// Маскот из удалённого каталога (рендер-онли, не сохраняется в Firestore).
  /// isDefault=true → как встроенные: можно активировать, нельзя
  /// редактировать/удалять/переименовывать.
  factory Mascot.fromCatalog({
    required String id,
    required String nameRu,
    required String nameEn,
    required String url,
    Unlock unlock = const Unlock.free(),
  }) =>
      Mascot(
        id: id,
        name: nameRu,
        nameEn: nameEn,
        catalogUrl: url,
        unlock: unlock,
        createdBy: 'catalog',
        createdAt: DateTime(2024),
        isDefault: true,
      );

  bool get isCatalog => catalogUrl != null;

  bool get hasImage =>
      imageUrl != null || defaultAsset != null || catalogUrl != null;

  /// Returns the locale-aware name for built-in mascots; falls back to [name] for user-created ones.
  String get localizedName {
    if (isCatalog) {
      return LocaleService.instance.isRussian ? name : (nameEn ?? name);
    }
    if (!isDefault) return name;
    final s = LocaleService.current;
    switch (id) {
      case 'default_boy': return s.mascotBoyName;
      case 'default_girl': return s.mascotGirlName;
      case 'default_spiky': return s.mascotSpikyName;
      case 'default_lulu': return s.mascotLuluName;
      case 'default_iskrik': return s.mascotIskrikName;
      case 'default_zhuzha': return s.mascotZhuzhaName;
      default: return name;
    }
  }

  /// PocketBase-запись (коллекция `mascots`) → модель. id маскота лежит в
  /// колонке `mascot_id` (rec.id — это авто-id PB). Пустые text-поля PB отдаёт
  /// как `''` → коэрсим в null, иначе `hasImage` ложно-true для дефолтных.
  factory Mascot.fromPb(RecordModel rec) {
    final d = rec.data;
    String? nz(dynamic v) =>
        (v == null || (v is String && v.isEmpty)) ? null : v.toString();
    return Mascot(
      id: (d['mascot_id'] ?? '').toString(),
      name: (d['name'] ?? '').toString(),
      imageUrl: nz(d['image_url']),
      defaultAsset: nz(d['default_asset']),
      createdBy: (d['created_by'] ?? '').toString(),
      createdAt:
          DateTime.tryParse((d['created_at'] ?? '').toString()) ?? DateTime.now(),
      isDefault: d['is_default'] == true,
      recordStreak: (d['record_streak'] as num?)?.toInt() ?? 0,
    );
  }

  Mascot copyWith({String? name, String? imageUrl, int? recordStreak}) {
    return Mascot(
      id: id,
      name: name ?? this.name,
      imageUrl: imageUrl ?? this.imageUrl,
      defaultAsset: defaultAsset,
      createdBy: createdBy,
      createdAt: createdAt,
      isDefault: isDefault,
      recordStreak: recordStreak ?? this.recordStreak,
    );
  }
}

/// Shared mascot state synced via the group document.
class GroupMascotState {
  final String? activeMascotId;
  final double positionX; // 0.0–1.0 relative to screen width
  final double positionY; // 0.0–1.0 relative to screen height
  final double scale;
  final int streakDays;
  final String? streakLastOpenedDate; // "YYYY-MM-DD" local time

  /// Серия КАЖДОГО маскота: {mascot_id: {s: серия, d: "YYYY-MM-DD" посл. общего дня}}.
  /// Серия растёт когда оба партнёра зашли за день, привязана к активному маскоту;
  /// пропуск дня → маскот «умирает» (см. [streakFor]).
  final Map<String, dynamic> mascotStreaks;

  /// Общий опыт пары (растёт за действия). Уровень/ранг выводятся из него.
  final int xp;

  const GroupMascotState({
    this.activeMascotId,
    this.positionX = 0.8,
    this.positionY = 0.7,
    this.scale = 1.0,
    this.streakDays = 0,
    this.streakLastOpenedDate,
    this.mascotStreaks = const {},
    this.xp = 0,
  });

  /// Текущая серия конкретного маскота. Если последний общий день — НЕ сегодня и
  /// не вчера, маскот «умер» → 0 (серия начнётся заново при следующем общем дне).
  int streakFor(String? mascotId) {
    if (mascotId == null || mascotId.isEmpty) return 0;
    final e = mascotStreaks[mascotId];
    if (e is! Map) return 0;
    final s = (e['s'] as num?)?.toInt() ?? 0;
    final d = e['d']?.toString();
    if (d == null || d.isEmpty || s <= 0) return 0;
    final today = _localDateStr(DateTime.now());
    final yesterday =
        _localDateStr(DateTime.now().subtract(const Duration(days: 1)));
    return (d == today || d == yesterday) ? s : 0;
  }

  /// Серия активного маскота (то, что показываем на главной/виджете).
  int get activeStreak => streakFor(activeMascotId);

  /// Computes the current mood based on when anyone last opened the app.
  MascotMoodState get moodState {
    if (streakLastOpenedDate == null) return MascotMoodState.sad;
    final today = _localDateStr(DateTime.now());
    final yesterday = _localDateStr(
      DateTime.now().subtract(const Duration(days: 1)),
    );
    if (streakLastOpenedDate == today || streakLastOpenedDate == yesterday) {
      return MascotMoodState.happy;
    }
    final lastDate = DateTime.tryParse(streakLastOpenedDate!);
    if (lastDate == null) return MascotMoodState.sad;
    final diff = DateTime.now().difference(lastDate).inDays;
    return diff > 3 ? MascotMoodState.verySad : MascotMoodState.sad;
  }

  static String _localDateStr(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  factory GroupMascotState.fromMap(Map<String, dynamic> data) {
    return GroupMascotState(
      activeMascotId: data['activeMascotId'] as String?,
      positionX: (data['mascotPositionX'] as num?)?.toDouble() ?? 0.8,
      positionY: (data['mascotPositionY'] as num?)?.toDouble() ?? 0.7,
      scale: (data['mascotScale'] as num?)?.toDouble() ?? 1.0,
      streakDays: (data['streakDays'] as num?)?.toInt() ?? 0,
      streakLastOpenedDate: data['streakLastOpenedDate'] as String?,
      xp: (data['xp'] as num?)?.toInt() ?? 0,
    );
  }

  /// Состояние маскота из group-дока PocketBase (snake_case колонки).
  ///
  /// ВАЖНО: number-колонки PB не nullable и дефолтят в 0 (в отличие от Firestore,
  /// где поле отсутствовало → срабатывал `?? default`). Поэтому для групп без
  /// заданной позиции/масштаба сырое значение = 0, что дало бы scale=0
  /// (НЕВИДИМЫЙ маскот) и позицию в углу (0,0). Трактуем неположительное как
  /// «не задано» → дефолты (0.8/0.7/1.0). Побочно: позицию ровно 0 и масштаб 0
  /// задать нельзя — оба вырожденные, никем не нужны. Пустые text-колонки
  /// PB ('') коэрсим в null. (§8: при импорте можно засеять явные значения.)
  factory GroupMascotState.fromPb(RecordModel rec) {
    final d = rec.data;
    String? nz(dynamic v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    final px = (d['mascot_position_x'] as num?)?.toDouble() ?? 0.0;
    final py = (d['mascot_position_y'] as num?)?.toDouble() ?? 0.0;
    final sc = (d['mascot_scale'] as num?)?.toDouble() ?? 0.0;
    return GroupMascotState(
      activeMascotId: nz(d['active_mascot_id']),
      positionX: px > 0 ? px : 0.8,
      positionY: py > 0 ? py : 0.7,
      scale: sc > 0 ? sc : 1.0,
      streakDays: (d['streak_days'] as num?)?.toInt() ?? 0,
      streakLastOpenedDate: nz(d['streak_last_opened_date']),
      mascotStreaks: d['mascot_streaks'] is Map
          ? Map<String, dynamic>.from(d['mascot_streaks'] as Map)
          : const {},
      xp: (d['xp'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
    'activeMascotId': activeMascotId,
    'mascotPositionX': positionX,
    'mascotPositionY': positionY,
    'mascotScale': scale,
    'streakDays': streakDays,
    'streakLastOpenedDate': streakLastOpenedDate,
    'xp': xp,
  };

  GroupMascotState copyWith({
    String? activeMascotId,
    double? positionX,
    double? positionY,
    double? scale,
    int? streakDays,
    String? streakLastOpenedDate,
    Map<String, dynamic>? mascotStreaks,
    int? xp,
    bool clearActiveMascot = false,
  }) {
    return GroupMascotState(
      activeMascotId: clearActiveMascot
          ? null
          : (activeMascotId ?? this.activeMascotId),
      positionX: positionX ?? this.positionX,
      positionY: positionY ?? this.positionY,
      scale: scale ?? this.scale,
      streakDays: streakDays ?? this.streakDays,
      streakLastOpenedDate: streakLastOpenedDate ?? this.streakLastOpenedDate,
      mascotStreaks: mascotStreaks ?? this.mascotStreaks,
      xp: xp ?? this.xp,
    );
  }
}

/// The default mascots bundled with the app.
///
/// Только два бесплатных стартовых маскота сидируются в галерею. Остальные
/// (включая маскотов-наград «за уровень») приходят из удалённого каталога
/// (Supabase) и добавляются БЕЗ обновления приложения — см. CatalogService.
class DefaultMascots {
  static const String _base = 'assets/images/mascots';

  static List<Map<String, String>> get entries => [
    {
      'id': 'default_boy',
      'name': 'Пиксик',
      'asset': '$_base/Веселый мальчик.png',
    },
    {
      'id': 'default_girl',
      'name': 'Пикси',
      'asset': '$_base/Веселая девочка.png',
    },
  ];

  static List<Mascot> asMascots() {
    return entries
        .map(
          (e) => Mascot(
            id: e['id']!,
            name: e['name']!,
            defaultAsset: e['asset'],
            createdBy: 'system',
            createdAt: DateTime(2024),
            isDefault: true,
          ),
        )
        .toList();
  }
}
