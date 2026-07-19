# RuStore — сборка и интеграция

RuStore (магазин Android для РФ) использует **свою платёжную систему** вместо
Google Play Billing. Сделано так, что **отдельная ветка не нужна** — различие
магазинов решается флагом сборки `--dart-define=STORE=rustore` на одном `main`.

## Архитектура (сделано в коде)

- `lib/services/coin_store.dart` — интерфейс `CoinStore` (init/buy/restore/
  priceLabel) + общие типы (`CoinPack`, `kCoinPacks`, `IapResult`, `IapStatus`,
  `GrantCoinsCallback`) + фабрика `createCoinStore()`.
- `lib/services/iap_service.dart` — реализация для **Google Play / App Store**
  (через `in_app_purchase`). Используется по умолчанию.
- `lib/services/rustore_iap_service.dart` — реализация для **RuStore**
  (через `flutter_rustore_billing`).
- Выбор реализации: `kStore == 'rustore' ? RuStoreIapService() : IapService()`.
  Флаг `kStore = String.fromEnvironment('STORE', defaultValue: 'play')`.
- UI (`profile_screen`) работает только через интерфейс `CoinStore` и не знает,
  какой магазин под капотом.

**Продукты во всех магазинах с одинаковыми id:** `coins_10`, `coins_50`,
`coins_120`, `coins_300`.

**Серверное начисление:** тот же путь, что у Google Play (`grantCoinsPurchase`:
whitelist productId + идемпотентность по purchaseId). Серверная верификация
токена RuStore — TODO (см. ниже).

## Сборка

```bash
# Google Play (как сейчас, флаг не нужен — default=play):
flutter build appbundle --release

# RuStore:
flutter build apk --release --dart-define=STORE=rustore
```

Существующий Android-CI (`.github/workflows/release-apk.yml`) не трогается —
без флага собирается Play-вариант. RuStore-APK пока собирается вручную
командой выше (позже можно добавить отдельный workflow по тегу `rustore-*`).

## Что нужно настроить (консоль RuStore + проект)

### 1. RuStore Консоль (console.rustore.ru)
- [ ] Зарегистрировать приложение, package `com.togetherly.love`.
- [ ] Скопировать **ID приложения** → вставить в
      `lib/config/rustore_config.dart` (`RuStoreConfig.appId`, сейчас placeholder).
- [ ] Создать **потребляемые** товары (consumable) с id ровно:
      `coins_10`, `coins_50`, `coins_120`, `coins_300` + цены.
- [ ] Загрузить подписанный APK (ключ — тот же, что для релизов; см.
      CI/CD releases).

### 2. AndroidManifest — deeplink возврата из оплаты
RuStore Pay возвращается в приложение по deeplink-схеме
`togetherlyrustore` (значение `RuStoreConfig.deeplinkScheme`). Если сборка
rustore показывает, что после оплаты приложение не возвращается — добавить в
`android/app/src/main/AndroidManifest.xml` в activity intent-filter со схемой
`togetherlyrustore` (см. доку flutter_rustore_billing). Манифест общий с Play —
лишняя схема Play-сборке не мешает.

### 3. Серверная верификация (TODO, как и для Google Play)
Сейчас `grantCoinsPurchase` (functions/index.js) начисляет по whitelist
productId + идемпотентности, без верификации токена магазина (TODO и для Play).
Когда будете добавлять верификацию — разводить по магазину: Google Play
Developer API против RuStore Server API. Клиент уже шлёт `purchaseId` RuStore
как `purchaseToken`; можно добавить поле `store` в вызов для маршрутизации.

## Реклама на RuStore

AdMob требует Google-сервисы и на «чистых» RuStore-устройствах не зафилит — но
**Яндекс (основной источник rewarded) работает без GMS**. Водопад уже это
закрывает: Яндекс отдаёт, AdMob молча отваливается. Отдельной работы не требует.

## Самообновление (self-update)

Текущий sideload self-update (`update_service.dart` + репо togetherly)
для RuStore не нужен — магазин обновляет сам. На будущее: можно отключать
self-update во флаге `STORE=rustore` (сейчас не сделано, не блокер).

## Тестирование
1. На устройстве с установленным приложением RuStore собрать и поставить
   rustore-APK.
2. Купить пак монет → проверить начисление коинов (через сервер) и что покупка
   `confirm`-ится (повторно не списывается).
3. Убить приложение во время оплаты → перезапуск/Restore должен довести покупку
   (`_resolvePending`).
4. Реклама rewarded (Яндекс) на устройстве без Google-сервисов.
