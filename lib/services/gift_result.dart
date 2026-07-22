/// Причины, по которым подарок не ушёл или отклик не засчитался.
///
/// Каждый код уходит в Bugsink тегом `error_code`, поэтому события
/// группируются по причине. Без кода панель складывает всё в одну кучу
/// «ClientException», и понять, что чинить, невозможно.
enum GiftError {
  /// Не хватает монет на балансе.
  insufficient,

  /// Отправитель не состоит в группе, куда шлёт подарок.
  notMember,

  /// Ключа подарка нет в серверной таблице.
  unknownGift,

  /// Отклик пришёл не от получателя.
  notRecipient,

  /// Записи подарка нет — истекла, удалена или id выдуман.
  giftNotFound,

  /// Отклик уже был засчитан раньше.
  alreadyReacted,

  /// Раздел выключен фичефлагом.
  disabled,

  /// Запрос не дошёл до сервера.
  network,

  /// Сервер ответил, но причину не назвал.
  server,
}

class GiftResult {
  const GiftResult({
    required this.ok,
    this.error,
    this.coins,
    this.refund,
    this.mutual,
    this.repeated = false,
  });

  final bool ok;
  final GiftError? error;

  /// Баланс того, кто сделал запрос, уже после операции.
  final int? coins;

  /// Сколько монет вернулось дарителю за отклик.
  final int? refund;

  /// Бонус обоим за ответ в первую минуту («обнял в ответ»).
  final int? mutual;

  /// Сервер ответил, что операция уже была выполнена раньше. Монеты при этом
  /// не двигались — так работает защита от двойного списания.
  final bool repeated;
}

const Map<String, GiftError> _codes = {
  'insufficient': GiftError.insufficient,
  'not_member': GiftError.notMember,
  'unknown_gift': GiftError.unknownGift,
  'not_recipient': GiftError.notRecipient,
  'gift_not_found': GiftError.giftNotFound,
  'already_reacted': GiftError.alreadyReacted,
  'disabled': GiftError.disabled,
};

GiftResult parseGiftResponse(Map<String, dynamic>? body) {
  if (body == null) {
    return const GiftResult(ok: false, error: GiftError.network);
  }
  final ok = body['ok'] == true;
  if (!ok) {
    return GiftResult(
      ok: false,
      error: _codes[body['error']] ?? GiftError.server,
      coins: (body['coins'] as num?)?.toInt(),
    );
  }
  return GiftResult(
    ok: true,
    coins: (body['coins'] as num?)?.toInt(),
    refund: (body['refund'] as num?)?.toInt(),
    mutual: (body['mutual'] as num?)?.toInt(),
    repeated: body['alreadySent'] == true || body['alreadyReacted'] == true,
  );
}
