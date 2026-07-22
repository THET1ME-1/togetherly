/// Подарки, которые меняют приложение получателя на время.
///
/// Эффект живёт в профиле получателя отдельным полем со сроком (epoch ms):
/// сервер выставляет его при отклике, клиент проверяет при каждом запуске.
/// Хранить в подарке нельзя — эффект нужен экранам, которые про подарки не
/// знают вовсе.
enum GiftEffectKind {
  /// До восьми утра: тихая ночь, утренний рассвет.
  untilMorning,

  /// Фиксированный срок от момента отклика.
  fixed,
}

class GiftEffect {
  const GiftEffect({
    required this.field,
    required this.kind,
    this.duration = const Duration(hours: 24),
  });

  /// Поле в профиле пользователя, где лежит срок действия.
  final String field;

  final GiftEffectKind kind;

  /// Для [GiftEffectKind.fixed] — сколько эффект длится.
  final Duration duration;
}

const Map<String, GiftEffect> _effects = {
  'night': GiftEffect(field: 'mute_until', kind: GiftEffectKind.untilMorning),
  'sun': GiftEffect(field: 'sunrise_until', kind: GiftEffectKind.untilMorning),
  'spa': GiftEffect(field: 'spa_until', kind: GiftEffectKind.fixed),
  'fire': GiftEffect(field: 'streak_shield_until', kind: GiftEffectKind.fixed),
};

GiftEffect? effectOf(String giftKey) => _effects[giftKey];

/// Активен ли эффект: [untilMs] — срок из профиля, [now] — текущее время.
bool isEffectActive(int? untilMs, DateTime now) {
  if (untilMs == null || untilMs <= 0) return false;
  return untilMs > now.millisecondsSinceEpoch;
}

/// Ближайшее восемь утра. До восьми — сегодняшнее, после — завтрашнее.
///
/// Ночной подарок, отправленный в час ночи, должен догореть этим же утром, а
/// не через сутки; дневной — дожить до следующего.
DateTime untilMorning(DateTime from) {
  final todayMorning = DateTime(from.year, from.month, from.day, 8);
  if (from.isBefore(todayMorning)) return todayMorning;
  final tomorrow = from.add(const Duration(days: 1));
  return DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 8);
}
