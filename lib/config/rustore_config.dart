/// Конфигурация RuStore Billing.
///
/// Используется только в сборке для RuStore (`--dart-define=STORE=rustore`).
/// В сборке для Google Play / App Store эти значения не читаются.
abstract final class RuStoreConfig {
  /// ID приложения из RuStore Консоли (число из URL страницы приложения:
  /// console.rustore.ru/apps/<appId>).
  static const String appId = '2063716432';

  /// Deeplink-схема для возврата из платёжного флоу RuStore. Должна быть
  /// объявлена в AndroidManifest (см. docs/RUSTORE.md). Уникальна для приложения.
  static const String deeplinkScheme = 'togetherlyrustore';

  /// Сконфигурирован ли RuStore (appId подставлен). Защита от запуска платежей
  /// с placeholder-значением.
  static bool get isConfigured =>
      appId.isNotEmpty && !appId.contains('ЗАМЕНИ');
}
