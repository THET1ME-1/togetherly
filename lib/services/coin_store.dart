import 'package:flutter/foundation.dart';

import 'iap_service.dart';
import 'rustore_iap_service.dart';

/// Описание пака коинов, продаваемого через магазин.
class CoinPack {
  const CoinPack({
    required this.productId,
    required this.coins,
  });

  /// Идентификатор продукта (одинаков во всех магазинах: Google Play, App
  /// Store, RuStore — продукты заводятся с теми же id).
  final String productId;

  /// Количество монет, которое получит пользователь после покупки.
  final int coins;
}

/// Все доступные паки монет. Порядок = порядок отображения в UI.
const List<CoinPack> kCoinPacks = [
  CoinPack(productId: 'coins_10', coins: 10),
  CoinPack(productId: 'coins_50', coins: 50),
  CoinPack(productId: 'coins_120', coins: 120),
  CoinPack(productId: 'coins_300', coins: 300),
];

/// Статус обработки одной покупки.
enum IapStatus {
  /// Покупка подтверждена и монеты начислены.
  success,

  /// Платёж был инициирован, но сервер ещё не начислил монеты
  /// (например, pending-платёж).
  pending,

  /// Покупка отменена пользователем.
  cancelled,

  /// Произошла ошибка (сеть, магазин, сервер).
  error,
}

/// Результат попытки покупки.
class IapResult {
  const IapResult(this.status, {this.coins = 0, this.error});

  final IapStatus status;

  /// Количество начисленных монет (только при [IapStatus.success]).
  final int coins;

  /// Человекочитаемое описание ошибки (только при [IapStatus.error]).
  final String? error;
}

/// Коллбек для подтверждения покупки на сервере и начисления монет.
/// Возвращает новый баланс или null при ошибке.
///
///  - [productId] — идентификатор купленного продукта (например, `coins_50`)
///  - [purchaseToken] — токен/идентификатор покупки (Google Play / App Store
///    serverVerificationData либо RuStore purchaseId) — используется сервером
///    как ключ идемпотентности.
typedef GrantCoinsCallback = Future<int?> Function({
  required String productId,
  required String purchaseToken,
});

/// Абстракция магазина монет. Реализуется per-store ([IapService] для Google
/// Play / App Store, [RuStoreIapService] для RuStore). UI работает только
/// через этот интерфейс и не знает, какой магазин под капотом.
abstract class CoinStore extends ChangeNotifier {
  /// true если магазин доступен на этом устройстве.
  bool get isAvailable;

  /// true если идёт загрузка продуктов или обработка покупки.
  bool get isLoading;

  /// Готовый ценник продукта (с валютой), либо null если ещё не загружен.
  String? priceLabel(String productId);

  /// Инициализация. [onGrantCoins] — серверное начисление после оплаты.
  Future<void> init({required GrantCoinsCallback onGrantCoins});

  /// Инициирует покупку продукта [productId]. Завершается после оплаты/отмены.
  Future<IapResult> buy(String productId);

  /// Восстановление/доведение незавершённых покупок (кнопка «Restore»).
  Future<void> restorePurchases();
}

/// Магазин текущей сборки. Переключается флагом сборки:
///   flutter build apk --dart-define=STORE=rustore
/// По умолчанию (Google Play / App Store) — `play`.
const String kStore = String.fromEnvironment('STORE', defaultValue: 'play');

/// Можно ли ПОКУПАТЬ монеты в этой сборке. В гитхаб-версии (sideload,
/// `--dart-define=STORE=github`) покупок нет: платёжный провайдер (Lava Top)
/// отклонил товары монет. Сами монеты остаются (ежедневный бонус, реклама,
/// инвайт) — исчезает только витрина покупки.
const bool kCoinsPurchasable = kStore != 'github';

/// Показывать ли донат→монеты (DonationAlerts с подсказкой указать email). Только
/// в sideload/веб-сборках: GitHub-Android, RuStore, iOS-IPA (все собираются с
/// `STORE=github`/`rustore`). На Google Play и App Store (`STORE=play`) —
/// нельзя (продажа валюты за внешний платёж = нарушение биллинга/3.1.1).
const bool kDonationsEnabled = kStore == 'github' || kStore == 'rustore';

/// Создаёт реализацию магазина под текущую сборку. Google Play / App Store —
/// [IapService], RuStore — [RuStoreIapService], гитхаб-версия — заглушка без
/// покупок.
CoinStore createCoinStore() => switch (kStore) {
      'rustore' => RuStoreIapService(),
      'github' => _DisabledCoinStore(),
      _ => IapService(),
    };

/// Магазин-заглушка для сборок без покупок (гитхаб): всё выключено, `buy`
/// сразу возвращает ошибку. UI покупки в такой сборке всё равно скрыт
/// ([kCoinsPurchasable]).
class _DisabledCoinStore extends CoinStore {
  @override
  bool get isAvailable => false;
  @override
  bool get isLoading => false;
  @override
  String? priceLabel(String productId) => null;
  @override
  Future<void> init({required GrantCoinsCallback onGrantCoins}) async {}
  @override
  Future<IapResult> buy(String productId) async =>
      const IapResult(IapStatus.error, error: 'disabled');
  @override
  Future<void> restorePurchases() async {}
}
