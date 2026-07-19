import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException;

/// Безопасная обёртка над image_picker.
///
/// Когда пользователь отказывает в доступе к камере/галерее, плагин кидает
/// `PlatformException` (`camera_access_denied`, `photo_access_denied` и пр.).
/// Если вызов пикера не обёрнут, это исключение улетает в Crashlytics как
/// **Fatal** — хотя это нормальное действие пользователя, а не краш.
///
/// [safePick] глотает такие сбои пикера и возвращает `null` — вызывающий код
/// уже трактует `null` как «отмена». Для информирования пользователя можно
/// передать [onError] (например, показать снэкбар с подсказкой про настройки).
Future<T?> safePick<T>(
  Future<T?> Function() pick, {
  void Function(PlatformException e)? onError,
}) async {
  try {
    return await pick();
  } on PlatformException catch (e) {
    debugPrint('safePick: image_picker failed (${e.code})');
    onError?.call(e);
    return null;
  } catch (e) {
    // Напр. TypeError/«Null check» из нативного пути пикера при пересоздании
    // активити (потерянный результат) — тоже не краш, трактуем как отмену.
    debugPrint('safePick: image_picker error: $e');
    return null;
  }
}
