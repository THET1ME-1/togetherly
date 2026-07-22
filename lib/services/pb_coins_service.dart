import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'pocketbase_service.dart';

/// Исход разовой dev-выдачи. Нужен, чтобы вызывающий отличал окончательный
/// отказ сервера (не разработчик → больше не спрашивать) от транзиентного сбоя
/// (сеть/сессия → можно повторить позже).
enum DevCoinsResult { ok, denied, retry }

class DevCoinsOutcome {
  final DevCoinsResult result;
  final Map<String, dynamic>? data;
  const DevCoinsOutcome(this.result, this.data);
}

/// Клиент серверной коин-логики PocketBase (миграция §6 — замена вызовов
/// Firebase Cloud Functions `callGrant*`/`callPurchase*`/`callSpendCoins`).
///
/// POST'ит на pb_hooks-роуты `/api/coins/*` с auth-токеном текущего PB-юзера
/// (SDK сам подставляет Authorization из authStore). Сервер валидирует
/// цены/кулдауны/лимиты и возвращает ту же форму, что Cloud Functions
/// (`{ok, coins, awarded?, ownedThemes?, ...}`) → `UserData._applyServerResult`
/// читает результат без изменений.
///
/// IAP (`iap-purchase`) — на PB-хуке: whitelist productId + идемпотентность по
/// purchaseToken (как в прежней Firebase-функции, реальной Play-валидации нет).
/// НЕ покрыто: AdMob SSV-callback (нужна серверная проверка подписи AdMob).
class PbCoinsService {
  PbCoinsService._();
  static final PbCoinsService instance = PbCoinsService._();
  factory PbCoinsService() => instance;

  Future<Map<String, dynamic>?> _call(
    String path, [
    Map<String, dynamic> body = const {},
  ]) async {
    try {
      final res = await PocketBaseService().pb.send(
        '/api/coins/$path',
        method: 'POST',
        body: body,
      );
      return res is Map ? Map<String, dynamic>.from(res) : null;
    } catch (e, st) {
      debugPrint('PbCoins.$path failed: $e');
      // Коины = деньги пользователя: сбой начисления/покупки/списания репортим
      // (warning — часть это штатные 4xx вроде cooldown/insufficient, но дешевле
      // отфильтровать в панели, чем пропустить реальный сбой экономики).
      unawaited(Sentry.captureException(e, stackTrace: st, withScope: (s) {
        s.setExtra('reason', 'coins route /api/coins/$path failed');
        s.level = SentryLevel.warning;
      }));
      return null;
    }
  }

  Future<Map<String, dynamic>?> dailyBonus() => _call('daily-bonus');
  Future<Map<String, dynamic>?> memoryReward() => _call('memory-reward');
  Future<Map<String, dynamic>?> adReward() => _call('ad-reward');

  /// Разовая dev-выдача. НЕ через [_call]: тот схлопывает любую ошибку в null,
  /// из-за чего не-разработчики (403) ретраили вызов на каждом lifecycle-событии
  /// и забивали сервер/Bugsink (см. issue `dev-coins 403`). Здесь различаем:
  /// 4xx (кроме 401/429) = окончательный отказ → больше не спрашивать;
  /// 0/5xx/401/429 = транзиентно → можно повторить в следующей сессии. 403 не
  /// репортим в Sentry — это ожидаемый «ты не дев», а не сбой.
  Future<DevCoinsOutcome> devCoinsGrant() async {
    try {
      final res = await PocketBaseService().pb.send(
        '/api/coins/dev-coins',
        method: 'POST',
      );
      final m = res is Map ? Map<String, dynamic>.from(res) : null;
      return DevCoinsOutcome(DevCoinsResult.ok, m);
    } on ClientException catch (e) {
      final sc = e.statusCode;
      if (sc >= 400 && sc < 500 && sc != 401 && sc != 429) {
        return const DevCoinsOutcome(DevCoinsResult.denied, null);
      }
      return const DevCoinsOutcome(DevCoinsResult.retry, null);
    } catch (_) {
      return const DevCoinsOutcome(DevCoinsResult.retry, null);
    }
  }

  Future<Map<String, dynamic>?> partnerInvite(String partnerUid) =>
      _call('partner-invite', {'partnerUid': partnerUid});
  Future<Map<String, dynamic>?> moodStreak(String groupId) =>
      _call('mood-streak', {'groupId': groupId});

  Future<Map<String, dynamic>?> purchaseTheme(int themeId) =>
      _call('purchase-theme', {'themeId': themeId});
  Future<Map<String, dynamic>?> purchaseIcon(String iconId) =>
      _call('purchase-icon', {'iconId': iconId});
  Future<Map<String, dynamic>?> purchaseFeature(String featureId) =>
      _call('purchase-feature', {'featureId': featureId});
  /// Погашение кода пополнения из телеграм-бота (покупка мимо магазинов).
  Future<Map<String, dynamic>?> redeem(String code) =>
      _call('redeem', {'code': code});

  Future<Map<String, dynamic>?> spend(String actionId) =>
      _call('spend', {'actionId': actionId});

  /// Начисление коинов после подтверждённой магазином IAP-покупки.
  /// Идемпотентность — по [purchaseToken] на сервере.
  Future<Map<String, dynamic>?> iapPurchase({
    required String productId,
    required String purchaseToken,
  }) => _call('iap-purchase', {
    'productId': productId,
    'purchaseToken': purchaseToken,
  });
}
