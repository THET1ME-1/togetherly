# ios/certs

Пусто по замыслу. Приватный ключ iOS distribution-сертификата **в git не
хранится** — репозиторий публичный.

## Где ключ теперь

Codemagic → App environment variables → группа **`ios_signing`**, переменная
**`CERTIFICATE_PRIVATE_KEY`** = ключ в **base64 одной строкой**
(`base64 -w0 ios/certs/dist_cert_key.pem`), флаг **Secure**. Поле значения в
Codemagic однострочное, поэтому многострочный PEM хранится закодированным.
Скрипт подписи в `codemagic.yaml` раскодирует base64 в PEM-файл и передаёт его
как `--certificate-key @file:...`.

Ключ **постоянный**: fetch-signing-files под ним переиспользует ОДИН
distribution-сертификат каждую сборку (не плодит новые → не упирается в лимит
Apple → нет «No Accounts» / «No profiles for com.togetherly.love»). Паттерн
уровня Fastlane Match, только хранилище подписи — не git, а секреты Codemagic.

## Если ключ меняется / скомпрометирован

1. Отозвать старый сертификат: Apple Developer → Certificates → Revoke.
2. Сгенерировать новый приватный ключ, обновить `CERTIFICATE_PRIVATE_KEY` в Codemagic.
3. Следующая сборка заведёт новый distribution-сертификат под новым ключом.
