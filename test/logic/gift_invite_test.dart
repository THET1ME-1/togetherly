import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/gift.dart';

void main() {
  test('приглашения открывают нужный экран после принятия', () {
    expect(GiftCatalog.byKey('coffee')!.opens, GiftOpens.callTimer);
    expect(GiftCatalog.byKey('tea')!.opens, GiftOpens.chat);
    expect(GiftCatalog.byKey('movie')!.opens, GiftOpens.watchTogether);
    expect(GiftCatalog.byKey('park')!.opens, GiftOpens.map);
    expect(GiftCatalog.byKey('photo')!.opens, GiftOpens.addPhoto);
  });

  test('у приглашений действие invite — их можно отклонить', () {
    for (final key in ['coffee', 'tea', 'movie', 'ramen', 'park', 'cocktail']) {
      expect(GiftCatalog.byKey(key)!.action, GiftAction.invite, reason: key);
    }
  });

  test('отказ возвращает дарителю всю цену, а не долю', () {
    expect(GiftCatalog.byKey('coffee')!.refundsOnDecline, isTrue);
  });

  test('письмо ждёт сутки, завтрак — до утра', () {
    expect(GiftCatalog.byKey('letter')!.deliverAfter, const Duration(hours: 24));
    expect(GiftCatalog.byKey('croissant')!.deliversAtMorning, isTrue);
  });

  test('пицца бросает монетку, бокал чокается', () {
    expect(GiftCatalog.byKey('pizza')!.action, GiftAction.coinFlip);
    expect(GiftCatalog.byKey('wine')!.action, GiftAction.clink);
  });

  test('отпуск и билет носят дату для обратного отсчёта', () {
    for (final key in ['beach', 'flight']) {
      expect(GiftCatalog.byKey(key)!.carriesDate, isTrue, reason: key);
    }
  });

  test('ракета проходит сквозь тихую ночь', () {
    expect(GiftCatalog.byKey('rocket')!.piercesQuietHours, isTrue);
    expect(GiftCatalog.byKey('heart')!.piercesQuietHours, isFalse);
  });

  test('ключик открывает секретные записи на сутки', () {
    expect(GiftCatalog.byKey('key')!.action, GiftAction.unlock);
  });

  test('лапка запоминает место отправителя', () {
    expect(GiftCatalog.byKey('paw')!.carriesPlace, isTrue);
  });

  test('салют оставляет запись в ленте пары', () {
    expect(GiftCatalog.byKey('salute')!.writesToFeed, isTrue);
  });

  test('песня носит строчку от дарителя', () {
    expect(GiftCatalog.byKey('song')!.carriesNote, isTrue);
  });

  test('сон ставит общий будильник', () {
    expect(GiftCatalog.byKey('bed')!.action, GiftAction.alarm);
  });
}
