import 'package:sentry_flutter/sentry_flutter.dart';

import 'gift_result.dart';

/// Телеметрия подарков в Bugsink.
///
/// Каждое событие несёт `gift_id` — по нему в панели собирается вся цепочка:
/// покупка → отправка → доставка → отклик. Клиентские и серверные события
/// связываются тем же идентификатором: его генерит клиент, а роут
/// `pb_hooks/gifts.pb.js` кладёт в свои теги.
class GiftTelemetry {
  const GiftTelemetry._();

  /// Шаг сценария. Оседает крошкой и попадает в отчёт о любой последующей
  /// ошибке — видно, что человек делал до сбоя.
  static void step(String giftId, String step, {Map<String, dynamic>? data}) {
    Sentry.addBreadcrumb(Breadcrumb(
      category: 'gift',
      message: step,
      level: SentryLevel.info,
      data: {'gift_id': giftId, ...?data},
    ));
  }

  /// Сбой шага. Код ошибки уходит тегом, чтобы события группировались по
  /// причине, а не по тексту исключения.
  static void failure(
    Object e,
    StackTrace st, {
    required String giftId,
    required String giftKey,
    required String step,
    GiftError? code,
  }) {
    Sentry.captureException(e, stackTrace: st, withScope: (s) {
      s.setTag('feature', 'gifts');
      s.setTag('gift_id', giftId);
      s.setTag('gift_key', giftKey);
      s.setTag('gift_step', step);
      s.setTag('error_code', code?.name ?? 'unknown');
      s.level = SentryLevel.error;
    });
  }

  /// Рассинхрон: приложение не упало, но состояние разъехалось — монеты
  /// списаны, а записи подарка нет. Без явной проверки такое не всплывает
  /// никогда, потому что для пользователя это выглядит как «просто не пришло».
  static void mismatch(String giftId, String what) {
    Sentry.captureMessage(
      'gifts: рассинхрон — $what',
      level: SentryLevel.warning,
      withScope: (s) {
        s.setTag('feature', 'gifts');
        s.setTag('gift_id', giftId);
        s.setTag('error_code', 'mismatch');
      },
    );
  }
}
