import 'dart:async';

import 'package:pocketbase/pocketbase.dart';

import '../models/gift.dart';
import 'gift_result.dart';
import 'gift_telemetry.dart';
import 'offline/pb_id.dart';
import 'pocketbase_service.dart';

/// Отправка подарков партнёру и отклик на них.
///
/// Монетные операции в проекте идут мимо outbox, напрямую по сети (см.
/// `pb_coins_service.dart`), и подарки следуют тому же правилу: без связи
/// подарок не уходит, а человек видит честную ошибку вместо ложного
/// «отправлено».
///
/// Двойное списание закрыто идентификатором: `giftId` генерит клиент, он же
/// становится `id` записи на сервере. Повтор после обрыва связи возвращает
/// прежний баланс с пометкой [GiftResult.repeated].
class GiftsService {
  GiftsService._();

  static final GiftsService instance = GiftsService._();

  Future<GiftResult> send({
    required String groupId,
    required String giftKey,
  }) async {
    final gift = GiftCatalog.byKey(giftKey);
    if (gift == null) {
      return const GiftResult(ok: false, error: GiftError.unknownGift);
    }
    final giftId = newPbId();
    GiftTelemetry.step(giftId, 'send:start', data: {'gift_key': giftKey});

    return _call(
      path: '/api/gifts/send',
      body: {'giftId': giftId, 'groupId': groupId, 'giftKey': giftKey},
      giftId: giftId,
      giftKey: giftKey,
      step: 'send',
    );
  }

  Future<GiftResult> react(String giftId) async {
    GiftTelemetry.step(giftId, 'react:start');
    return _call(
      path: '/api/gifts/react',
      body: {'giftId': giftId},
      giftId: giftId,
      giftKey: '',
      step: 'react',
    );
  }

  /// Общий вызов роута.
  ///
  /// PocketBase SDK бросает [ClientException] на любой не-2xx ответ, поэтому
  /// отказы вроде `insufficient` (402) приходят сюда исключением, а не
  /// значением. Тело такого ответа лежит в `response` — разбираем его и отдаём
  /// нормальный код ошибки, иначе нехватка монет выглядела бы как обрыв сети.
  Future<GiftResult> _call({
    required String path,
    required Map<String, dynamic> body,
    required String giftId,
    required String giftKey,
    required String step,
  }) async {
    try {
      final res = await PocketBaseService().pb.send(
        path,
        method: 'POST',
        body: body,
      );
      final parsed = parseGiftResponse(
        res is Map ? Map<String, dynamic>.from(res) : null,
      );
      GiftTelemetry.step(giftId, '$step:${parsed.ok ? 'ok' : 'refused'}', data: {
        'error': parsed.error?.name,
        'coins': parsed.coins,
        'refund': parsed.refund,
        'repeated': parsed.repeated,
      });
      return parsed;
    } on ClientException catch (e, st) {
      final parsed = parseGiftResponse(
        e.response.isEmpty ? null : Map<String, dynamic>.from(e.response),
      );
      GiftTelemetry.step(giftId, '$step:refused',
          data: {'error': parsed.error?.name, 'status': e.statusCode});
      // Нехватка монет — единственный отказ, который человек создаёт сам.
      // Всё остальное (не участник, нет подарка, молчание сервера) означает
      // поломку и обязано быть видно в панели: без этого отказ выглядит как
      // «просто не работает» и чинить нечего.
      if (parsed.error != GiftError.insufficient) {
        GiftTelemetry.failure(e, st,
            giftId: giftId, giftKey: giftKey, step: step, code: parsed.error);
      }
      return parsed;
    } catch (e, st) {
      GiftTelemetry.failure(e, st,
          giftId: giftId,
          giftKey: giftKey,
          step: step,
          code: GiftError.network);
      return const GiftResult(ok: false, error: GiftError.network);
    }
  }
}
