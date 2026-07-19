import 'package:flutter/foundation.dart';
import 'package:flutter_rustore_billing/flutter_rustore_billing.dart';

import '../config/rustore_config.dart';
import 'coin_store.dart';

/// Реализация [CoinStore] для RuStore (магазин для Android в РФ).
///
/// RuStore использует свой billing SDK вместо Google Play Billing. Серверное
/// начисление монет — тот же путь, что и у Google Play ([GrantCoinsCallback] →
/// grantCoinsPurchase): сервер начисляет по whitelist productId и идемпотентности
/// по purchaseId. (Серверная верификация токена RuStore — отдельный TODO, см.
/// docs/RUSTORE.md.)
///
/// Монеты — расходуемый товар, поэтому после серверного начисления покупка
/// подтверждается через `confirm(purchaseId)` (consume).
class RuStoreIapService extends CoinStore {
  RuStoreIapService();

  bool _available = false;
  bool _loading = false;
  GrantCoinsCallback? _onGrantCoins;

  /// productId -> готовый ценник с валютой.
  final Map<String, String> _priceLabels = {};

  @override
  bool get isAvailable => _available;

  @override
  bool get isLoading => _loading;

  @override
  String? priceLabel(String productId) => _priceLabels[productId];

  @override
  Future<void> init({required GrantCoinsCallback onGrantCoins}) async {
    _onGrantCoins = onGrantCoins;

    if (!RuStoreConfig.isConfigured) {
      debugPrint('RuStoreIapService: appId не сконфигурирован — отключено');
      _available = false;
      return;
    }

    try {
      if (!await RustoreBillingClient.isRustoreInstalled()) {
        debugPrint('RuStoreIapService: приложение RuStore не установлено');
        _available = false;
        return;
      }

      await RustoreBillingClient.initialize(
        RuStoreConfig.appId,
        RuStoreConfig.deeplinkScheme,
        kDebugMode,
      );
      // Временно true, чтобы _loadProducts/_resolvePending отработали.
      _available = true;

      await _loadProducts();
      // Доводим незавершённые покупки (если приложение закрылось до confirm).
      await _resolvePending();

      // Биллинг считаем доступным ТОЛЬКО если товары реально загрузились. Пока
      // монетизация в RuStore Консоли не подключена (или товары не созданы),
      // products пуст → магазин монет авто-скрывается в UI (gate _iap.isAvailable),
      // а не показывает сломанные паки с пустой ценой. Появится сам, как только
      // товары заведутся в Консоли.
      _available = _priceLabels.isNotEmpty;
    } catch (e) {
      debugPrint('RuStoreIapService: init failed: $e');
      _available = false;
    }
  }

  Future<void> _loadProducts() async {
    _loading = true;
    notifyListeners();
    try {
      final ids = kCoinPacks.map((p) => p.productId).toList();
      final resp = await RustoreBillingClient.products(ids);
      for (final p in resp.products) {
        if (p == null) continue;
        final label = p.priceLabel;
        if (label != null && label.isNotEmpty) {
          _priceLabels[p.productId] = label;
        }
      }
    } catch (e) {
      debugPrint('RuStoreIapService: products failed: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  @override
  Future<IapResult> buy(String productId) async {
    if (!_available) {
      return const IapResult(IapStatus.error, error: 'RuStore недоступен');
    }

    _loading = true;
    notifyListeners();
    try {
      final result = await RustoreBillingClient.purchase(productId);

      final success = result.successPurchase;
      if (success != null) {
        return await _grantAndConfirm(success.productId, success.purchaseId);
      }

      if (result.invalidPurchase != null || result.invalidInvoice != null) {
        return const IapResult(IapStatus.error, error: 'Покупка отклонена');
      }

      // Оплата по invoice: успешный finishCode = оплачено, иначе отмена.
      final invoice = result.successInvoice;
      if (invoice != null) {
        final code = invoice.finishCode.toUpperCase();
        if (code.contains('CANCEL') || code.contains('CLOSED')) {
          return const IapResult(IapStatus.cancelled);
        }
        // Платёж принят, но purchase ещё не материализовался — доведём при
        // следующем запуске/Restore.
        return const IapResult(IapStatus.pending);
      }

      return const IapResult(IapStatus.cancelled);
    } catch (e) {
      debugPrint('RuStoreIapService: purchase failed: $e');
      return IapResult(IapStatus.error, error: e.toString());
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Серверное начисление, затем confirm (consume) покупки.
  Future<IapResult> _grantAndConfirm(String productId, String purchaseId) async {
    try {
      final newBalance = await _onGrantCoins?.call(
        productId: productId,
        purchaseToken: purchaseId,
      );

      if (newBalance == null) {
        return const IapResult(
          IapStatus.error,
          error: 'Сервер не начислил монеты',
        );
      }

      // Подтверждаем покупку ТОЛЬКО после успешного серверного начисления.
      try {
        await RustoreBillingClient.confirm(purchaseId);
      } catch (e) {
        debugPrint('RuStoreIapService: confirm failed: $e');
      }

      final pack = kCoinPacks.firstWhere(
        (p) => p.productId == productId,
        orElse: () => const CoinPack(productId: '', coins: 0),
      );
      return IapResult(IapStatus.success, coins: pack.coins);
    } catch (e) {
      debugPrint('RuStoreIapService: _grantAndConfirm failed: $e');
      return IapResult(IapStatus.error, error: e.toString());
    }
  }

  /// Доводит оплаченные, но не подтверждённые покупки (state == PAID).
  Future<void> _resolvePending() async {
    try {
      final resp = await RustoreBillingClient.purchases();
      for (final p in resp.purchases) {
        if (p == null) continue;
        final pid = p.purchaseId;
        final productId = p.productId;
        if (pid == null || productId == null) continue;
        if ((p.purchaseState ?? '').toUpperCase() == 'PAID') {
          await _grantAndConfirm(productId, pid);
        }
      }
    } catch (e) {
      debugPrint('RuStoreIapService: resolve pending failed: $e');
    }
  }

  @override
  Future<void> restorePurchases() async {
    if (!_available) return;
    await _resolvePending();
  }
}
