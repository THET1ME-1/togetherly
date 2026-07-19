import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/pair_achievement.dart';
import 'pb_realtime_service.dart';

/// Достижения пары. Разблокировка — чистая функция от уже синкающихся счётчиков
/// group-дока (`start_date`, `memories_count`, `streak_days`, `drawings_count`,
/// `messages_count`), поэтому оба устройства вычисляют ОДИНАКОВЫЙ набор без
/// отдельного серверного хранилища. Локально храним лишь «что уже отпраздновали»
/// (дедуп тоста) — по образцу флагов сессии в других сервисах.
///
/// Слушает [PbRealtimeService.watchGroup]; на каждый апдейт группы пересчитывает
/// [AchievementStats] и, если пороги перейдены, шлёт разблокированные достижения
/// в [unlocks] (UI показывает праздничный оверлей). Живой снимок счётчиков —
/// в [stats] (для экрана-сетки).
class AchievementService {
  AchievementService._();
  static final AchievementService instance = AchievementService._();

  final PbRealtimeService _rt = PbRealtimeService();

  StreamSubscription<RecordModel?>? _groupSub;
  String? _groupId;

  /// Разблокированные «сейчас» достижения для празднования. Broadcast: слушает
  /// экран с оверлеем.
  final StreamController<PairAchievement> _unlockCtrl =
      StreamController<PairAchievement>.broadcast();
  Stream<PairAchievement> get unlocks => _unlockCtrl.stream;

  /// Живой снимок счётчиков пары (для экрана достижений — прогресс/статусы).
  final ValueNotifier<AchievementStats> stats =
      ValueNotifier<AchievementStats>(const AchievementStats());

  /// id уже обработанных (отпразднованных/бэкфилл) достижений текущей группы —
  /// дедуп, чтобы тост не повторялся при каждом апдейте группы и после рестарта.
  final Set<String> _seen = <String>{};
  bool _initialized = false; // первый снимок группы = «тихий» бэкфилл

  String get _seenKey => 'ach_seen_${_groupId ?? ''}';

  /// Запускает слежение за достижениями пары [groupId]. Идемпотентно.
  Future<void> start(String groupId) async {
    if (groupId.isEmpty) {
      await stop();
      return;
    }
    if (_groupId == groupId && _groupSub != null) return;
    await stop();
    _groupId = groupId;
    _initialized = false;
    _seen
      ..clear()
      ..addAll(await _loadSeen());
    _groupSub = _rt.watchGroup(groupId).listen(
          _onGroup,
          onError: (e) => debugPrint('AchievementService watch error: $e'),
        );
  }

  Future<void> stop() async {
    await _groupSub?.cancel();
    _groupSub = null;
    _groupId = null;
    _initialized = false;
    _seen.clear();
  }

  void _onGroup(RecordModel? rec) {
    if (rec == null) return;
    final snapshot = _statsFrom(rec.data);
    stats.value = snapshot;

    final earned =
        PairAchievement.all.where((a) => a.isUnlockedBy(snapshot)).toList();
    final fresh = earned.where((a) => !_seen.contains(a.id)).toList();
    if (fresh.isEmpty) {
      _initialized = true;
      return;
    }

    // Первый снимок группы в сессии = бэкфилл уже заработанного: помечаем как
    // виденное БЕЗ праздника (иначе существующая пара при обновлении приложения
    // получила бы шквал тостов за давно достигнутое).
    final backfill = !_initialized;
    for (final a in fresh) {
      _seen.add(a.id);
      if (!backfill) _unlockCtrl.add(a);
    }
    _initialized = true;
    unawaited(_saveSeen());
  }

  AchievementStats _statsFrom(Map<String, dynamic> d) {
    int i(String k) => (d[k] as num?)?.toInt() ?? 0;
    return AchievementStats(
      daysTogether: _daysSince(d['start_date']),
      memories: i('memories_count'),
      messages: i('messages_count'),
      drawings: i('drawings_count'),
      streakDays: i('streak_days'),
    );
  }

  /// Дней с даты старта пары. Принимает ISO-строку или epoch-ms.
  int _daysSince(dynamic raw) {
    DateTime? start;
    if (raw is String && raw.isNotEmpty) {
      start = DateTime.tryParse(raw);
    } else if (raw is num) {
      start = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    }
    if (start == null) return 0;
    final days = DateTime.now().difference(start).inDays;
    return days < 0 ? 0 : days;
  }

  Future<Set<String>> _loadSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_seenKey) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _saveSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_seenKey, _seen.toList());
    } catch (_) {}
  }
}
