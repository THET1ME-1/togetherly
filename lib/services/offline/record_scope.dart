/// Описание «области» (scope) набора записей в локальном кэше — локальный
/// эквивалент серверного PB-фильтра из [PbRealtimeService].
///
/// Зачем: realtime-обёртки (`watchMemories`, `watchMoods`, …) строят серверный
/// фильтр строкой (`group_id = {:g} && deleted = false`). Для офлайн-кэша нам
/// нужен тот же предикат, но вычисляемый ЛОКАЛЬНО над сохранённой записью —
/// чтобы (а) реактивно отдавать из кэша только записи нужной области и
/// (б) при сверке удалять «осиротевшие» строки только внутри своей области.
///
/// [token] — стабильный человекочитаемый идентификатор области. Им же
/// помечается «водяной знак» инкрементальной синхронизации (sync_meta), чтобы
/// уже загруженное не тянулось повторно.
class RecordScope {
  /// Стабильный ключ области, напр. `memories:g=<gid>:deleted=false`.
  final String token;

  /// Поля, которые должны точно совпасть (колонка → требуемое значение).
  final Map<String, Object?> equals;

  /// Поля-списки, которые должны СОДЕРЖАТЬ значение (колонка → элемент).
  /// Покрывает PB-оператор `~` для members (`members ~ uid`).
  final Map<String, String> contains;

  const RecordScope(
    this.token, {
    this.equals = const {},
    this.contains = const {},
  });

  /// Входит ли «сырая» запись PB (`rec.toJson()`, snake_case-колонки) в область.
  bool matches(Map<String, dynamic> rec) {
    for (final e in equals.entries) {
      if (rec[e.key] != e.value) return false;
    }
    for (final c in contains.entries) {
      final v = rec[c.key];
      if (v is! List || !v.map((e) => e.toString()).contains(c.value)) {
        return false;
      }
    }
    return true;
  }
}
