import 'dart:async';

import 'pb_data_service.dart';
import 'pb_realtime_service.dart';
import 'pocketbase_service.dart';

/// Приглашение к совместному сеансу (co-watch) поверх PocketBase (миграция §3).
///
/// Живёт json-полем `groups.active_session`; доставляется live-подпиской на
/// group-док (ноль доп. чтений). ВАЖНО: это только ПРИГЛАШЕНИЕ — сам плеер/
/// презенс (TogetherSessionService) пока на RTDB и переедет на PB heartbeat+TTL
/// отдельным срезом.
class TogetherInviteRepository {
  TogetherInviteRepository._();
  static final TogetherInviteRepository instance = TogetherInviteRepository._();
  factory TogetherInviteRepository() => instance;

  final PbDataService _data = PbDataService();
  final PbRealtimeService _rt = PbRealtimeService();

  String? get _uid => PocketBaseService().userId;

  /// Live-поток активного приглашения группы (null — нет сеанса).
  Stream<Map<String, dynamic>?> watch(String groupId) =>
      _rt.watchActiveSession(groupId);

  /// Объявить активный сеанс (вызывает хост). hostUid — текущий PB-юзер,
  /// startedAt — клиентский ISO (PB без serverTimestamp).
  Future<void> set(
    String groupId, {
    required String activity,
    required String mediaId,
    required String hostName,
  }) =>
      _data.setActiveSession(groupId, {
        'activity': activity,
        'mediaId': mediaId,
        'hostUid': _uid ?? '',
        'hostName': hostName,
        'startedAt': DateTime.now().toIso8601String(),
      });

  Future<void> clear(String groupId) => _data.clearActiveSession(groupId);
}
