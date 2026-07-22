/// Движок подарка — что подарок делает, когда долетел до партнёра.
///
/// В фазе 1 реализован только «Отклик»: подарок приходит мгновенно, живёт до
/// истечения срока и просит ответа. Ответил — часть монет возвращается
/// дарителю, поэтому дарение работает как обмен, а не как трата.
enum GiftEngine { response }

class Gift {
  const Gift({
    required this.key,
    required this.price,
    required this.engine,
    required this.asset,
    required this.life,
  });

  /// Совпадает с ключом в серверной прайс-таблице (`pb_hooks/gifts.pb.js`).
  final String key;

  /// Цена для витрины. Списывает сервер по своей таблице — клиентскому числу
  /// тут никто не верит.
  final int price;

  final GiftEngine engine;
  final String asset;

  /// Сколько подарок ждёт отклика, прежде чем истечёт.
  final Duration life;
}

class GiftCatalog {
  const GiftCatalog._();

  static const List<Gift> all = [
    Gift(
      key: 'heart',
      price: 10,
      engine: GiftEngine.response,
      asset: 'assets/images/gifts/heart.webp',
      life: Duration(hours: 24),
    ),
    Gift(
      key: 'hug',
      price: 15,
      engine: GiftEngine.response,
      asset: 'assets/images/gifts/hug.webp',
      life: Duration(hours: 24),
    ),
    Gift(
      key: 'star',
      price: 10,
      engine: GiftEngine.response,
      asset: 'assets/images/gifts/star.webp',
      life: Duration(hours: 24),
    ),
    Gift(
      key: 'salute',
      price: 30,
      engine: GiftEngine.response,
      asset: 'assets/images/gifts/salute.webp',
      life: Duration(hours: 24),
    ),
    Gift(
      key: 'rocket',
      price: 50,
      engine: GiftEngine.response,
      asset: 'assets/images/gifts/rocket.webp',
      life: Duration(hours: 24),
    ),
  ];

  static Gift? byKey(String key) {
    for (final g in all) {
      if (g.key == key) return g;
    }
    return null;
  }
}
