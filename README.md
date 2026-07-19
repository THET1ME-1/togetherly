<div align="center">

<img src="docs/branding/readme-banner.png" alt="Togetherly — an app for two" width="100%">

# Togetherly

<br>

[![Release](https://img.shields.io/github/v/release/THET1ME-1/togetherly?style=for-the-badge&label=release&color=E75480)](https://github.com/THET1ME-1/togetherly/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/THET1ME-1/togetherly/total?style=for-the-badge&color=8E4657)](https://github.com/THET1ME-1/togetherly/releases)
[![License](https://img.shields.io/github/license/THET1ME-1/togetherly?style=for-the-badge&color=8E4657)](LICENSE)
[![Stars](https://img.shields.io/github/stars/THET1ME-1/togetherly?style=for-the-badge&color=E75480)](https://github.com/THET1ME-1/togetherly/stargazers)
[![Platform](https://img.shields.io/badge/Android_·_iOS-1F1B24?style=for-the-badge)](https://github.com/THET1ME-1/togetherly/releases/latest)

![Flutter](https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white)
![PocketBase](https://img.shields.io/badge/PocketBase-B8DBD9?style=for-the-badge&logo=pocketbase&logoColor=black)
![Centrifugo](https://img.shields.io/badge/Centrifugo-46488B?style=for-the-badge)
![Material 3](https://img.shields.io/badge/Material_3-Expressive-E75480?style=for-the-badge)

**A cozy private space for two** — shared memories, moods, live map, home widgets, and little rituals that keep you close, even apart. 💛

🇷🇺 🇬🇧 · 2 languages

[**⬇ Download**](https://github.com/THET1ME-1/togetherly/releases/latest) · [English](#english) · [Русский](#-togetherly-русский)

<br>

<img src="docs/branding/screenshots.png" alt="Togetherly — profile, widgets, connection, calendar, drawing" width="100%">

</div>

---

## English

**Togetherly** is a warm, private app for couples (and small close groups). One shared space where your relationship lives — memories, moods, and everyday closeness — whether you're together or miles apart.

### What's inside
- 📸 **Shared Memory Lane** — photos, videos, places, music, books & movies in one feed
- 💌 **Time capsule** — seal a letter or a photo; it opens on the day you choose
- 🔒 **Secret memories** — hide the special ones behind a PIN
- 🏆 **Couple achievements** — milestones (100 days together, first photo, …) with confetti
- 🗺️ **Live map "Where we are"** — see each other's location in real time
- 🧩 **Home-screen widgets** (Android & iOS) — shared photo, days together, streak, mood
- 😊 **Moods** — track your mood and see your partner's history
- ⏱️ **Days together, streaks**, anniversary & birthday reminders
- 💬 **Private chat** and "miss you" nudges with push notifications
- 🎨 **Shared drawing canvas** and postcards
- 🐣 **A couple mascot** that grows with your activity
- 🎨 **20 themes** (light & dark) and themed app icons
- 🪙 Coins & rewards, co-watch, and more

### Download
**Android** — [**GitHub Releases**](https://github.com/THET1ME-1/togetherly/releases/latest) (recommended).

For auto-updates use **[Obtainium](https://github.com/ImranR98/Obtainium)**: *Add App* → paste
`https://github.com/THET1ME-1/togetherly` → it tracks every new release (pick `arm64-v8a` — almost all modern phones).

One-tap: `obtainium://add/https://github.com/THET1ME-1/togetherly`

Signing fingerprint (SHA-256) to verify the APK:
`1E:94:4F:00:FE:F1:17:D5:00:03:56:03:44:FC:BE:4F:9F:69:BF:FA:4C:F3:5B:A8:9F:26:D0:32:C3:3A:4E:13`

**RuStore · Google Play · App Store** — coming soon.

### Built with
Flutter (Material 3) · Dart · self-hosted **PocketBase** (auth / data / media) · **Centrifugo** (realtime) · offline-first sync · Android & iOS.

### Build from source
```bash
flutter pub get
# runs against the author's backend by default; point it at your own:
flutter run \
  --dart-define=PB_URL=https://your-pocketbase.example.com \
  --dart-define=CENTRIFUGO_WS=wss://your-pocketbase.example.com:8443/connection/websocket
```
No project keys ship in the repo — config files are `*.example` templates you fill in.
Full guide: **[CONTRIBUTING.md](CONTRIBUTING.md)**. Security issues → **[SECURITY.md](SECURITY.md)**.

### License
[GPL-3.0](LICENSE) — free software with copyleft: any fork/derivative, when distributed,
must stay open under the same license. The app is free to use; source © THET1ME-1.

---

## 🩷 Togetherly (Русский)

**Togetherly** — тёплое приватное приложение для пар (и небольших близких групп). Одно общее пространство, где живут ваши отношения: воспоминания, настроения и повседневная близость — вместе вы или за тысячи километров.

### Что внутри
- 📸 **Общая лента воспоминаний** — фото, видео, места, музыка, книги и фильмы в одной ленте
- 💌 **Капсула времени** — запечатайте письмо или фото; откроется в выбранный вами день
- 🔒 **Секретные воспоминания** — спрячьте особенное под PIN
- 🏆 **Достижения пары** — вехи (100 дней вместе, первое фото…) с праздничным салютом
- 🗺️ **Живая карта «Где мы»** — видите геопозицию друг друга в реальном времени
- 🧩 **Виджеты на экране** (Android и iOS) — общее фото, дни вместе, серия, настроение
- 😊 **Настроения** — отмечайте своё и смотрите историю партнёра
- ⏱️ **Дни вместе, серии**, напоминания о годовщине и дне рождения
- 💬 **Личный чат** и кнопка «Я скучаю» с пуш-уведомлениями
- 🎨 **Общий холст для рисования** и открытки
- 🐣 **Маскот пары**, который растёт вместе с вами
- 🎨 **20 тем** (светлые и тёмные) и тематические иконки приложения
- 🪙 Коины и награды, совместный просмотр и не только

### Скачать
**Android** — [**GitHub Releases**](https://github.com/THET1ME-1/togetherly/releases/latest) (рекомендуется).

Для авто-обновлений используйте **[Obtainium](https://github.com/ImranR98/Obtainium)**: *Add App* → вставьте
`https://github.com/THET1ME-1/togetherly` → он подхватывает каждый новый релиз (выбирайте `arm64-v8a` — почти все современные телефоны).

One-tap: `obtainium://add/https://github.com/THET1ME-1/togetherly`

Отпечаток подписи (SHA-256) для проверки APK:
`1E:94:4F:00:FE:F1:17:D5:00:03:56:03:44:FC:BE:4F:9F:69:BF:FA:4C:F3:5B:A8:9F:26:D0:32:C3:3A:4E:13`

**RuStore · Google Play · App Store** — скоро.

### На чём сделано
Flutter (Material 3) · Dart · самохост **PocketBase** (авторизация / данные / медиа) · **Centrifugo** (realtime) · offline-first синхронизация · Android и iOS.

### Сборка из исходников
```bash
flutter pub get
# по умолчанию цепляется к бэкенду автора; наведи на свой:
flutter run \
  --dart-define=PB_URL=https://твой-pocketbase.example.com \
  --dart-define=CENTRIFUGO_WS=wss://твой-pocketbase.example.com:8443/connection/websocket
```
Ключей проекта в репозитории нет — конфиги идут `*.example`-шаблонами, подставь свои.
Полный гайд: **[CONTRIBUTING.md](CONTRIBUTING.md)**. Про уязвимости — **[SECURITY.md](SECURITY.md)**.

### Лицензия
[GPL-3.0](LICENSE) — свободное ПО с копилефтом: любой форк/производная при распространении
остаётся открытым под той же лицензией. Приложение бесплатное; исходники © THET1ME-1.

---

<div align="center">

## 👥 Team · S&amp;T Company

Togetherly is built by **S&amp;T Company**

| | |
|:--|:--|
| [**THET1ME-1**](https://github.com/THET1ME-1) | founder · lead dev |
| [**JbSharan2**](https://github.com/JbSharan2) | co-founder |

<br>

<sub>Made with Flutter &amp; 💛 · <code>com.togetherly.love</code></sub>

</div>
