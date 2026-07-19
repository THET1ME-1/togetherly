import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mood_entry.dart';
import '../models/pair_data.dart';
import 'mood_repository.dart';
import 'pocketbase_service.dart';
import 'widget_service.dart';

/// Сервис для управления записями настроений (mood calendar).
///
/// Миграция Firebase→PocketBase (§3): данные живут в плоской коллекции PB
/// `mood_entries` (group_id/user_uid/mood_id/...), доступ — через
/// [MoodRepository] (live SSE + CRUD). На self-hosted PB чтения БЕСПЛАТНЫ, поэтому
/// записи каждого участника читаются ЦЕЛИКОМ live, без месячных документов,
/// legacy-fallback'а, одноразовой миграции и rollover-таймера, которые были нужны
/// лишь ради экономии чтений Firestore. Публичный API сохранён — экраны не меняются.
class MoodService extends ChangeNotifier {
  final MoodRepository _repo = MoodRepository();

  String? get _uid => PocketBaseService().userId;

  // ── Настройка: несколько настроений в день ───────────────────────────────
  // false (по умолчанию) — одно настроение в день: setMoodForToday/ForDate
  // удаляют прежние записи дня перед добавлением. true — каждое настроение
  // сохраняется отдельной записью (как было в ранних версиях).
  static const String _kMultiplePerDayKey = 'mood_allow_multiple_per_day';
  bool _settingsLoaded = false;
  bool _allowMultiplePerDay = false;
  bool get allowMultipleMoodsPerDay => _allowMultiplePerDay;

  String _groupId = '';
  String get groupId => _groupId;

  /// Сервисы для атомарного апдейта всех трёх источников настроения
  /// (calendar entries + group memberMoods + widgetData). Заполняются один раз
  /// при старте через [bindServices]; без них setMoodForToday работает только
  /// с календарём.
  PairData? _pairData;
  WidgetService? _widgetService;

  void bindServices({
    required PairData pairData,
    required WidgetService widgetService,
  }) {
    _pairData = pairData;
    _widgetService = widgetService;
  }

  /// Загружает настройки из SharedPreferences (идемпотентно).
  Future<void> loadSettings() async {
    if (_settingsLoaded) return;
    _settingsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _allowMultiplePerDay = prefs.getBool(_kMultiplePerDayKey) ?? false;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setAllowMultipleMoodsPerDay(bool value) async {
    _settingsLoaded = true;
    _allowMultiplePerDay = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kMultiplePerDayKey, value);
    } catch (_) {}
    notifyListeners();
  }

  // ── Состояние (источник правды — live-стримы PB) ─────────────────────────
  /// Мои записи настроений (плоский отсортированный список — публичный API).
  List<MoodEntry> _myEntries = [];
  List<MoodEntry> get myEntries => List.unmodifiable(_myEntries);
  StreamSubscription<List<MoodEntry>>? _mySub;

  /// Записи партнёров: uid → entries (плоский список) + их подписки.
  final Map<String, List<MoodEntry>> _partnerEntries = {};
  List<MoodEntry> partnerEntries(String uid) =>
      List.unmodifiable(_partnerEntries[uid] ?? []);
  final Map<String, StreamSubscription<List<MoodEntry>>?> _partnerSubs = {};

  // ── Единый источник правды для «сегодняшнего» настроения ─────────────────
  // Все UI (home_header, mini_mood_calendar, mood_calendar_screen, widget_screen)
  // читают через myMoodToday вместо отдельных источников — иначе три источника
  // расходятся и пользователь видит разные эмодзи в разных местах.

  /// Текущее настроение пользователя на сегодня — самая свежая запись
  /// календаря, или null если ещё не выбрано.
  MoodEntry? get myMoodToday {
    final entries = myEntriesForDay(DateTime.now());
    return entries.isNotEmpty ? entries.first : null;
  }

  /// Текущее настроение партнёра на сегодня.
  MoodEntry? partnerMoodToday(String uid) {
    final entries = partnerEntriesForDay(uid, DateTime.now());
    return entries.isNotEmpty ? entries.first : null;
  }

  /// Привязаться к группе и начать слушать.
  void bindToGroup(String groupId) {
    loadSettings();
    if (groupId == _groupId && groupId.isNotEmpty) return;
    unbindFromGroup(notify: false);
    _groupId = groupId;
    _startListening();
  }

  /// Живая подписка на МОИ настроения (вся история по uid, без лимита).
  void _startListening() {
    final uid = _uid;
    if (_groupId.isEmpty || uid == null) return;
    _mySub?.cancel();
    _mySub = _repo.watch(_groupId, uid).listen((entries) {
      _myEntries = entries; // уже отсортированы DESC репозиторием
      notifyListeners();
    });
  }

  /// Живая подписка на настроения конкретного партнёра (вся история).
  void listenToPartner(String partnerUid) {
    if (_groupId.isEmpty || partnerUid.isEmpty) return;
    _partnerSubs[partnerUid]?.cancel();
    _partnerSubs[partnerUid] = _repo.watch(_groupId, partnerUid).listen((entries) {
      _partnerEntries[partnerUid] = entries;
      notifyListeners();
    });
  }

  void unbindFromGroup({bool notify = true}) {
    _mySub?.cancel();
    _mySub = null;
    for (final sub in _partnerSubs.values) {
      sub?.cancel();
    }
    _partnerSubs.clear();
    _groupId = '';
    _myEntries = [];
    _partnerEntries.clear();
    if (notify) {
      notifyListeners();
    }
  }

  /// Добавить настроение.
  /// [date] — если указана, настроение записывается на эту дату (в полдень),
  /// иначе — на текущий момент. Live-подписка покрывает всю историю → запись на
  /// любой день появляется через SSE сама (оптимистичный апдейт не нужен).
  Future<void> addMood({
    required String moodId,
    required String imagePath,
    required String label,
    DateTime? date,
  }) async {
    if (_groupId.isEmpty) return;
    final now = DateTime.now();
    final ts = date != null
        ? DateTime(
            date.year,
            date.month,
            date.day,
            now.hour,
            now.minute,
            now.second,
          )
        : now;
    await _repo.add(
      groupId: _groupId,
      moodId: moodId,
      imagePath: imagePath,
      label: label,
      timestamp: ts,
    );
  }

  /// Установить настроение на сегодня атомарно во всех источниках.
  /// Удаляет старые записи за сегодня (чтобы mini_mood_calendar не циклил
  /// между старыми и новыми эмодзи), пишет новую запись в календарь,
  /// обновляет group memberMoods и widgetData. Единая точка входа для всех
  /// пикеров — гарантирует согласованность header/calendar/widget.
  Future<void> setMoodForToday({
    required String moodId,
    required String imagePath,
    required String label,
  }) async {
    if (_groupId.isEmpty) return;
    final today = DateTime.now();

    // 1. В одиночном режиме удаляем все существующие записи на сегодня. В
    // мультирежиме записи дня сохраняются, новое добавляется отдельной записью.
    if (!_allowMultiplePerDay) {
      final existing = myEntriesForDay(today);
      await Future.wait(existing.map((e) => _repo.delete(e.id)));
    }

    // 2. Календарь — каноничный источник.
    await addMood(moodId: moodId, imagePath: imagePath, label: label);

    // 3. Group memberMoods — для шапки и партнёра.
    await _pairData?.setMood(imagePath, label);

    // 4. WidgetData — для нативного виджета. skipCalendar: уже добавили выше.
    await _widgetService?.updateMood(imagePath, label, skipCalendar: true);
  }

  /// Установить настроение на конкретную дату. Для прошлых дат обновляется
  /// только календарь; для сегодня — все три источника через setMoodForToday.
  Future<void> setMoodForDate({
    required DateTime date,
    required String moodId,
    required String imagePath,
    required String label,
  }) async {
    if (_groupId.isEmpty) return;
    final today = DateTime.now();
    final isToday = date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;

    if (isToday) {
      await setMoodForToday(moodId: moodId, imagePath: imagePath, label: label);
      return;
    }

    // Прошлая дата — только календарь. В одиночном режиме заменяем запись дня,
    // в мультирежиме добавляем ещё одну.
    if (!_allowMultiplePerDay) {
      final existing = myEntriesForDay(date);
      await Future.wait(existing.map((e) => _repo.delete(e.id)));
    }
    await addMood(
      moodId: moodId,
      imagePath: imagePath,
      label: label,
      date: date,
    );
  }

  /// Очистить настроение на сегодня атомарно во всех источниках.
  Future<void> clearMoodForToday() async {
    if (_groupId.isEmpty) return;
    final existing = myEntriesForDay(DateTime.now());
    await Future.wait(existing.map((e) => _repo.delete(e.id)));
    await _pairData?.clearMood();
    await _widgetService?.clearMood();
  }

  /// Очистить настроение на конкретную дату (для прошлых — только календарь).
  Future<void> clearMoodForDate(DateTime date) async {
    if (_groupId.isEmpty) return;
    final today = DateTime.now();
    final isToday = date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;

    if (isToday) {
      await clearMoodForToday();
      return;
    }

    final existing = myEntriesForDay(date);
    await Future.wait(existing.map((e) => _repo.delete(e.id)));
  }

  /// Удалить запись настроения.
  Future<void> deleteMoodEntry(String entryId) async {
    if (_groupId.isEmpty) return;
    await _repo.delete(entryId);
  }

  /// Получить записи за конкретный день (мои).
  List<MoodEntry> myEntriesForDay(DateTime date) {
    final key = _dayKey(date);
    return _myEntries.where((e) => e.dayKey == key).toList();
  }

  /// Получить записи партнёра за конкретный день.
  List<MoodEntry> partnerEntriesForDay(String uid, DateTime date) {
    final key = _dayKey(date);
    final entries = _partnerEntries[uid] ?? [];
    return entries.where((e) => e.dayKey == key).toList();
  }

  /// Количество последовательных дней, когда И я, И все известные партнёры
  /// заполняли настроение подряд (считается назад от сегодня).
  int get bothPartnersStreakDays {
    if (_partnerEntries.isEmpty) return 0;
    final myDays = _myEntries.map((e) => e.dayKey).toSet();
    // Берём дни всех партнёров — если несколько, нужно пересечение
    Set<String>? partnerDays;
    for (final entries in _partnerEntries.values) {
      final days = entries.map((e) => e.dayKey).toSet();
      partnerDays = partnerDays == null ? days : partnerDays.intersection(days);
    }
    if (partnerDays == null || partnerDays.isEmpty) return 0;
    final bothDays = myDays.intersection(partnerDays);
    int streak = 0;
    var day = DateTime.now();
    for (var i = 0; i < 365; i++) {
      final key = _dayKey(day);
      if (!bothDays.contains(key)) break;
      streak++;
      day = day.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// Группировка по дням (мои записи).
  Map<String, List<MoodEntry>> get myEntriesByDay {
    final map = <String, List<MoodEntry>>{};
    for (final e in _myEntries) {
      map.putIfAbsent(e.dayKey, () => []).add(e);
    }
    return map;
  }

  /// Статистика за период: {moodId: count}
  Map<String, int> myStats({required DateTime from, required DateTime to}) {
    final counts = <String, int>{};
    for (final e in _myEntries) {
      if (e.timestamp.isAfter(from) &&
          e.timestamp.isBefore(to.add(const Duration(days: 1)))) {
        counts[e.moodId] = (counts[e.moodId] ?? 0) + 1;
      }
    }
    return counts;
  }

  Map<String, int> partnerStats(
    String uid, {
    required DateTime from,
    required DateTime to,
  }) {
    final entries = _partnerEntries[uid] ?? [];
    final counts = <String, int>{};
    for (final e in entries) {
      if (e.timestamp.isAfter(from) &&
          e.timestamp.isBefore(to.add(const Duration(days: 1)))) {
        counts[e.moodId] = (counts[e.moodId] ?? 0) + 1;
      }
    }
    return counts;
  }

  String _dayKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  @override
  void dispose() {
    unbindFromGroup(notify: false);
    super.dispose();
  }
}
