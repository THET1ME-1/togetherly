# iOS Release Runbook — Togetherly

Этот файл описывает шаги, которые **нельзя сделать из кода** (консоли Apple /
Firebase / Codemagic) и которые завершают подготовку к релизу в App Store.

Архитектурное решение зафиксировано: **Apple-вход идёт через Firebase Auth**, а
НЕ через Supabase. Причина — единственный источник личности в приложении это
Firebase UID (на нём держатся связывание пар, доступ к Firestore/RTDB и RLS
Supabase, который доверяет Firebase ID-токену; см. `lib/main.dart` →
`Supabase.initialize(accessToken: ...)`). Вход через Supabase Auth создал бы
отдельный Supabase-UID и сломал бы связывание пар. **Пары Android+iOS совместимы
автоматически** — это два Firebase UID, связанные одним `pairId`, ОС не важна.

---

## Что уже сделано в коде (ветка `feature/ios-release`)

- `sign_in_with_apple` + `crypto` добавлены в `pubspec.yaml`.
- `FirebaseService.signInWithApple()` — Apple → `OAuthProvider('apple.com')` →
  `signInWithCredential` (с nonce, как требует Firebase).
- Кнопка «Continue with Apple» на экранах `login_screen` и `setup_screen`,
  показывается **только на iOS** (`Platform.isIOS`).
- `ios/Runner/Runner.entitlements`: Sign in with Apple, `aps-environment`,
  Associated Domains (`applinks:togetherly-d4856.web.app`).
- `ios/Runner/Info.plist`: имя «Togetherly», ATT-описание, URL-схема
  `loveapp://` (deep-link приглашений), placeholder AdMob iOS App ID.
- `ios/Podfile` создан (iOS 13, static frameworks).
- `codemagic.yaml` — облачная сборка/подпись/публикация в TestFlight.

---

## Блокеры, требующие действий в консолях (по порядку)

### 1. Apple Developer Portal (developer.apple.com)
- [ ] **App ID** `com.togetherly.love` (Identifiers → +). Включить capabilities:
      - **Sign In with Apple**
      - **Push Notifications**
      - **Associated Domains**
- [ ] Email Communication / Sign in with Apple: настроить **Email relay** для
      домена отправки (если письма приглашений уходят с собственного домена —
      иначе можно пропустить).

### 2. Firebase Console (проект `togetherly-d4856`)
- [x] Add app → **iOS**, bundle id `com.togetherly.love`.
- [x] Скачать **`GoogleService-Info.plist`** → лежит в
      `ios/Runner/GoogleService-Info.plist` (BUNDLE_ID/PROJECT_ID проверены).
- [x] Authentication → Sign-in method → включить **Apple**.
- [ ] (Если ещё не сделано для Android) проверить, что включён **Google**.

### 3. AdMob (apps.admob.com)
- [x] Создать **iOS-приложение** в том же AdMob-аккаунте.
- [x] iOS App ID вписан в `ios/Runner/Info.plist`
      (`ca-app-pub-1956369312643059~9958268140`).
- [x] iOS-рекламные блоки созданы и подставлены в код per-platform
      (`Platform.isIOS`): баннер `…/2598652877`, rewarded `…/1785393951`
      (см. rewarded_ad_service.dart, memory_lane_screen.dart, widget_screen.dart).
- [ ] Добавить **SKAdNetwork**-идентификаторы в `Info.plist` (список даёт
      Google/Yandex) — для атрибуции на iOS 14+.
- [ ] `app-ads.txt` уже задеплоен — проверить, что в нём есть запись и для iOS.

### 4. Apple App Site Association (для Universal Links / App Links)
- [ ] На хостинге `togetherly-d4856.web.app` выложить
      `/.well-known/apple-app-site-association` (JSON, без расширения,
      content-type `application/json`) с `appID = <TEAM_ID>.com.togetherly.love`
      и путём приглашений. Это iOS-аналог уже работающего Android `assetlinks`.

### 5. App Store Connect (appstoreconnect.apple.com)
- [ ] Создать приложение (bundle id `com.togetherly.love`), записать числовой
      **Apple ID** приложения → вставить в `codemagic.yaml` (`APP_STORE_APP_ID`).
- [ ] Заполнить карточку: описание, скриншоты (6.7"/6.5"/5.5" + iPad если
      поддерживаем iPad — сейчас orientation для iPad включён), privacy-метки
      (App Privacy), возрастной рейтинг.
- [ ] **Privacy Policy URL** — уже есть `PRIVACY_POLICY.md` (выложить как
      страницу/URL).
- [x] **Account deletion** — реализовано: Профиль → Danger Zone → «Удалить
      аккаунт» (`FirebaseService.deleteAccount()`: роспуск пар + удаление
      Firestore/Supabase + Firebase Auth, с переавторизацией Google/Apple).
- [ ] App Store Connect API key (.p8) → добавить в **Codemagic** (Integrations).

### 6. Codemagic
- [ ] Подключить репозиторий, добавить App Store Connect API key с именем
      `TogetherlyASC` (как в `codemagic.yaml` → `integrations.app_store_connect`).
      **Роль ключа — Admin или App Manager** (роль Developer НЕ может создавать
      сертификаты/профили → fetch-signing-files отдаст 401 и подпись упадёт).
- [x] **Постоянный ключ подписи (главный фикс подписи) — уже в репо.**
      Ошибка «No Accounts» / «No profiles for com.togetherly.love» была из-за того,
      что ключ генерился заново каждую сборку → под него плодились новые
      distribution-сертификаты, лимит Apple исчерпывался, профили не создавались.
      Фикс: постоянный ключ `ios/certs/dist_cert_key.pem` **закоммичен** (репо
      приватный), `codemagic.yaml` берёт его через `--certificate-key @file:...`.
      Ручной ввод переменных в Codemagic UI НЕ нужен.
- [ ] **Если билд упадёт с «Maximum number of certificates generated»** — значит за
      прошлые провальные прогоны distribution-сертификаты Apple исчерпаны (лимит
      2–3). Тогда отозвать лишние **Apple Distribution** в Apple Developer →
      Certificates (приложение на iOS ещё не выпущено — все они мусорные), и
      перезапустить сборку. Ключ уже постоянный, так что это разово.
- [ ] Запустить сборку: тег `ios-1.14.0` (push) либо «Start build» вручную.
- [ ] Первый прогон публикует в **TestFlight**. После проверки — переключить
      `submit_to_app_store: true` в `codemagic.yaml`.

> Диагностика: после фикса шаг подписи идёт с `set -euxo pipefail`, поэтому при
> сбое билд падает **на шаге «Set up code signing»** с реальной причиной
> (401 = права/интеграция ASC-ключа; «Maximum number of certificates» = отозвать
> старые сертификаты; «not found» переменной = не задан CERTIFICATE_PRIVATE_KEY),
> а не глубже в «Build IPA» с маскирующим «No Accounts».

---

## Чек-лист соответствия требованиям App Store
- [x] Sign in with Apple (Guideline 4.8 — раз есть Google-вход).
- [x] Удаление аккаунта в приложении (Guideline 5.1.1(v)).
- [ ] ATT-промпт перед персонализированной рекламой (`NSUserTrackingUsageDescription` добавлен).
- [ ] App Privacy «nutrition labels» в ASC.
- [ ] Все `NS*UsageDescription` осмысленны (фото/гео/камера — заполнены).

## Что протестировать в TestFlight в первую очередь
1. Вход через Apple (новый пользователь + повторный вход).
2. **Смешанная пара**: связать iOS-аккаунт с Android-аккаунтом по invite-коду /
   ссылке, проверить синхронизацию настроения, чата, «я скучаю», виджетов.
3. Deep-link приглашения (`loveapp://` и Universal Link `https://...web.app`).
4. Реклама (баннер/rewarded) и начисление коинов.
5. Push-уведомления.
