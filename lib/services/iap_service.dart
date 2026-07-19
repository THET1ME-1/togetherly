import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'coin_store.dart';

/// Реализация [CoinStore] для Google Play и App Store (через `in_app_purchase`).
///
/// Отвечает за:
///  - загрузку ProductDetails из магазина
///  - инициацию покупки
///  - получение обновлений покупок через [InAppPurchase.purchaseStream]
///  - вызов сервера через [GrantCoinsCallback] для начисления монет
///  - подтверждение (complete) транзакции перед сторами
class IapService extends CoinStore {
  IapService();

  // ── Состояние ─────────────────────────────────────────────────────────────

  bool _available = false;
  bool _loading = false;

  final Map<String, ProductDetails> _products = {};

  /// true если магазин доступен на этом устройстве.
  @override
  bool get isAvailable => _available;

  /// true если идёт загрузка продуктов или обработка покупки.
  @override
  bool get isLoading => _loading;

  /// Готовый ценник продукта (с валютой), либо null если ещё не загружен.
  @override
  String? priceLabel(String productId) => _products[productId]?.price;

  // ── Внутренние поля ───────────────────────────────────────────────────────

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  GrantCoinsCallback? _onGrantCoins;

  // Completer, который завершается когда обработка текущей покупки окончена.
  Completer<IapResult>? _currentCompleter;

  // ── Инициализация ─────────────────────────────────────────────────────────

  /// Инициализирует сервис. Вызывать один раз (обычно в main.dart или при
  /// открытии магазина монет).
  ///
  /// [onGrantCoins] — коллбек, который вызывается при успешном платеже
  /// для начисления монет через сервер.
  @override
  Future<void> init({required GrantCoinsCallback onGrantCoins}) async {
    _onGrantCoins = onGrantCoins;
    _available = await _iap.isAvailable();
    if (!_available) {
      debugPrint('IapService: store not available');
      return;
    }

    // Подписка на стрим покупок. Один раз за жизнь сервиса.
    _purchaseSub ??= _iap.purchaseStream.listen(
      _onPurchaseUpdates,
      onError: (Object e) {
        debugPrint('IapService: purchaseStream error: $e');
        _completeWith(IapResult(IapStatus.error, error: e.toString()));
      },
    );

    await _loadProducts();

    // Восстанавливаем незавершённые покупки (если пользователь переустановил
    // приложение, не завершив предыдущую транзакцию). Поток purchaseStream
    // доставит их, и _verifyAndGrant() начислит монеты.
    await _iap.restorePurchases();
  }

  /// Загружает ProductDetails для всех продуктов [kCoinPacks].
  Future<void> _loadProducts() async {
    _loading = true;
    notifyListeners();
    try {
      final ids = kCoinPacks.map((p) => p.productId).toSet();
      final response = await _iap.queryProductDetails(ids);
      if (response.error != null) {
        debugPrint('IapService: queryProductDetails error: ${response.error}');
      }
      for (final pd in response.productDetails) {
        _products[pd.id] = pd;
      }
      if (response.notFoundIDs.isNotEmpty) {
        debugPrint(
            'IapService: products not found in store: ${response.notFoundIDs}');
      }
    } catch (e) {
      debugPrint('IapService: _loadProducts failed: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Покупка ───────────────────────────────────────────────────────────────

  /// Инициирует покупку продукта с [productId].
  ///
  /// Возвращает [IapResult] после того, как транзакция завершена (успех,
  /// отмена или ошибка). Вызов блокируется через Completer до завершения.
  @override
  Future<IapResult> buy(String productId) async {
    if (_currentCompleter != null && !_currentCompleter!.isCompleted) {
      return const IapResult(
        IapStatus.error,
        error: 'Another purchase is in progress',
      );
    }

    final pd = _products[productId];
    if (pd == null) {
      return IapResult(
        IapStatus.error,
        error: 'Product "$productId" not loaded',
      );
    }

    _currentCompleter = Completer<IapResult>();

    final param = PurchaseParam(productDetails: pd);
    try {
      // consumable = true (монеты — расходуемый товар)
      await _iap.buyConsumable(purchaseParam: param);
    } catch (e) {
      debugPrint('IapService: buyConsumable failed: $e');
      _completeWith(IapResult(IapStatus.error, error: e.toString()));
    }

    return _currentCompleter!.future;
  }

  // ── Обработка обновлений покупки ─────────────────────────────────────────

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      await _handlePurchase(purchase);
    }
  }

  Future<void> _handlePurchase(PurchaseDetails purchase) async {
    switch (purchase.status) {
      case PurchaseStatus.pending:
        _completeWith(const IapResult(IapStatus.pending));
        break;

      case PurchaseStatus.canceled:
        _completeWith(const IapResult(IapStatus.cancelled));
        if (purchase.pendingCompletePurchase) {
          await _iap.completePurchase(purchase);
        }
        break;

      case PurchaseStatus.error:
        final msg = purchase.error?.message ?? 'Unknown IAP error';
        debugPrint('IapService: purchase error: $msg');
        _completeWith(IapResult(IapStatus.error, error: msg));
        if (purchase.pendingCompletePurchase) {
          await _iap.completePurchase(purchase);
        }
        break;

      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        await _verifyAndGrant(purchase);
        break;
    }
  }

  Future<void> _verifyAndGrant(PurchaseDetails purchase) async {
    final token =
        purchase.verificationData.serverVerificationData;
    final productId = purchase.productID;

    try {
      final newBalance = await _onGrantCoins?.call(
        productId: productId,
        purchaseToken: token,
      );

      if (newBalance != null) {
        final pack = kCoinPacks.firstWhere(
          (p) => p.productId == productId,
          orElse: () => const CoinPack(productId: '', coins: 0),
        );
        _completeWith(IapResult(IapStatus.success, coins: pack.coins));
      } else {
        _completeWith(const IapResult(
          IapStatus.error,
          error: 'Server failed to grant coins',
        ));
      }
    } catch (e) {
      debugPrint('IapService: _verifyAndGrant failed: $e');
      _completeWith(IapResult(IapStatus.error, error: e.toString()));
    } finally {
      // Важно: подтверждаем покупку ПОСЛЕ обработки сервером.
      if (purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
      }
    }
  }

  /// Ручное восстановление покупок. Вызывается из UI по кнопке "Restore".
  @override
  Future<void> restorePurchases() async {
    if (!_available) return;
    await _iap.restorePurchases();
  }

  // ── Хелперы ───────────────────────────────────────────────────────────────

  void _completeWith(IapResult result) {
    if (_currentCompleter != null && !_currentCompleter!.isCompleted) {
      _currentCompleter!.complete(result);
    }
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _purchaseSub?.cancel();
    super.dispose();
  }
}
