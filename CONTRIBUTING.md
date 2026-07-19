# Contributing to Togetherly

Thanks for your interest! Togetherly is a Flutter app for couples, open source
under **GPL-3.0**. This guide covers building from source, running against your
own backend, and sending changes.

> 🇷🇺 Краткая версия на русском — в конце файла.

---

## 1. Prerequisites

- **Flutter** (stable channel) with **Dart SDK ≥ 3.10.4** (`flutter --version`)
- **Android**: Android Studio / SDK for building & running
- **iOS** (optional): macOS + Xcode + CocoaPods

```bash
git clone https://github.com/THET1ME-1/togetherly.git
cd togetherly
flutter pub get
flutter run          # debug, connects to the default backend (see below)
```

`flutter analyze` must pass with **no errors** before you open a PR.

## 2. Configuration & secrets

**No project keys or secrets are committed.** Config files ship as `*.example`
templates — copy them and fill in your own values. Real files are gitignored.

| Template | Copy to | When you need it |
|---|---|---|
| `ios/Runner/GoogleService-Info.plist.example` | `ios/Runner/GoogleService-Info.plist` | iOS Google Sign-In (legacy Firebase). The app itself runs on PocketBase — Android/debug builds don't need it. |

### Backend URL (important)

By default the app talks to the author's **production** PocketBase — please don't
point load or test data at it. Run against your own backend with build-time
defines:

```bash
flutter run \
  --dart-define=PB_URL=https://your-pocketbase.example.com \
  --dart-define=CENTRIFUGO_WS=wss://your-pocketbase.example.com:8443/connection/websocket
```

Other optional defines:

- `--dart-define=KINOPOISK_TOKEN=...` — movie/series search ([get a free token](https://kinopoisk.dev)); without it the field falls back to manual entry.
- `--dart-define=STORE=rustore` — RuStore build flavor (in-app purchases). Omit for the plain build.

### Secrets you provide yourself (never commit these)

- Android signing keystore (`*.jks`, `key.properties`)
- iOS distribution key → GitHub Actions secret `CERTIFICATE_PRIVATE_KEY` (see `ios/certs/README.md`)
- Any service-account keys, admin passwords, provider tokens

## 3. Running the backend

The backend is self-hosted and lives in this repo:

- **PocketBase** — auth, data, media. Server-side logic is in
  `pocketbase/pb_hooks/*.pb.js` (hooks) and `pocketbase/pb_public/` (static pages).
  Drop the hooks into your PocketBase `pb_hooks/` directory. A few hooks read
  environment variables from the PocketBase process, e.g. `MOD_SECRET`
  (moderation endpoints) and `FB_WEB_API_KEY` (optional legacy login bridge).
- **Centrifugo** — realtime fan-out. PocketBase issues connection/subscription
  JWTs (`/api/centrifugo/*`); Centrifugo's API key is read from its own config
  on the server, not from this repo.
- **Cloudflare Workers** (`workers/`) and **Firebase functions** (`functions/`)
  are legacy/auxiliary — not required to run the app.

The app is offline-first: it works without a reachable backend and syncs when one
is available.

## 4. Pull requests

1. Fork, branch from the default branch.
2. Keep changes focused; match the surrounding code style.
3. Run `flutter analyze` (no errors) and, where relevant, `flutter test`.
4. Commit messages: short imperative summary (`fix(chat): …`, `feat(memories): …`).
   Russian or English are both fine — the codebase mixes both.
5. Open the PR with a clear description of what and why.

By contributing you agree your contributions are licensed under **GPL-3.0**.

## 5. Security

Found a vulnerability? **Don't open a public issue** — see
[SECURITY.md](SECURITY.md).

---

## 🇷🇺 Кратко по-русски

- Нужен **Flutter (stable)**, **Dart ≥ 3.10.4**. Клонировать → `flutter pub get` → `flutter run`.
- **Секретов и ключей проекта в репозитории нет.** Конфиги — `*.example`-шаблоны, копируйте и подставляйте свои.
- По умолчанию приложение ходит на **прод-бэкенд автора** — не нагружайте его. Свой бэкенд:
  `--dart-define=PB_URL=...` и `--dart-define=CENTRIFUGO_WS=...`.
- Опционально: `--dart-define=KINOPOISK_TOKEN=...` (поиск фильмов), `--dart-define=STORE=rustore` (сборка RuStore).
- Бэкенд самохостится: **PocketBase** (`pocketbase/pb_hooks/` — серверные хуки) + **Centrifugo** (realtime). Firebase/Workers — легаси, для запуска не нужны.
- Перед PR: `flutter analyze` без ошибок. Вклад — под лицензией **GPL-3.0**.
- Про уязвимости — только приватно, см. [SECURITY.md](SECURITY.md).
