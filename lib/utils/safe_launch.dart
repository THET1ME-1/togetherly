import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

/// Открывает ссылку, не роняя приложение, если её некому обработать.
///
/// url_launcher бросает `PlatformException(ACTIVITY_NOT_FOUND)`, когда на
/// устройстве нет приложения под интент — например ссылка на SoundCloud/музыку
/// без установленного клиента (см. Bugsink, url_launcher_android). Возвращает
/// true, если ссылку удалось открыть.
Future<bool> safeLaunchUrl(
  Uri uri, {
  LaunchMode mode = LaunchMode.externalApplication,
}) async {
  try {
    return await launchUrl(uri, mode: mode);
  } catch (e) {
    debugPrint('safeLaunchUrl: не удалось открыть $uri: $e');
    return false;
  }
}
