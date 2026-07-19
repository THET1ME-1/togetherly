# Подготовка Togetherly к релизу на новых платформах

Заметки по выходу на **RuStore** и **iOS (App Store)** + ментальная модель кросс-платформенной разработки.
Приложение исторически заточено под Google Play (Firebase, Google Play Billing, AdMob, FCM, in_app_update, google_sign_in) — это и создаёт основную работу при портировании.

---

## 0. Как разрабатывают под разные платформы (ВАЖНО: НЕ через ветки git)

**Отдельные git-ветки под платформы делать нельзя.** Иначе каждую фичу пишешь дважды, ветки разъезжаются, баг чинишь в одной — в другой остаётся.
Ветки git нужны для **фич и релизов** (`feature/supabase-migration`, `feature/p2p-sync`), а не для платформ.

Правильная модель — **один codebase, одна ветка `main`**. Flutter компилирует один Dart-код и под Android, и под iOS. Различия решаются внутри кода:

1. **Рантайм-проверки:** `Platform.isIOS` / `Platform.isAndroid` / `defaultTargetPlatform` (уже используется в ~14 файлах).
2. **Нативные папки:** `android/` и `ios/` лежат рядом в одном репозитории — это не ветки, а папки одного проекта.
3. **Абстракция + разные реализации:** интерфейс (`PushService`), под капотом FCM/APNs/RuStore по платформе/сборке.
4. **Build flavors** — варианты сборки одной платформы (gplay/rustore/dev/prod). Это сборочные конфиги в той же ветке, НЕ ветки git.

```
main (одна ветка)
 ├── flutter build appbundle --flavor gplay   → Google Play
 ├── flutter build appbundle --flavor rustore → RuStore
 └── flutter build ipa                        → App Store
```

Ментальная модель:
- **Ветка git** = «над какой фичей/релизом работаю»
- **`android/` / `ios/`** = нативная часть каждой платформы
- **Flavors** = варианты сборки одной платформы
- **`Platform.is*` / абстракции** = поведение, отличающееся в рантайме

---

## 1. RuStore (альтернативный Android-стор)

### Главная проблема: зависимости от Google Play Services (GMS)
RuStore ставится в т.ч. на устройства **без GMS**, и модерация это проверяет.

| Зависимость | Что ломается на RuStore | Решение |
|---|---|---|
| `in_app_purchase` (Google Play Billing) | **Покупка коинов не работает совсем** (Billing физически требует установки из Google Play) | RuStore Billing / свой шлюз / убрать покупки — см. ниже |
| `in_app_update` | Google in-app update молча не срабатывает | `flutter_rustore_update` или гейт `Platform.isAndroid` + флейвор |
| `firebase_messaging` (FCM) | Пуши не доходят без GMS | `flutter_rustore_push` как fallback (пуши — ядро продукта) |
| `google_mobile_ads` (AdMob) | Реклама не грузится без GMS | Уже есть каскад Yandex→AdMob — Yandex закрывает; проверить, что фейл AdMob не ломает поток |
| `google_sign_in` | Требует GMS + проблемы с Google-аккаунтом в РФ | Убедиться, что есть email/пароль вход через `firebase_auth` |

### Платежи: Google Play Billing оставить нельзя (это техника, не выбор)
Google Play Billing физически не работает в приложении, установленном из RuStore (Play Store брокерит транзакцию и проверяет, что пакет пришёл из Play). Текущий `in_app_purchase` на RuStore-сборке мёртв.

Вопрос не «RuStore Billing или Google Play Billing», а **чем заменить**. Три пути:

- **A. RuStore Billing** (`flutter_rustore_billing`) — модерация ждёт этого; сам формирует **фискальные чеки по 54-ФЗ**; минус — привязка к наличию приложения RuStore на устройстве. Нужна серверная валидация через `https://public-api.rustore.ru` (текущая Cloud Function валидирует Google Play-токены — нужен отдельный путь). Продукты `coins_10/50/120/300` завести в RuStore Console.
- **B. Свой платёжный шлюз** (ЮKassa/CloudPayments) — работает везде; минус — **сам отвечаешь за чеки 54-ФЗ** и свой бэкенд. Оправдано только если провайдер уже есть.
- **C. Убрать покупки из RuStore-флейвора** — спрятать paywall, коины добываются только бесплатно (rewarded Yandex, гранты). Самый быстрый способ выложиться (пара часов), 0 интеграции платежей. Минус — теряешь монетизацию покупок.

> RuStore либеральнее Apple/Google: их правила **разрешают сторонние платёжные системы**, так что путь B легален. Но RuStore Billing (A) — путь наименьшего сопротивления из-за авточеков.

### Чек-лист RuStore
- [ ] **Блокеры:** определиться с платежами (A/B/C); подпись (`togetherly.jks` — RuStore НЕ делает Play App Signing, ключ финальный; вынести `key.properties` с паролем `togetherly123` из git); юр. часть (аккаунт ИП/самозанятый, политика конфиденциальности URL, возрастной рейтинг, 152-ФЗ).
- [ ] **Важное:** RuStore Push для устройств без GMS; RuStore Updates; product flavor `gplay`/`rustore`.
- [ ] **Проверки:** `targetSdk` ≥ 34; бамп версии; прогон на устройстве/эмуляторе **без GMS** (не должно крашиться); скриншоты/иконка/описание.

---

## 2. iOS (App Store)

### Блокеры
- **№0 — нужен Mac.** Собрать/подписать/загрузить iOS с Windows нельзя. Варианты: физический Mac / облачный Mac / CI с macOS (**Codemagic** — проще всего для Flutter, GitHub Actions, Bitrise).
- **№1 — Apple Developer Program** ($99/год).
- **№2 — Firebase на iOS не настроен:** нет `GoogleService-Info.plist` → `firebase_core` крашит на старте. Добавить iOS-app в Firebase Console (Bundle ID `com.togetherly.love`), скачать plist в `ios/Runner/`.
- **№3 — нативные виджеты рабочего стола.** ~13 Android-виджетов (`LoveWidgetProvider`, `DaysCounterWidgetProvider`, таймеры, фото…) на iOS **не появятся сами** — нужен отдельный **WidgetKit extension на SwiftUI**, UI каждого виджета переписать на Swift. Возможно, крупнейший объём работы во всём порте. Решить заранее, какие виджеты портировать.

### Важное (настройка перед сабмитом)
| Что | Деталь |
|---|---|
| **App Tracking Transparency** | Реклама (AdMob+Yandex) использует IDFA → Apple **обязательно** требует `NSUserTrackingUsageDescription` + ATT-промпт. Иначе реджект. |
| **AdMob iOS App ID** | В `Info.plist` сейчас плейсхолдер `ЗАМЕНИ_НА_IOS_APP_ID` — нужен реальный. |
| **Пуши (APNs)** | FCM на iOS идёт через APNs: APNs-ключ `.p8` в Firebase + capability Push Notifications + Background Modes (remote notification) + entitlements. Пуши — ядро продукта. |
| **Deep links** | Инвайты (`loveapp://`, `https://…/invite`) → `CFBundleURLTypes` в Info.plist + Associated Domains entitlement + `apple-app-site-association` на домене. |
| **Google Sign-In iOS** | URL scheme (reversed client ID) в Info.plist. |
| **IAP** | `in_app_purchase` поддерживает StoreKit, но продукты `coins_10/50/120/300` завести в App Store Connect + Paid Apps agreement. Комиссия 15–30%. |
| **Строки разрешений** | Добавить недостающие (микрофон при записи видео/аудио); исправить `CFBundleDisplayName` (сейчас `Love App` → `Togetherly`). |

### Перед публикацией
- Скриншоты под размеры iPhone; иконка (`flutter_launcher_icons: ios: true` — ок).
- Privacy nutrition labels + политика конфиденциальности + возрастной рейтинг.
- **Демо-аккаунт для ревьюера:** приложение для пар — нужен **спаренный** тестовый аккаунт (дать два связанных в review notes), иначе ревьюер видит пустой экран → реджект.
- `in_app_update` — Android-only; убедиться, что за гейтом `Platform.isAndroid`.

### Что можно сделать с Windows (без Mac)
Правка `Info.plist` (имя, ATT-строка, разрешения, URL scheme), entitlements-файл, проверка что Android-специфика (`in_app_update`, нативные виджеты, app-icon-алиасы) за гейтами `Platform.isAndroid`. Сборка/подпись — потом на Mac/Codemagic.
