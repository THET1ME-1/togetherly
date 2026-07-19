import 'dart:async';

import 'analytics_service.dart';
import 'pb_data_service.dart';
import 'pb_realtime_service.dart';
import 'pocketbase_service.dart';
import 'rate_limiter_service.dart';

/// Репозиторий «Я скучаю» / вайбов поверх PocketBase (миграция §3).
///
/// Заменяет RTDB-счётчик + Firestore `missYouEvents` (push-триггер). На PB всё
/// живёт в коллекции `miss_you` (count + last_vibe + last_vibe_text), а пуш
/// партнёру шлёт [PbPushService] по SSE-дельте этой строки (рост count).
///
/// ВАЖНОЕ ПОВЕДЕНЧЕСКОЕ ОТЛИЧИЕ от Firebase: вайбы (thinking_of_you/want_hug/
/// custom) ТЕПЕРЬ инкрементят счётчик. Раньше sendVibe был push-only и счётчик
/// не трогал. На PB пуш дедуплицируется по росту count, поэтому инкремент —
/// именно то, что заставляет уведомление повторно сработать.
class MissYouRepository {
  MissYouRepository._();
  static final MissYouRepository instance = MissYouRepository._();
  factory MissYouRepository() => instance;

  final PbDataService _data = PbDataService();
  final PbRealtimeService _rt = PbRealtimeService();

  String? get _uid => PocketBaseService().userId;

  /// Живой словарь {uid: count} по группе.
  Stream<Map<String, int>> watchCounts(String groupId) =>
      _rt.watchMissYou(groupId);

  /// Тап «Я скучаю»: +1 в счётчик. Без рейт-лимита (как было). Аналитика.
  Future<void> sendMissYou(String groupId) async {
    final uid = _uid;
    if (uid == null || groupId.isEmpty) return;
    final ok = await _data.incrementMissYou(groupId, uid, vibe: 'miss_you');
    if (ok) unawaited(AnalyticsService.instance.logMissYouSent());
  }

  /// Вайб (думаю о тебе / хочу обнять / custom). Рейт-лимит как прежде:
  /// [RateLimiterService.checkVibe] бросает [RateLimitException] ДО записи —
  /// исключение пробрасывается наружу (UI ловит). Инкрементит счётчик (см. док
  /// класса) + пишет last_vibe/last_vibe_text для текста пуша.
  Future<void> sendVibe({
    required String groupId,
    required String vibeType,
    String? customText,
  }) async {
    final uid = _uid;
    if (uid == null || groupId.isEmpty) return;
    await RateLimiterService().checkVibe(); // бросит RateLimitException при лимите
    final ok = await _data.incrementMissYou(
      groupId,
      uid,
      vibe: vibeType,
      text: customText,
    );
    if (ok) {
      unawaited(RateLimiterService().recordVibe());
      unawaited(AnalyticsService.instance.logVibeSent(vibeType: vibeType));
    }
  }
}
