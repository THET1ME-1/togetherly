# Security Policy · Политика безопасности

## Reporting a vulnerability

Togetherly stores private data for couples (memories, photos, locations). If you
find a vulnerability, **please report it privately** — do not open a public issue.

- Email: **badzoff@gmail.com** (subject: `Togetherly security`)
- Or use GitHub → **Security** → **Report a vulnerability** (private advisory).

Please include: what you found, steps to reproduce, and the impact. We aim to
acknowledge within a few days. Do not access, modify, or exfiltrate data that
isn't yours while testing.

## Scope

- The Flutter app in this repository.
- The self-hosted backend hooks (`pocketbase/pb_hooks/`), Cloudflare Workers
  (`workers/`), and Firebase functions (`functions/`) as published here.

Out of scope: the production backend instance and its data, denial-of-service,
and issues in third-party dependencies (report those upstream).

## What is *not* a secret in this repo

Some values look sensitive but are public by design:

- **Sentry/Bugsink DSN** (`lib/config/sentry_config.dart`) — a public ingest key,
  like every Sentry DSN; it lives in the client on purpose.
- **Firebase client API keys** — client-side identifiers, protected by security
  rules, not credentials. (Legacy — the project is migrating to PocketBase.)

Real secrets (signing keys, service-account keys, admin passwords, provider
tokens) are **never** committed — they live in CI secrets / server env only.

---

## Сообщить об уязвимости

Togetherly хранит приватные данные пар (воспоминания, фото, геолокацию). Нашли
уязвимость — **сообщите приватно**, не открывайте публичный issue.

- Почта: **badzoff@gmail.com** (тема: `Togetherly security`)
- Или GitHub → **Security** → **Report a vulnerability** (приватный advisory).

Опишите находку, шаги воспроизведения и последствия. Не трогайте чужие данные во
время проверки.
