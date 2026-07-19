import 'package:shared_preferences/shared_preferences.dart';

/// Лёгкие локальные UI-настройки (без сервера). Единый источник ключей, чтобы
/// главный экран и настройки читали/писали одно и то же.
class UiPrefs {
  UiPrefs._();

  /// Режим боковой кнопки навбара: true = стрелка → (открыть Ленту),
  /// false = плюс + (сразу создать пин). Дефолт — стрелка.
  static const String kHomeSideActionArrow = 'home_side_action_arrow';

  /// Показана ли одноразовая подсказка про удержание боковой кнопки.
  static const String kSideActionHintSeen = 'side_action_hint_seen';

  static Future<bool> sideActionIsArrow() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(kHomeSideActionArrow) ?? true;
  }

  static Future<void> setSideActionIsArrow(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kHomeSideActionArrow, value);
  }

  static Future<bool> sideActionHintSeen() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(kSideActionHintSeen) ?? false;
  }

  static Future<void> markSideActionHintSeen() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kSideActionHintSeen, true);
  }
}
