import 'package:flutter/widgets.dart';

import 'app_theme.dart';

/// Даёт доступ к активной [AppTheme] из любого места дерева: `context.appTheme`.
///
/// Нужен для тёмной темы: виджеты, которым тема не прокидывалась параметром,
/// читают семантические токены (`textPrimary`, `cardSurface`, `divider`…) прямо
/// из контекста, вместо хардкоженных светлых цветов.
///
/// Устанавливается один раз в `MaterialApp.builder` и пересоздаётся при смене
/// темы — все зависящие виджеты перестраиваются автоматически.
class ThemeScope extends InheritedWidget {
  const ThemeScope({super.key, required this.theme, required super.child});

  final AppTheme theme;

  /// Активная тема. Если [ThemeScope] почему-то отсутствует (тесты, изолированные
  /// поддеревья) — безопасный фолбэк на светлую `pink`, а не исключение.
  static AppTheme of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    return scope?.theme ?? AppThemes.pink;
  }

  @override
  bool updateShouldNotify(ThemeScope oldWidget) {
    // Тема меняется не только сменой палитры (index), но и режимом свет/тьма,
    // вариантом и AMOLED при том же index — сравниваем подпись из ключевых полей.
    final a = theme, b = oldWidget.theme;
    return a.index != b.index ||
        a.brightness != b.brightness ||
        a.primary != b.primary ||
        a.cardSurface != b.cardSurface;
  }
}

/// Синтаксический сахар: `context.appTheme.textPrimary`.
extension AppThemeContext on BuildContext {
  AppTheme get appTheme => ThemeScope.of(this);
}
