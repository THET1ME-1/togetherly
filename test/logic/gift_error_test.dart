import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/services/gift_result.dart';

void main() {
  test('успешная отправка даёт баланс и repeated=false', () {
    final r = parseGiftResponse({'ok': true, 'alreadySent': false, 'coins': 40});
    expect(r.ok, isTrue);
    expect(r.coins, 40);
    expect(r.repeated, isFalse);
    expect(r.error, isNull);
  });

  test('повторная отправка помечается repeated', () {
    final r = parseGiftResponse({'ok': true, 'alreadySent': true, 'coins': 40});
    expect(r.repeated, isTrue);
  });

  test('повторный отклик тоже помечается repeated', () {
    final r = parseGiftResponse({'ok': true, 'alreadyReacted': true, 'refund': 3});
    expect(r.repeated, isTrue);
    expect(r.refund, 3);
  });

  test('нехватка монет разбирается в код insufficient', () {
    final r = parseGiftResponse({'ok': false, 'error': 'insufficient', 'coins': 5});
    expect(r.ok, isFalse);
    expect(r.error, GiftError.insufficient);
    expect(r.coins, 5);
  });

  test('неизвестный код ошибки не роняет разбор', () {
    final r = parseGiftResponse({'ok': false, 'error': 'что-то новое'});
    expect(r.error, GiftError.server);
  });

  test('пустой ответ считается сетевой ошибкой', () {
    expect(parseGiftResponse(null).error, GiftError.network);
  });
}
