import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/gift.dart';

void main() {
  test('каталог фазы 1 содержит ровно пять подарков движка «Отклик»', () {
    expect(GiftCatalog.all.length, 5);
    expect(GiftCatalog.all.every((g) => g.engine == GiftEngine.response), isTrue);
  });

  test('ключи уникальны', () {
    final keys = GiftCatalog.all.map((g) => g.key).toSet();
    expect(keys.length, GiftCatalog.all.length);
  });

  test('цены совпадают с серверными', () {
    expect(GiftCatalog.byKey('heart')!.price, 10);
    expect(GiftCatalog.byKey('hug')!.price, 15);
    expect(GiftCatalog.byKey('star')!.price, 10);
    expect(GiftCatalog.byKey('salute')!.price, 30);
    expect(GiftCatalog.byKey('rocket')!.price, 50);
  });

  test('неизвестный ключ даёт null, а не исключение', () {
    expect(GiftCatalog.byKey('nope'), isNull);
  });

  test('у каждого подарка есть ассет в assets/images/gifts', () {
    for (final g in GiftCatalog.all) {
      expect(g.asset, startsWith('assets/images/gifts/'));
      expect(g.asset, endsWith('.webp'));
    }
  });
}
