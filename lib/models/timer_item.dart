import 'dart:convert';

/// Модель одного таймера (счётчик дней/времени с определённой даты).
class TimerItem {
  final String id;
  String title;
  DateTime startDate;
  bool isDefault;
  String emoji;
  bool isSystem; // system timers can't be deleted or renamed
  bool
  isCountdown; // true = countdown timer (days left), false = count up (days elapsed)
  String? backgroundImagePath; // local path to background image (not synced)

  TimerItem({
    required this.id,
    required this.title,
    required this.startDate,
    this.isDefault = false,
    this.emoji = '❤️',
    this.isSystem = false,
    this.isCountdown = false,
    this.backgroundImagePath,
  });

  // ── Вычисляемые значения ──

  int get daysElapsed {
    // Считаем КАЛЕНДАРНЫЕ дни между датами (без учёта времени суток),
    // чтобы совпадать с круговым экраном-лепестком и не «терять» день,
    // когда текущее время ещё не дотянуло до времени старта.
    // Деление часов на 24 с округлением страхует от перехода на летнее время.
    final now = DateTime.now();
    final startDay = DateTime(startDate.year, startDate.month, startDate.day);
    final nowDay = DateTime(now.year, now.month, now.day);
    if (isCountdown) {
      // Countdown: days until target date
      return (startDay.difference(nowDay).inHours / 24).round();
    } else {
      // Count up: days since start date
      return (nowDay.difference(startDay).inHours / 24).round();
    }
  }

  int get monthsElapsed {
    final now = DateTime.now();
    if (isCountdown) {
      // Countdown: months until target date
      int months =
          (startDate.year - now.year) * 12 + startDate.month - now.month;
      if (startDate.day < now.day) months--;
      return months;
    } else {
      // Count up: months since start date
      int months =
          (now.year - startDate.year) * 12 + now.month - startDate.month;
      if (now.day < startDate.day) months--;
      return months;
    }
  }

  Duration get timeElapsed {
    if (isCountdown) {
      return startDate.difference(DateTime.now());
    } else {
      return DateTime.now().difference(startDate);
    }
  }

  String get formattedTime {
    final diff = timeElapsed;
    final d = diff.inDays.abs();
    final h = (diff.inHours.abs() % 24).toString().padLeft(2, '0');
    final m = (diff.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final s = (diff.inSeconds.abs() % 60).toString().padLeft(2, '0');
    return '$d:$h:$m:$s';
  }

  String get formattedStartDate {
    final d = startDate.day.toString().padLeft(2, '0');
    final m = startDate.month.toString().padLeft(2, '0');
    final y = startDate.year.toString();
    final h = startDate.hour;
    final min = startDate.minute;
    if (h == 0 && min == 0) return '$d.$m.$y';
    return '$d.$m.$y  ${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
  }

  // ── Сериализация ──

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'startDate': startDate.toIso8601String(),
    'isDefault': isDefault,
    'emoji': emoji,
    'isSystem': isSystem,
    'isCountdown': isCountdown,
    if (backgroundImagePath != null) 'backgroundImagePath': backgroundImagePath,
  };

  factory TimerItem.fromJson(Map<String, dynamic> json) => TimerItem(
    id: json['id'] as String,
    title: json['title'] as String,
    startDate: DateTime.parse(json['startDate'] as String),
    isDefault: json['isDefault'] as bool? ?? false,
    emoji: json['emoji'] as String? ?? '❤️',
    isSystem: json['isSystem'] as bool? ?? false,
    isCountdown: json['isCountdown'] as bool? ?? false,
    backgroundImagePath: json['backgroundImagePath'] as String?,
  );

  static String encodeList(List<TimerItem> items) =>
      jsonEncode(items.map((e) => e.toJson()).toList());

  static List<TimerItem> decodeList(String source) {
    final list = jsonDecode(source) as List;
    return list
        .map((e) => TimerItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  TimerItem copyWith({
    String? id,
    String? title,
    DateTime? startDate,
    bool? isDefault,
    String? emoji,
    bool? isSystem,
    bool? isCountdown,
    String? backgroundImagePath,
  }) => TimerItem(
    id: id ?? this.id,
    title: title ?? this.title,
    startDate: startDate ?? this.startDate,
    isDefault: isDefault ?? this.isDefault,
    emoji: emoji ?? this.emoji,
    isSystem: isSystem ?? this.isSystem,
    isCountdown: isCountdown ?? this.isCountdown,
    backgroundImagePath: backgroundImagePath ?? this.backgroundImagePath,
  );
}
