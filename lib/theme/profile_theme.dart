import 'package:flutter/material.dart';

import 'app_theme.dart';

/// M3 Expressive-тема для экрана «Профиль» — в духе Kadr.
///
/// Схема выводится из [AppTheme.primary] как seed (вариант `vibrant`), поэтому
/// подстраивается под все 25 тем Togetherly и сама даёт тональные поверхности,
/// контейнеры и контрастный `primary` (белый текст на кнопках читается).
/// Заголовки/числа — Unbounded, текст — Onest. Экран профиля оборачивается в эту
/// тему через `Theme(data: ProfileTheme.themeFor(t), child: ...)`, дальше всё
/// строится стандартными M3-виджетами.
abstract final class ProfileTheme {
  static const String displayFont = 'Unbounded';
  static const String bodyFont = 'Onest';

  /// M3-схема из seed темы. Тёмные темы Togetherly дают тёмную схему.
  static ColorScheme schemeFor(AppTheme t) => ColorScheme.fromSeed(
        seedColor: t.primary,
        brightness: t.brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
      );

  static ThemeData themeFor(AppTheme t) => data(schemeFor(t));

  /// ThemeData (шрифты Unbounded/Onest, кнопки-пилюли, карточки) поверх готовой
  /// M3-схемы. Схему передаёт экран, чтобы она совпадала с вариантом приложения.
  static ThemeData data(ColorScheme scheme) => _fromScheme(scheme);

  static ThemeData _fromScheme(ColorScheme scheme) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: scheme.brightness,
    );
    final text = _expressiveText(base.textTheme);
    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: scheme.surface,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
        indent: 16,
        endIndent: 16,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: text.bodyLarge?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        subtitleTextStyle: text.bodyMedium?.copyWith(
          fontSize: 13,
          color: scheme.onSurfaceVariant,
        ),
      ),
      // Крупные «таблеточные» кнопки — фирменная черта expressive-стиля.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 56),
          padding: const EdgeInsets.symmetric(horizontal: 28),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
              fontFamily: bodyFont, fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 56),
          padding: const EdgeInsets.symmetric(horizontal: 28),
          shape: const StadiumBorder(),
          side: BorderSide(color: scheme.outline),
          textStyle: const TextStyle(
              fontFamily: bodyFont, fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
              fontFamily: bodyFont, fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      switchTheme: const SwitchThemeData(),
    );
  }

  static TextTheme _expressiveText(TextTheme base) {
    TextStyle display(TextStyle? s) => (s ?? const TextStyle()).copyWith(
        fontFamily: displayFont,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5);
    TextStyle headline(TextStyle? s) => (s ?? const TextStyle()).copyWith(
        fontFamily: displayFont,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3);
    TextStyle title(TextStyle? s) => (s ?? const TextStyle())
        .copyWith(fontFamily: displayFont, fontWeight: FontWeight.w600);
    TextStyle body(TextStyle? s) =>
        (s ?? const TextStyle()).copyWith(fontFamily: bodyFont);
    return base.copyWith(
      displayLarge: display(base.displayLarge),
      displayMedium: display(base.displayMedium),
      displaySmall: display(base.displaySmall),
      headlineLarge: headline(base.headlineLarge),
      headlineMedium: headline(base.headlineMedium),
      headlineSmall: headline(base.headlineSmall),
      titleLarge: title(base.titleLarge),
      titleMedium: title(base.titleMedium),
      titleSmall: title(base.titleSmall),
      bodyLarge: body(base.bodyLarge),
      bodyMedium: body(base.bodyMedium),
      bodySmall: body(base.bodySmall),
      labelLarge: body(base.labelLarge),
      labelMedium: body(base.labelMedium),
      labelSmall: body(base.labelSmall),
    );
  }
}
