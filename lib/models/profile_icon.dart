import '../services/locale_service.dart';

/// Профильная иконка («бейдж»), которую пользователь может купить за коины
/// и закрепить рядом со своим именем.
///
/// Источник правды о ценах — сервер (functions/index.js,
/// `PROFILE_ICON_PRICES`). Этот каталог — клиентское зеркало для отображения.
/// Все списания монет идут только через Cloud Function `purchaseIcon`.
class ProfileIcon {
  /// Идентификатор = имя файла без расширения (`assets/images/icons/<id>.webp`).
  final String id;

  /// Цена в коинах. 0 — иконка не продаётся (выдаётся только вручную).
  final int price;

  /// true для специальных наград (Sponsor / Helper): их нельзя купить,
  /// они выдаются разработчиком за вклад в проект.
  final bool grantOnly;

  final String _nameRu;
  final String _nameEn;
  final String _descRu;
  final String _descEn;

  const ProfileIcon({
    required this.id,
    required this.price,
    this.grantOnly = false,
    required String nameRu,
    required String nameEn,
    required String descRu,
    required String descEn,
  })  : _nameRu = nameRu,
        _nameEn = nameEn,
        _descRu = descRu,
        _descEn = descEn;

  /// Путь к ассету. Имена файлов всегда латиницей — см. каталог ниже.
  String get asset => 'assets/images/icons/$id.webp';

  String get name => LocaleService.instance.isRussian ? _nameRu : _nameEn;
  String get description =>
      LocaleService.instance.isRussian ? _descRu : _descEn;

  // ── Каталог ────────────────────────────────────────────────────────────────
  // Цены сверены с functions/index.js → PROFILE_ICON_PRICES.
  // Common = 20, Rare = 35, Premium = 50, Grant-only = 0.

  static const List<ProfileIcon> all = <ProfileIcon>[
    // ── Common (20) ──
    ProfileIcon(
      id: 'Paw',
      price: 20,
      nameRu: 'Лапка',
      nameEn: 'Paw',
      descRu: 'Для тех, кто любит пушистиков 🐾',
      descEn: 'For those who love fluffy friends 🐾',
    ),
    ProfileIcon(
      id: 'Sun',
      price: 20,
      nameRu: 'Солнышко',
      nameEn: 'Sunshine',
      descRu: 'Ты — моё солнце ☀️',
      descEn: 'You are my sunshine ☀️',
    ),
    ProfileIcon(
      id: 'Moon',
      price: 20,
      nameRu: 'Луна',
      nameEn: 'Moon',
      descRu: 'Люблю тебя до луны и обратно 🌙',
      descEn: 'Love you to the moon and back 🌙',
    ),
    ProfileIcon(
      id: 'Rainbow',
      price: 20,
      nameRu: 'Радуга',
      nameEn: 'Rainbow',
      descRu: 'Все цвета вашей любви 🌈',
      descEn: 'Every colour of your love 🌈',
    ),
    ProfileIcon(
      id: 'Bunny',
      price: 20,
      nameRu: 'Зайка',
      nameEn: 'Bunny',
      descRu: 'Нежный зайка для нежных сердец 🐰',
      descEn: 'A sweet bunny for tender hearts 🐰',
    ),
    ProfileIcon(
      id: 'Frog',
      price: 20,
      nameRu: 'Лягушонок',
      nameEn: 'Froggy',
      descRu: 'Поцелуй — и появится принц 🐸',
      descEn: 'One kiss and a prince appears 🐸',
    ),
    // ── Rare (35) ──
    ProfileIcon(
      id: 'Lucky',
      price: 35,
      nameRu: 'Везунчик',
      nameEn: 'Lucky',
      descRu: 'Мне повезло встретить тебя 🍀',
      descEn: 'Lucky to have found you 🍀',
    ),
    ProfileIcon(
      id: 'UFO',
      price: 35,
      nameRu: 'НЛО',
      nameEn: 'UFO',
      descRu: 'Наша любовь не от мира сего 🛸',
      descEn: 'Our love is out of this world 🛸',
    ),
    ProfileIcon(
      id: 'Together',
      price: 35,
      nameRu: 'Вместе',
      nameEn: 'Together',
      descRu: 'Вместе навсегда 💞',
      descEn: 'Together forever 💞',
    ),
    // ── Premium (50) ──
    ProfileIcon(
      id: 'Soulmate',
      price: 50,
      nameRu: 'Родственная душа',
      nameEn: 'Soulmate',
      descRu: 'Две половинки одного целого 💫',
      descEn: 'Two halves of one whole 💫',
    ),
    ProfileIcon(
      id: 'Perfect Match',
      price: 50,
      nameRu: 'Идеальная пара',
      nameEn: 'Perfect Match',
      descRu: 'Созданы друг для друга ❤️',
      descEn: 'Made for each other ❤️',
    ),
    ProfileIcon(
      id: 'Inseparable',
      price: 50,
      nameRu: 'Неразлучные',
      nameEn: 'Inseparable',
      descRu: 'Нас не разлучить 🔗',
      descEn: "Nothing can pull us apart 🔗",
    ),
    // ── Grant-only (награды за вклад в проект) ──
    ProfileIcon(
      id: 'Sponsor',
      price: 0,
      grantOnly: true,
      nameRu: 'Спонсор',
      nameEn: 'Sponsor',
      descRu: 'Спонсор проекта. Спасибо за поддержку! 💛',
      descEn: 'Project sponsor. Thank you for your support! 💛',
    ),
    ProfileIcon(
      id: 'Helper',
      price: 0,
      grantOnly: true,
      nameRu: 'Помощник',
      nameEn: 'Helper',
      descRu: 'Помощник проекта. Спасибо за вклад! 🤝',
      descEn: 'Project helper. Thanks for your contribution! 🤝',
    ),
    ProfileIcon(
      id: 'Fish',
      price: 0,
      grantOnly: true,
      nameRu: 'Рыбка',
      nameEn: 'Fishy',
      descRu: 'Для тех, кто любит рыбалку 🎣',
      descEn: 'For those who love fishing 🎣',
    ),
  ];

  /// Иконки, доступные для покупки (исключая grant-only).
  static List<ProfileIcon> get purchasable =>
      all.where((i) => !i.grantOnly).toList(growable: false);

  /// Поиск по id. Возвращает null, если иконки нет в каталоге.
  static ProfileIcon? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final icon in all) {
      if (icon.id == id) return icon;
    }
    return null;
  }
}
