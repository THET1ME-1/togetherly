# ios/certs

Пусто по замыслу. Приватный ключ iOS distribution-сертификата **в git не
хранится** — репозиторий публичный.

## Где ключ теперь

GitHub → репозиторий `THET1ME-1/togetherly` → Settings → Secrets and variables →
Actions → **`CERTIFICATE_PRIVATE_KEY`** = ключ в **base64 одной строкой**
(`base64 -w0 ios/certs/dist_cert_key.pem`).

Шаг подписи в `.github/workflows/release-apk.yml` (джоба `publish-ios`)
раскодирует base64 в PEM-файл и передаёт его в `app-store-connect
fetch-signing-files` как `--certificate-key @file:...`.

Ключ **постоянный**: под ним переиспользуется ОДИН distribution-сертификат
(не плодим новые → не упираемся в лимит Apple → нет «No Accounts» /
«No profiles for com.togetherly.love»). Паттерн уровня Fastlane Match, только
хранилище подписи — не git, а секреты GitHub.

## Остальные секреты iOS

- `APP_STORE_CONNECT_ISSUER_ID` — Issuer ID из App Store Connect →
  Users and Access → Integrations → App Store Connect API.
- `APP_STORE_CONNECT_KEY_IDENTIFIER` — Key ID того же ключа.
- `APP_STORE_CONNECT_PRIVATE_KEY` — содержимое `.p8`.

## Если ключ меняется / скомпрометирован

1. Отозвать старый сертификат: Apple Developer → Certificates → Revoke.
2. Сгенерировать новый приватный ключ, обновить `CERTIFICATE_PRIVATE_KEY`.
3. Следующая сборка заведёт новый distribution-сертификат под новым ключом.
