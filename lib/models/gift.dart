import '../services/locale_service.dart';

/// Движок подарка — что подарок делает, когда долетел до партнёра.
///
/// Пока реализован один: подарок приходит мгновенно, живёт сутки и просит
/// ответа. Ответил — часть монет возвращается дарителю, поэтому дарение
/// работает как обмен, а не как трата. Остальные движки (ждёт действия,
/// меняет приложение, зовёт вместе, копится, насовсем) — следующие фазы.
enum GiftEngine { response }

/// Что получатель делает с подарком. Действие определяет и анимацию, и текст
/// подсказки, и то, чем считается «ответ» — задутой свечой или простым тапом.
enum GiftAction {
  /// Просто нажать в ответ.
  tap,

  /// Задуть свечу: подарок ждёт, пока пламя не погаснет.
  blow,

  /// Открыть коробку — внутри записка от дарителя.
  open,

  /// Разломить печенье и прочитать предсказание.
  crack,

  /// Поймать: значок убегает по экрану.
  catchIt,

  /// Полить: без внимания подарок вянет раньше срока.
  water,

  /// Принять двойным касанием — как лайк в переписке.
  doubleTap,

  /// Обнять в ответ: успел за минуту — бонус обоим.
  hugBack,

  /// Загадать желание и отправить его текстом дарителю.
  wish,

  /// Салют: разворачивается сразу, без ожидания действия.
  blast,

  /// Срочный зов: уведомление проходит поверх тихого режима.
  urgent,

  /// Перевод монет партнёру.
  transfer,
}

/// Подсказка получателю на русском. Английский текст живёт в [actionHintEn].
String actionHintRu(GiftAction action) => switch (action) {
      GiftAction.doubleTap => 'Коснись дважды',
      GiftAction.hugBack => 'Обними в ответ',
      GiftAction.wish => 'Загадай желание',
      GiftAction.blast => 'Смотри салют',
      GiftAction.urgent => 'Ответь скорее',
      GiftAction.transfer => 'Забери монеты',
      GiftAction.blow => 'Задуй свечу',
      GiftAction.open => 'Открой коробку',
      GiftAction.crack => 'Разломи печенье',
      GiftAction.catchIt => 'Поймай зайчика',
      GiftAction.water => 'Полей букет',
      GiftAction.tap => 'Нажми в ответ',
    };

String actionHintEn(GiftAction action) => switch (action) {
      GiftAction.doubleTap => 'Double tap',
      GiftAction.hugBack => 'Hug back',
      GiftAction.wish => 'Make a wish',
      GiftAction.blast => 'Enjoy the fireworks',
      GiftAction.urgent => 'Answer soon',
      GiftAction.transfer => 'Take the coins',
      GiftAction.blow => 'Blow out the candle',
      GiftAction.open => 'Open the box',
      GiftAction.crack => 'Crack it open',
      GiftAction.catchIt => 'Catch the bunny',
      GiftAction.water => 'Water the flowers',
      GiftAction.tap => 'Tap back',
    };

class Gift {
  const Gift({
    required this.key,
    required this.price,
    required this.engine,
    required this.titleRu,
    required this.titleEn,
    this.action = GiftAction.tap,
    this.carriesNote = false,
    this.wantsReply = false,
    this.keepsForever = false,
    this.transfersCoins = false,
    this.mutualBonus = 0,
    this.life = const Duration(hours: 24),
  });

  /// Совпадает с ключом в серверной прайс-таблице (`pb_hooks/gifts.pb.js`).
  final String key;

  /// Цена для витрины. Списывает сервер по своей таблице — клиентскому числу
  /// тут никто не верит.
  final int price;

  final GiftEngine engine;

  /// Названия хранятся здесь, а не в [LocaleService]: тридцать четыре подарка
  /// дали бы шестьдесят восемь геттеров, которые правятся всегда вместе с
  /// каталогом. Общие строки экрана остались в локали.
  final String titleRu;
  final String titleEn;

  /// Что делает получатель, чтобы подарок «сработал».
  final GiftAction action;

  /// Даритель может вложить текст: записку, предсказание, письмо, посвящение.
  final bool carriesNote;

  /// Получатель пишет ответ, и он возвращается дарителю (желание на звезду).
  final bool wantsReply;

  /// Не расходуется, а остаётся в профиле пары навсегда. Видят только двое.
  final bool keepsForever;

  /// Цена уходит не в никуда, а на баланс партнёра.
  final bool transfersCoins;

  /// Монет обоим, если ответ пришёл в первую минуту.
  final int mutualBonus;

  /// Сколько подарок ждёт отклика, прежде чем истечёт.
  final Duration life;

  String get asset => 'assets/images/gifts/$key.webp';

  String get title => LocaleService.instance.isRussian ? titleRu : titleEn;
}

class GiftCatalog {
  const GiftCatalog._();

  /// Порядок = порядок на витрине: от дешёвых повседневных к дорогим событиям.
  static const List<Gift> all = [
    // Каждый день — 10-15 монет, покрываются дневным бонусом
    Gift(key: 'heart', price: 10, engine: GiftEngine.response, titleRu: 'Сердце', titleEn: 'Heart',
        action: GiftAction.doubleTap),
    Gift(key: 'star', price: 10, engine: GiftEngine.response, titleRu: 'Звезда', titleEn: 'Star',
        action: GiftAction.wish, wantsReply: true),
    Gift(key: 'fire', price: 10, engine: GiftEngine.response, titleRu: 'Огонёк', titleEn: 'Spark'),
    Gift(key: 'sun', price: 10, engine: GiftEngine.response, titleRu: 'Солнце', titleEn: 'Sun'),
    Gift(key: 'hug', price: 15, engine: GiftEngine.response, titleRu: 'Обнимашка', titleEn: 'Hug',
        action: GiftAction.hugBack, mutualBonus: 5),
    Gift(key: 'night', price: 15, engine: GiftEngine.response, titleRu: 'Сладких снов', titleEn: 'Good night'),
    Gift(key: 'cookie', price: 15, engine: GiftEngine.response, titleRu: 'Печенье', titleEn: 'Cookie',
        action: GiftAction.crack, carriesNote: true),
    Gift(key: 'bunny', price: 15, engine: GiftEngine.response, titleRu: 'Зайчик', titleEn: 'Bunny',
        action: GiftAction.catchIt),
    Gift(key: 'paw', price: 15, engine: GiftEngine.response, titleRu: 'Лапка', titleEn: 'Paw'),
    Gift(key: 'spa', price: 15, engine: GiftEngine.response, titleRu: 'Отдых', titleEn: 'Spa'),

    // По поводу — 20-30 монет
    Gift(key: 'coffee', price: 20, engine: GiftEngine.response, titleRu: 'Кофе', titleEn: 'Coffee'),
    Gift(key: 'tea', price: 20, engine: GiftEngine.response, titleRu: 'Чай', titleEn: 'Tea'),
    Gift(key: 'croissant', price: 20, engine: GiftEngine.response, titleRu: 'Завтрак', titleEn: 'Breakfast'),
    Gift(key: 'pizza', price: 20, engine: GiftEngine.response, titleRu: 'Пицца', titleEn: 'Pizza'),
    Gift(key: 'wine', price: 20, engine: GiftEngine.response, titleRu: 'Бокал', titleEn: 'Wine'),
    Gift(key: 'cocktail', price: 20, engine: GiftEngine.response, titleRu: 'Коктейль', titleEn: 'Cocktail'),
    Gift(key: 'song', price: 20, engine: GiftEngine.response, titleRu: 'Песня', titleEn: 'Song'),
    Gift(key: 'photo', price: 20, engine: GiftEngine.response, titleRu: 'Кадр', titleEn: 'Photo'),
    Gift(key: 'piggy', price: 20, engine: GiftEngine.response, titleRu: 'Копилка', titleEn: 'Piggy bank',
        action: GiftAction.transfer, transfersCoins: true),
    Gift(key: 'bouquet', price: 25, engine: GiftEngine.response, titleRu: 'Букет', titleEn: 'Bouquet',
        action: GiftAction.water, life: Duration(days: 3)),
    Gift(key: 'park', price: 25, engine: GiftEngine.response, titleRu: 'Прогулка', titleEn: 'Walk'),
    Gift(key: 'ramen', price: 25, engine: GiftEngine.response, titleRu: 'Ужин вдвоём', titleEn: 'Dinner'),
    Gift(key: 'bed', price: 25, engine: GiftEngine.response, titleRu: 'Сон', titleEn: 'Sleep'),
    Gift(key: 'beach', price: 25, engine: GiftEngine.response, titleRu: 'Отпуск', titleEn: 'Vacation'),
    Gift(key: 'giftbox', price: 30, engine: GiftEngine.response, titleRu: 'Коробка', titleEn: 'Gift box',
        action: GiftAction.open, carriesNote: true),
    Gift(key: 'letter', price: 30, engine: GiftEngine.response, titleRu: 'Письмо', titleEn: 'Letter',
        action: GiftAction.open, carriesNote: true),
    Gift(key: 'movie', price: 30, engine: GiftEngine.response, titleRu: 'Кино', titleEn: 'Movie'),
    Gift(key: 'salute', price: 30, engine: GiftEngine.response, titleRu: 'Салют', titleEn: 'Fireworks',
        action: GiftAction.blast),

    // Событие — 40-60 монет, за неделю бесплатно не накопить
    Gift(key: 'cake', price: 40, engine: GiftEngine.response, titleRu: 'Торт', titleEn: 'Cake',
        action: GiftAction.blow),
    Gift(key: 'flight', price: 40, engine: GiftEngine.response, titleRu: 'Билет', titleEn: 'Ticket'),
    Gift(key: 'key', price: 40, engine: GiftEngine.response, titleRu: 'Ключик', titleEn: 'Key'),
    Gift(key: 'medal', price: 50, engine: GiftEngine.response, titleRu: 'Медаль', titleEn: 'Medal',
        carriesNote: true, keepsForever: true),
    Gift(key: 'rocket', price: 50, engine: GiftEngine.response, titleRu: 'Ракета', titleEn: 'Rocket',
        action: GiftAction.urgent),
    Gift(key: 'diamond', price: 60, engine: GiftEngine.response, titleRu: 'Кольцо', titleEn: 'Ring',
        carriesNote: true, keepsForever: true),
  ];

  static Gift? byKey(String key) {
    for (final g in all) {
      if (g.key == key) return g;
    }
    return null;
  }
}
