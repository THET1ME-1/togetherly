/// Конфиг крашрепортинга на self-hosted Bugsink (Sentry-совместимый бэкенд на
/// нашем VPS — замена Firebase Crashlytics в рамках ухода с Firebase).
///
/// DSN — это НЕ секрет: публичный ключ проекта, он и должен жить в клиенте
/// (как и DSN в любом Sentry-приложении). Бэкенд: http://77.91.95.34:8000
/// (Bugsink, Docker, --memory=512m). Веб-панель крашей там же.
///
/// ⚠️ Пока по HTTP (PocketBase занимает 80/443 на домене). Перевести Bugsink
/// на HTTPS-сабдомен через reverse-proxy — отдельный инфра-шаг.
class SentryConfig {
  static const String dsn =
      'http://05953bce75c54cdb9fe149861d159da5@77.91.95.34:8000/1';
}
