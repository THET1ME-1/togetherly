import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/gift.dart';

void main() {
  test('у торта действие — задуть свечу', () {
    expect(GiftCatalog.byKey('cake')!.action, GiftAction.blow);
  });

  test('коробка, письмо и печенье носят вложенный текст', () {
    for (final key in ['giftbox', 'letter', 'cookie']) {
      expect(GiftCatalog.byKey(key)!.carriesNote, isTrue, reason: key);
    }
  });

  test('сердце ничего не требует — просто отклик', () {
    final heart = GiftCatalog.byKey('heart')!;
    expect(heart.action, GiftAction.tap);
    expect(heart.carriesNote, isFalse);
  });

  test('зайчика надо поймать, букет вянет', () {
    expect(GiftCatalog.byKey('bunny')!.action, GiftAction.catchIt);
    expect(GiftCatalog.byKey('bouquet')!.action, GiftAction.water);
  });

  test('букет живёт трое суток, остальные — сутки', () {
    expect(GiftCatalog.byKey('bouquet')!.life, const Duration(days: 3));
    expect(GiftCatalog.byKey('heart')!.life, const Duration(hours: 24));
  });

  test('у каждого подарка каталога действие задано', () {
    for (final g in GiftCatalog.all) {
      expect(g.action, isNotNull, reason: g.key);
    }
  });

  test('подсказка получателю зависит от действия', () {
    expect(actionHintRu(GiftAction.blow), 'Задуй свечу');
    expect(actionHintRu(GiftAction.open), 'Открой коробку');
    expect(actionHintRu(GiftAction.crack), 'Разломи печенье');
    expect(actionHintRu(GiftAction.catchIt), 'Поймай зайчика');
    expect(actionHintRu(GiftAction.water), 'Полей букет');
    expect(actionHintRu(GiftAction.tap), 'Нажми в ответ');
  });
}
