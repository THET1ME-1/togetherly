import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Единая модель тем: палитра (акцент) × режим (свет/тьма) × вариант × AMOLED.
///
/// Раньше было 25 захардкоженных [AppTheme] — часть «светлые», часть «тёмные».
/// Теперь палитра — это ОДИН акцент, а свет/тьма — отдельный бесплатный тумблер.
/// Любой акцент раскрывается в обоих режимах через M3 ([ColorScheme.fromSeed]),
/// а узнаваемость («розовая — розовая») ведёт сам акцент, не производный tertiary.

/// Режим: светлый, тёмный, как в системе. Бесплатный тумблер поверх палитры.
enum AppThemeMode { light, dark, system }

extension AppThemeModeX on AppThemeMode {
  /// Разрешить в конкретную яркость. Для [system] берётся текущая яркость ОС.
  Brightness resolve() => switch (this) {
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
        AppThemeMode.system =>
          PlatformDispatcher.instance.platformBrightness,
      };
}

/// Вариант схемы: мягкий (по умолчанию), «сочно», «точь-в-точь».
enum SchemeFlavor { soft, juicy, exact }

extension SchemeFlavorX on SchemeFlavor {
  DynamicSchemeVariant get variant => switch (this) {
        SchemeFlavor.soft => DynamicSchemeVariant.tonalSpot,
        SchemeFlavor.juicy => DynamicSchemeVariant.vibrant,
        SchemeFlavor.exact => DynamicSchemeVariant.fidelity,
      };
}

/// Одна палитра: имя, акцент, платность. Индекс сохраняем прежним — на нём
/// висит владение (`owned_themes` на сервере), ломать нельзя.
class Palette {
  final int index;
  final String name;
  final Color accent;
  final bool isPremium;
  final int price;
  const Palette(this.index, this.name, this.accent,
      {this.isPremium = false, this.price = 0});
}

/// 25 палитр. Акценты разведены по оттенку и светлоте (мин. ΔE ≈ 17.7), чтобы
/// каждая была различима и совпадала с названием. Бесплатны первые пять.
const List<Palette> kPalettes = [
  Palette(0, 'Розовая', Color(0xFFFF7E9B)),
  Palette(1, 'Фиолетовая', Color(0xFF6E4FC0)),
  Palette(2, 'Голубая', Color(0xFF56AEE8)),
  Palette(3, 'Персиковая', Color(0xFFE8895A)),
  Palette(4, 'Шалфейная', Color(0xFF8CAE7E)),
  Palette(5, 'Полуночная', Color(0xFF33406E), isPremium: true, price: 30),
  Palette(6, 'Лавандовая', Color(0xFFCBA6E6), isPremium: true, price: 30),
  Palette(7, 'Вишнёвая', Color(0xFFB03A63), isPremium: true, price: 30),
  Palette(8, 'Мятная', Color(0xFF74D8BE), isPremium: true, price: 30),
  Palette(9, 'Закатная', Color(0xFFFF6A47), isPremium: true, price: 30),
  Palette(10, 'Монохром', Color(0xFF6E7178), isPremium: true, price: 30),
  Palette(11, 'Лесная', Color(0xFF276E3C), isPremium: true, price: 30),
  Palette(12, 'Океан', Color(0xFF1685A2), isPremium: true, price: 30),
  Palette(13, 'Медовая', Color(0xFFF0A81C), isPremium: true, price: 30),
  Palette(14, 'Лимонная', Color(0xFF9FCB2E), isPremium: true, price: 30),
  Palette(15, 'Песочная', Color(0xFFCDBE96), isPremium: true, price: 30),
  Palette(16, 'Северное сияние', Color(0xFF7C5CFF), isPremium: true, price: 40),
  Palette(17, 'Бордовая', Color(0xFF7C2E38), isPremium: true, price: 30),
  Palette(18, 'Бирюзовая', Color(0xFF16C2CE), isPremium: true, price: 30),
  Palette(19, 'Нордик', Color(0xFF40699E), isPremium: true, price: 30),
  Palette(20, 'Угольная бирюза', Color(0xFF1E7E70), isPremium: true, price: 30),
  Palette(21, 'Кофе', Color(0xFF9C6E45), isPremium: true, price: 30),
  Palette(22, 'Тёмный лес', Color(0xFF2FA355), isPremium: true, price: 30),
  Palette(23, 'Гранат', Color(0xFFE05A62), isPremium: true, price: 30),
  Palette(24, 'Тёмный мёд', Color(0xFFC8912E), isPremium: true, price: 30),
];

Palette paletteByIndex(int index) =>
    (index >= 0 && index < kPalettes.length) ? kPalettes[index] : kPalettes[0];

// ── Цветовая математика (совпадает с утверждённым макетом) ──
Color _lighten(Color c, double f) => Color.lerp(c, Colors.white, f)!;
Color _darken(Color c, double f) => Color.lerp(c, Colors.black, f)!;
double _avgLum(Color c) => 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;

/// Собирает [AppTheme] из палитры и режима. Все поверхности/текст — из M3-схемы
/// (tonalSpot/vibrant/fidelity), а идентичность (primary, hero) — из самого
/// акцента. В тёмном режиме тёмные акценты подсвечиваются, чтобы не тонуть.
AppTheme buildAppTheme(
  Palette p,
  Brightness brightness, {
  SchemeFlavor flavor = SchemeFlavor.soft,
  bool amoled = false,
}) {
  final s = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: brightness,
    dynamicSchemeVariant: flavor.variant,
  );
  final dark = brightness == Brightness.dark;
  // Эффективный акцент: тёмный акцент в тёмной теме поднимаем по светлоте.
  final acc = (dark && _avgLum(p.accent) < 0.45)
      ? _lighten(p.accent, 0.28)
      : p.accent;

  final card = (dark && amoled) ? const Color(0xFF181818) : s.surfaceContainerHigh;
  final bg1 = (dark && amoled) ? const Color(0xFF000000) : s.surface;
  final bg2 =
      (dark && amoled) ? const Color(0xFF000000) : s.surfaceContainerLow;
  final muted =
      (dark && amoled) ? const Color(0xFF222222) : s.surfaceContainerHighest;

  return AppTheme(
    index: p.index,
    name: p.name,
    isPremium: p.isPremium,
    price: p.price,
    brightness: brightness,
    primary: acc,
    primaryLight: s.primaryContainer,
    bgGradient: [bg1, bg2],
    heroGradient: [_lighten(acc, 0.06), _darken(acc, 0.14)],
    heroShadowBase: acc.withValues(alpha: 0.15),
    heroShadowExpanded: acc.withValues(alpha: 0.25),
    heroGlassOpacity: 0.20,
    heroToggleBorder: !dark,
    heroToggleSelectedColor: acc,
    cardSurface: card,
    cardBorder: s.outlineVariant,
    iconDraw: acc,
    iconMood: acc,
    iconCalendar: acc,
    iconPost: acc,
    navActiveBg: s.secondaryContainer,
    navActiveIcon: acc,
    promptButtonColor: acc,
    timerDialBackground: s.primaryContainer,
    textPrimary: s.onSurface,
    textSecondary: s.onSurfaceVariant,
    textMuted: s.outline,
    surfaceMuted: muted,
    divider: s.outlineVariant,
    useGlow: !dark,
  );
}
