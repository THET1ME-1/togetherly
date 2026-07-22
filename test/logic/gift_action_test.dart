import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/gift.dart';
import 'package:love_app/models/gift_effect.dart';

void main() {
  secondBatch();

  test('у торта действие — задуть свечу', () {
    expect(GiftCatalog.byKey('cake')!.action, GiftAction.blow);
  });

  test('коробка, письмо и печенье носят вложенный текст', () {
    for (final key in ['giftbox', 'letter', 'cookie']) {
      expect(GiftCatalog.byKey(key)!.carriesNote, isTrue, reason: key);
    }
  });

  test('медаль принимают простым тапом, но она носит подпись', () {
    final medal = GiftCatalog.byKey('medal')!;
    expect(medal.action, GiftAction.tap);
    expect(medal.carriesNote, isTrue);
  });

  test('каждому подарку каталога досталась своя механика или вложение', () {
    for (final g in GiftCatalog.all) {
      // эффекты на приложение живут отдельно, в gift_effect.dart
      final hasOwn = effectOf(g.key) != null ||
          g.action != GiftAction.tap ||
          g.carriesNote ||
          g.carriesDate ||
          g.carriesPlace ||
          g.keepsForever ||
          g.writesToFeed ||
          g.deliversAtMorning ||
          g.deliverAfter != null ||
          g.piercesQuietHours;
      expect(hasOwn, isTrue, reason: 'подарок ${g.key} остался просто картинкой');
    }
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

// ── партия 2: отклик, перевод, посвящение ────────────────────────────────────

void secondBatch() {
  test('сердце принимают двойным касанием', () {
    expect(GiftCatalog.byKey('heart')!.action, GiftAction.doubleTap);
  });

  test('обнимашка даёт бонус за быстрый ответ', () {
    final hug = GiftCatalog.byKey('hug')!;
    expect(hug.action, GiftAction.hugBack);
    expect(hug.mutualBonus, 5);
  });

  test('звезда просит вписать желание и вернуть его дарителю', () {
    final star = GiftCatalog.byKey('star')!;
    expect(star.action, GiftAction.wish);
    expect(star.wantsReply, isTrue);
  });

  test('салют и ракета срабатывают сразу у обоих', () {
    expect(GiftCatalog.byKey('salute')!.action, GiftAction.blast);
    expect(GiftCatalog.byKey('rocket')!.action, GiftAction.urgent);
  });

  test('копилка переводит монеты, а не тратит их', () {
    final piggy = GiftCatalog.byKey('piggy')!;
    expect(piggy.action, GiftAction.transfer);
    expect(piggy.transfersCoins, isTrue);
  });

  test('медаль и кольцо носят подпись и остаются навсегда', () {
    for (final key in ['medal', 'diamond']) {
      final g = GiftCatalog.byKey(key)!;
      expect(g.carriesNote, isTrue, reason: key);
      expect(g.keepsForever, isTrue, reason: key);
    }
  });

  test('обычные подарки навсегда не остаются', () {
    expect(GiftCatalog.byKey('coffee')!.keepsForever, isFalse);
  });
}
