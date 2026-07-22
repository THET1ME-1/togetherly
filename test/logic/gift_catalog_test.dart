import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/gift.dart';

/// Прайс-таблица серверного роута `pocketbase/pb_hooks/gifts.pb.js`.
/// Расхождение с каталогом = списание не той суммы, что видел человек.
const Map<String, int> serverPrices = {
  'heart': 10, 'star': 10, 'fire': 10, 'sun': 10,
  'hug': 15, 'night': 15, 'cookie': 15, 'bunny': 15, 'paw': 15, 'spa': 15,
  'coffee': 20, 'tea': 20, 'croissant': 20, 'pizza': 20, 'wine': 20,
  'cocktail': 20, 'song': 20, 'photo': 20, 'piggy': 20,
  'bouquet': 25, 'park': 25, 'ramen': 25, 'bed': 25, 'beach': 25,
  'giftbox': 30, 'letter': 30, 'movie': 30, 'salute': 30,
  'cake': 40, 'flight': 40, 'key': 40,
  'medal': 50, 'rocket': 50, 'diamond': 60,
};

void main() {
  test('в каталоге тридцать четыре подарка', () {
    expect(GiftCatalog.all.length, 34);
  });

  test('ключи уникальны', () {
    final keys = GiftCatalog.all.map((g) => g.key).toSet();
    expect(keys.length, GiftCatalog.all.length);
  });

  test('цены совпадают с серверной таблицей до копейки', () {
    for (final g in GiftCatalog.all) {
      expect(serverPrices[g.key], isNotNull,
          reason: 'подарка ${g.key} нет в серверной таблице');
      expect(g.price, serverPrices[g.key], reason: 'цена ${g.key} разъехалась');
    }
    expect(serverPrices.length, GiftCatalog.all.length,
        reason: 'на сервере есть подарки, которых нет в каталоге');
  });

  test('у каждого подарка непустые названия на обоих языках', () {
    for (final g in GiftCatalog.all) {
      expect(g.titleRu.trim(), isNotEmpty, reason: g.key);
      expect(g.titleEn.trim(), isNotEmpty, reason: g.key);
    }
  });

  test('путь к значку строится из ключа', () {
    expect(GiftCatalog.byKey('cake')!.asset, 'assets/images/gifts/cake.webp');
  });

  test('неизвестный ключ даёт null, а не исключение', () {
    expect(GiftCatalog.byKey('nope'), isNull);
  });

  test('витрина отсортирована по возрастанию цены', () {
    final prices = GiftCatalog.all.map((g) => g.price).toList();
    final sorted = [...prices]..sort();
    expect(prices, sorted);
  });
}
