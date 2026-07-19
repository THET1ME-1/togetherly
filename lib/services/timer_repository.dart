import 'dart:async';

import '../models/timer_item.dart';
import 'pb_data_service.dart';
import 'pb_realtime_service.dart';
import 'pocketbase_service.dart';

/// Репозиторий таймеров поверх PocketBase (миграция §3).
///
/// Групповые таймеры — json-массив в `groups.timers` (live через подписку на
/// group-док); соло — `users.solo_timers`. [TimerService] работает с моделями
/// [TimerItem]. Фоны таймеров (картинки) — медиа §4, остаются на вызывающем.
class TimerRepository {
  TimerRepository._();
  static final TimerRepository instance = TimerRepository._();
  factory TimerRepository() => instance;

  final PbDataService _data = PbDataService();
  final PbRealtimeService _rt = PbRealtimeService();

  String? get _uid => PocketBaseService().userId;

  /// Живой список групповых таймеров. `watchGroup` шлёт весь group-док при ЛЮБОМ
  /// изменении → де-дуп по сырому значению `timers`, чтобы не гонять merge на
  /// несвязанные изменения (mood/status/...). ПЕРВЫЙ снапшот эмитится всегда —
  /// от него зависит `_hasReceivedRemoteSync`/отложенный системный таймер.
  Stream<List<TimerItem>> watchGroupTimers(String groupId) {
    String? prevSig;
    return _rt
        .watchGroup(groupId)
        .map((rec) => rec?.data['timers'])
        .where((raw) {
      final sig = raw?.toString() ?? '';
      if (sig == prevSig) return false;
      prevSig = sig;
      return true;
    }).map((raw) => raw is List
            ? raw
                .map((e) => TimerItem.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList()
            : <TimerItem>[]);
  }

  Future<void> saveGroupTimers(String groupId, List<TimerItem> timers) =>
      _data.setGroupTimers(groupId, timers.map((t) => t.toJson()).toList());

  Future<void> upsertGroupTimer(String groupId, TimerItem timer) =>
      _data.upsertGroupTimer(groupId, timer.toJson());

  Future<void> deleteGroupTimer(String groupId, String timerId) =>
      _data.deleteGroupTimer(groupId, timerId);

  Future<void> setDefaultGroupTimer(String groupId, String timerId) =>
      _data.setDefaultGroupTimer(groupId, timerId);

  // ── Соло-таймеры (users.solo_timers) ──────────────────────────────────────
  Future<List<Map<String, dynamic>>?> loadSoloTimers() async {
    final uid = _uid;
    if (uid == null) return null;
    return _data.loadSoloTimers(uid);
  }

  Future<void> saveSoloTimers(List<TimerItem> timers) async {
    final uid = _uid;
    if (uid == null) return;
    await _data.saveSoloTimers(uid, timers.map((t) => t.toJson()).toList());
  }
}
