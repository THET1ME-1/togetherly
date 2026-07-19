import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Глобальный single-flight + кэш для запроса разрешения POST_NOTIFICATIONS
/// (Android 13+).
///
/// Несколько сервисов уведомлений (настроение, дни вместе, праздники, маскот)
/// могут запросить разрешение почти одновременно. Нативная сторона Android
/// отклоняет параллельные запросы исключением
/// `PlatformException(permissionRequestInProgress)` — раньше оно улетало в
/// Crashlytics как Fatal. Здесь запрос сериализуется на уровне всего приложения
/// (общий Future для конкурентных вызовов), результат кэшируется, а исключения
/// перехватываются.
bool _granted = false;
Future<bool>? _inFlight;

/// Возвращает true, если разрешение на уведомления выдано. Безопасно при
/// параллельных и повторных вызовах из разных сервисов.
Future<bool> requestNotificationPermissionSafely(
  AndroidFlutterLocalNotificationsPlugin? androidPlugin,
) async {
  if (_granted) return true;
  // Запрос уже идёт — переиспользуем его, не дёргаем нативку второй раз.
  final pending = _inFlight;
  if (pending != null) return pending;

  final future = () async {
    try {
      final granted =
          await androidPlugin?.requestNotificationsPermission() ?? true;
      _granted = granted;
      return granted;
    } on PlatformException catch (e) {
      // permissionRequestInProgress и пр. — не краш; попробуем в следующий раз.
      debugPrint('requestNotificationPermissionSafely failed (${e.code})');
      return false;
    } catch (e) {
      debugPrint('requestNotificationPermissionSafely error: $e');
      return false;
    } finally {
      _inFlight = null;
    }
  }();
  _inFlight = future;
  return future;
}
