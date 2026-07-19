import 'package:flutter/material.dart';

/// Описание одной темы приложения.
///
/// Чтобы добавить новую тему — создай [AppTheme] и добавь в [AppThemes.all].
/// Все цвета задаются в одном месте, без `if (isPurple)` по всему коду.
class AppTheme {
  /// Уникальный id (совпадает с индексом в [AppThemes.all])
  final int index;

  /// Отображаемое название
  final String name;

  // ── Основные акцентные цвета ─────────────────────────────────────────────

  /// Главный акцентный цвет (кнопки, иконки, бейджи, рамки)
  final Color primary;

  /// Светлый вариант primary (фоны чипов, контейнеров)
  final Color primaryLight;

  // ── Фон страницы ─────────────────────────────────────────────────────────

  /// Цвета градиента фона [сверху, снизу]
  final List<Color> bgGradient;

  /// URL изображения фона из Firebase Storage (если задан — используется вместо градиента)
  final String? bgImageUrl;

  // ── Hero-карточка (ExpandableTimerCard) ──────────────────────────────────

  /// Цвета градиента карточки [начало, конец]
  final List<Color> heroGradient;

  /// Цвет тени в свёрнутом состоянии
  final Color heroShadowBase;

  /// Цвет тени в развёрнутом состоянии
  final Color heroShadowExpanded;

  /// Прозрачность стеклянных элементов внутри карточки (стрелка, тоггл)
  final double heroGlassOpacity;

  /// Показывать ли белую рамку на переключателе Days/Months/Time
  final bool heroToggleBorder;

  /// Цвет текста активного пункта тоггла
  final Color heroToggleSelectedColor;

  // ── Поверхности обычных карточек ─────────────────────────────────────────

  /// Фон карточек (Connect Prompt, Memory Lane и т.д.)
  final Color cardSurface;

  /// Цвет рамки карточек
  final Color cardBorder;

  // ── Иконки кнопок быстрых действий ───────────────────────────────────────

  final Color iconDraw;
  final Color iconMood;
  final Color iconCalendar;
  final Color iconPost;

  // ── Нижняя навигация ───────────────────────────────────────────────────

  /// Фон активной кнопки навигации
  final Color navActiveBg;

  /// Цвет иконки активного пункта навигации
  final Color navActiveIcon;

  /// Цвет кнопки "Ответить на вопрос" в Daily Reflection
  final Color promptButtonColor;

  /// Цвет фона лепестков таймера (PetalTimerDial)
  final Color timerDialBackground;

  /// Премиум-тема (требует разблокировки за Коины)
  final bool isPremium;

  /// Стоимость в Коинах (актуально только если [isPremium])
  final int price;

  // ── Тёмная тема (яркость + семантические токены) ─────────────────────────
  // Позволяют одной теме быть по-настоящему тёмной (тёмные карточки + светлый
  // текст). Все дефолты = прежние СВЕТЛЫЕ значения, поэтому 20 существующих тем
  // не меняются: они просто не передают эти параметры.

  /// Яркость темы. Управляет ColorScheme/scaffold/меню в `main._buildTheme`.
  final Brightness brightness;

  /// Основной текст на карточках и фоне (заголовки, значения). Заменяет
  /// хардкоженные `Colors.grey.shade900` / `Color(0xFF2A2A2A)` в виджетах.
  final Color textPrimary;

  /// Вторичный текст (подзаголовки, описания). Заменяет `grey.shade700/600`.
  final Color textSecondary;

  /// Приглушённый текст (подписи, плейсхолдеры, метки). Заменяет `grey.shade500/400`.
  final Color textMuted;

  /// Вторичная поверхность (чипы, поля ввода, приподнятые блоки внутри карточки).
  /// Заменяет `grey.shade100/200`.
  final Color surfaceMuted;

  /// Разделители и тонкие границы. Заменяет `grey.shade200/300`.
  final Color divider;

  /// Рисовать ли акцентные свечения-ореолы (мягкие цветные тени вокруг кнопок,
  /// карточек, активных элементов). Нуар-тёмные темы ставят `false` — глубина
  /// создаётся границами и слоями, а не сиянием. По умолчанию `true`, поэтому
  /// светлые темы не меняются.
  final bool useGlow;

  const AppTheme({
    required this.index,
    required this.name,
    required this.primary,
    required this.primaryLight,
    required this.bgGradient,
    this.bgImageUrl,
    required this.heroGradient,
    required this.heroShadowBase,
    required this.heroShadowExpanded,
    required this.heroGlassOpacity,
    required this.heroToggleBorder,
    required this.heroToggleSelectedColor,
    required this.cardSurface,
    required this.cardBorder,
    required this.iconDraw,
    required this.iconMood,
    required this.iconCalendar,
    required this.iconPost,
    required this.navActiveBg,
    required this.navActiveIcon,
    required this.promptButtonColor,
    required this.timerDialBackground,
    this.isPremium = false,
    this.price = 0,
    this.brightness = Brightness.light,
    this.textPrimary = const Color(0xFF212121),
    this.textSecondary = const Color(0xFF616161),
    this.textMuted = const Color(0xFF9E9E9E),
    this.surfaceMuted = const Color(0xFFF2F2F4),
    this.divider = const Color(0xFFE0E0E0),
    this.useGlow = true,
  });

  /// Тема тёмная? Удобный флаг для виджетов (например выбрать оттенок тени).
  bool get isDark => brightness == Brightness.dark;

  /// Цвет ЗАЛИВКИ акцентного/активного элемента, ПОВЕРХ которого лежит текст или
  /// иконка: FAB и круглые кнопки, заполненные лепестки таймера, ячейка «сегодня».
  ///
  /// Светлые темы и тёмные со СРЕДНИМ акцентом — заливка = сам [primary]
  /// (у 20 светлых тем `primary == navActiveIcon`, вид не меняется; у «Угольной
  /// розы» это даёт розовые заливки таймера/«сегодня»/FAB). И только когда акцент
  /// тёмной темы почти-белый (яркость > 0.6, как серебро нуара) — заливка падает
  /// на графит [AppThemes.darkFill], иначе она стала бы белым пятном с «белым
  /// текстом на белом». Цвет иконки/текста поверх бери через [AppThemes.onColor].
  Color get fillColor =>
      (isDark && primary.computeLuminance() > 0.6) ? AppThemes.darkFill : primary;

  /// Свечение-ореол вокруг элемента цветом [color] — то, что раньше писалось
  /// inline как `boxShadow: [BoxShadow(color: accent.withOpacity(0.3), …)]`.
  ///
  /// На темах без свечения ([useGlow] == false, нуар) возвращает пустой список,
  /// поэтому один и тот же виджет получается матовым на нуаре и с ореолом на
  /// светлых темах — без `if (isDark)` в каждом виджете.
  List<BoxShadow> accentGlow(
    Color color, {
    double blurRadius = 8,
    double opacity = 0.3,
    double spreadRadius = 0,
    Offset offset = const Offset(0, 2),
  }) => useGlow
      ? [
          BoxShadow(
            color: color.withValues(alpha: opacity),
            blurRadius: blurRadius,
            spreadRadius: spreadRadius,
            offset: offset,
          ),
        ]
      : const <BoxShadow>[];
}

// ─────────────────────────────────────────────────────────────────────────────
// Все доступные темы
// Чтобы добавить новую — создай AppTheme ниже и добавь в [all].
// ─────────────────────────────────────────────────────────────────────────────
abstract final class AppThemes {
  /// Графитовый фолбэк-тон заливки для тёмных тем с ПОЧТИ-БЕЛЫМ акцентом
  /// (яркость > 0.6, напр. серебро нуара): там `primary` нельзя лить как фон —
  /// получилось бы белое пятно с «белым текстом на белом», поэтому [AppTheme.fillColor]
  /// подставляет этот графит. Тёмные темы со средним акцентом (напр. «Угольная
  /// роза») заливаются самим `primary` и сюда не попадают.
  static const Color darkFill = Color(0xFF333438);

  // ── 0: Розовая ────────────────────────────────────────────────────────────
  static const pink = AppTheme(
    index: 0,
    name: 'Розовая',
    primary: Color(0xFFFF7E8B),
    primaryLight: Color(0xFFFEEAF1),
    bgGradient: [Color(0xFFFFE8DC), Color(0xFFFFE8DC), Color(0xFFFFF0EA)],
    heroGradient: [Color(0xFFFFB4B0), Color(0xFFFF8E9E)],
    heroShadowBase: Color(0x26FF7E8B), // rgba(255,126,139, 0.15)
    heroShadowExpanded: Color(0x40FF7E8B), // rgba(255,126,139, 0.25)
    heroGlassOpacity: 0.20,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFFFF7E8B), // == primary
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFE5E5E5),
    iconDraw: Color(0xFFFF7E8B),
    iconMood: Color(0xFFFF7E8B),
    iconCalendar: Color(0xFFFF7E8B),
    iconPost: Color(0xFFFF7E8B),
    navActiveBg: Color(0xFFF9E4E2),
    navActiveIcon: Color(0xFFFF7E8B),
    promptButtonColor: Color(0xFFFF7E8B),
    timerDialBackground: Color(0xFFFFB3BD),
    bgImageUrl:
        'https://firebasestorage.googleapis.com/v0/b/togetherly-d4856.firebasestorage.app/o/wallpapers%2Fpink-background.webp?alt=media',
  );

  // ── 1: Фиолетовая (Lavender) ──────────────────────────────────────────────
  static const purple = AppTheme(
    index: 1,
    name: 'Фиолетовая',
    primary: Color(0xFF9B86BD), // Calming Lavender
    primaryLight: Color(0xFFE6E6FA), // Soft Lavender
    bgGradient: [
      Color(0xFFE6E6FA),
      Color(0xFFF3F0FF),
    ], // lavender → soft lavender
    heroGradient: [Color(0xFF6C5B7B), Color(0xFF352F44)], // deep purple
    heroShadowBase: Color(0x0D000000), // black 5%
    heroShadowExpanded: Color(0x1A9B86BD), // lavender 10%
    heroGlassOpacity: 0.22,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF352F44), // глубокий фиолетовый
    cardSurface: Color(0xFFFDFDFF),
    cardBorder: Color(0xFFDDDDEE),
    iconDraw: Color(0xFF9B86BD),
    iconMood: Color(0xFF9B86BD),
    iconCalendar: Color(0xFF9B86BD),
    iconPost: Color(0xFF9B86BD),
    navActiveBg: Color(0xFFEDE7F6),
    navActiveIcon: Color(0xFF9B86BD),
    promptButtonColor: Color(0xFF9B86BD),
    timerDialBackground: Color(0xFFDBCEEC),
    bgImageUrl:
        'https://firebasestorage.googleapis.com/v0/b/togetherly-d4856.firebasestorage.app/o/wallpapers%2Fpurple-background.webp?alt=media',
  );

  // ── 2: Голубая (Dusty Sky) ────────────────────────────────────────────────
  static const blue = AppTheme(
    index: 2,
    name: 'Голубая',
    primary: Color(0xFF7898BF), // пыльно-голубой с тёплым оттенком
    primaryLight: Color(0xFFEAF2FA),
    bgGradient: [Color(0xFFEBF2F9), Color(0xFFF5F9FE)],
    bgImageUrl:
        'https://firebasestorage.googleapis.com/v0/b/togetherly-d4856.firebasestorage.app/o/wallpapers%2Fblue-background.webp?alt=media',
    heroGradient: [Color(0xFFA8C6DE), Color(0xFF7898BF)],
    heroShadowBase: Color(0x267898BF),
    heroShadowExpanded: Color(0x407898BF),
    heroGlassOpacity: 0.18,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF4D7099),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFD6E6F4),
    iconDraw: Color(0xFF7898BF),
    iconMood: Color(0xFF7898BF),
    iconCalendar: Color(0xFF7898BF),
    iconPost: Color(0xFF7898BF),
    navActiveBg: Color(0xFFE6F0FA),
    navActiveIcon: Color(0xFF7898BF),
    promptButtonColor: Color(0xFF7898BF),
    timerDialBackground: Color(0xFFC1D6EB),
  );

  // ── 3: Персиковая (Soft Peach) ─────────────────────────────────────────────
  static const orange = AppTheme(
    index: 3,
    name: 'Персиковая',
    primary: Color(0xFFCF7E5E), // мягкий тёплый терракот
    primaryLight: Color(0xFFFDF3EE),
    bgGradient: [Color(0xFFFEF4EE), Color(0xFFFFFBF8)],
    heroGradient: [Color(0xFFE5AA8E), Color(0xFFCF7E5E)],
    heroShadowBase: Color(0x26CF7E5E),
    heroShadowExpanded: Color(0x40CF7E5E),
    heroGlassOpacity: 0.20,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFFCF7E5E),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFEDE4DC),
    iconDraw: Color(0xFFCF7E5E),
    iconMood: Color(0xFFCF7E5E),
    iconCalendar: Color(0xFFCF7E5E),
    iconPost: Color(0xFFCF7E5E),
    navActiveBg: Color(0xFFFDF2EB),
    navActiveIcon: Color(0xFFCF7E5E),
    promptButtonColor: Color(0xFFCF7E5E),
    timerDialBackground: Color(0xFFF1CBB6),
    bgImageUrl:
        'https://firebasestorage.googleapis.com/v0/b/togetherly-d4856.firebasestorage.app/o/wallpapers%2Fpersic-background.webp?alt=media',
  );

  // ── 4: Шалфейная (Warm Sage) ─────────────────────────────────────────────
  static const green = AppTheme(
    index: 4,
    name: 'Шалфейная',
    primary: Color(0xFF7EA876), // тёплый мягкий шалфей
    primaryLight: Color(0xFFEBF5E6),
    bgGradient: [Color(0xFFF2F8EF), Color(0xFFFAFDF8)],
    heroGradient: [Color(0xFFA8C9A2), Color(0xFF7EA876)],
    heroShadowBase: Color(0x267EA876),
    heroShadowExpanded: Color(0x407EA876),
    heroGlassOpacity: 0.22,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF4E7649),
    cardSurface: Color(0xFFFBFDF9),
    cardBorder: Color(0xFFD4ECCE),
    iconDraw: Color(0xFF7EA876),
    iconMood: Color(0xFF7EA876),
    iconCalendar: Color(0xFF7EA876),
    iconPost: Color(0xFF7EA876),
    navActiveBg: Color(0xFFE5F3E1),
    navActiveIcon: Color(0xFF7EA876),
    promptButtonColor: Color(0xFF7EA876),
    timerDialBackground: Color(0xFFCEDDC6),
    bgImageUrl:
        'https://firebasestorage.googleapis.com/v0/b/togetherly-d4856.firebasestorage.app/o/wallpapers%2Fgreen-background.webp?alt=media',
  );

  // ═════════════════════════════════════════════════════════════════════════
  // ПРЕМИУМ-ТЕМЫ (требуют покупку за Коины)
  // ═════════════════════════════════════════════════════════════════════════

  // ── 5: Полуночная (Midnight) ─────────────────────────────────────────────
  static const midnight = AppTheme(
    index: 5,
    name: 'Полуночная',
    primary: Color(0xFF3B4A75),
    primaryLight: Color(0xFFE5E9F2),
    bgGradient: [Color(0xFFEBEEF7), Color(0xFFF5F7FC)],
    heroGradient: [Color(0xFF3B4A75), Color(0xFF1B1F3A)],
    heroShadowBase: Color(0x261B1F3A),
    heroShadowExpanded: Color(0x401B1F3A),
    heroGlassOpacity: 0.22,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF1B1F3A),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFD9DDEA),
    iconDraw: Color(0xFF3B4A75),
    iconMood: Color(0xFF3B4A75),
    iconCalendar: Color(0xFF3B4A75),
    iconPost: Color(0xFF3B4A75),
    navActiveBg: Color(0xFFE5E9F2),
    navActiveIcon: Color(0xFF3B4A75),
    promptButtonColor: Color(0xFF3B4A75),
    timerDialBackground: Color(0xFFC4CCE0),
    isPremium: true,
    price: 30,
  );

  // ── 6: Лавандовая (Lavender) ─────────────────────────────────────────────
  static const lavender = AppTheme(
    index: 6,
    name: 'Лавандовая',
    primary: Color(0xFFB392D4),
    primaryLight: Color(0xFFF5EFFB),
    bgGradient: [Color(0xFFFAF5FF), Color(0xFFFFFCFF)],
    heroGradient: [Color(0xFFD9C4ED), Color(0xFFB392D4)],
    heroShadowBase: Color(0x26B392D4),
    heroShadowExpanded: Color(0x40B392D4),
    heroGlassOpacity: 0.22,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF8E6FB8),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFE9DDF4),
    iconDraw: Color(0xFFB392D4),
    iconMood: Color(0xFFB392D4),
    iconCalendar: Color(0xFFB392D4),
    iconPost: Color(0xFFB392D4),
    navActiveBg: Color(0xFFF1E8FB),
    navActiveIcon: Color(0xFFB392D4),
    promptButtonColor: Color(0xFFB392D4),
    timerDialBackground: Color(0xFFE0CFEF),
    isPremium: true,
    price: 30,
  );

  // ── 7: Вишнёвая (Cherry) ─────────────────────────────────────────────────
  static const cherry = AppTheme(
    index: 7,
    name: 'Вишнёвая',
    primary: Color(0xFFA03D5C),
    primaryLight: Color(0xFFFBEAEF),
    bgGradient: [Color(0xFFFCF0F3), Color(0xFFFFF8FA)],
    heroGradient: [Color(0xFFC46A87), Color(0xFF7E2A45)],
    heroShadowBase: Color(0x26A03D5C),
    heroShadowExpanded: Color(0x40A03D5C),
    heroGlassOpacity: 0.22,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF7E2A45),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFEED9DF),
    iconDraw: Color(0xFFA03D5C),
    iconMood: Color(0xFFA03D5C),
    iconCalendar: Color(0xFFA03D5C),
    iconPost: Color(0xFFA03D5C),
    navActiveBg: Color(0xFFF9E2E8),
    navActiveIcon: Color(0xFFA03D5C),
    promptButtonColor: Color(0xFFA03D5C),
    timerDialBackground: Color(0xFFE2B4C2),
    isPremium: true,
    price: 30,
  );

  // ── 8: Мятная (Mint) ─────────────────────────────────────────────────────
  static const mint = AppTheme(
    index: 8,
    name: 'Мятная',
    primary: Color(0xFF6FBFA3),
    primaryLight: Color(0xFFE6F7F0),
    bgGradient: [Color(0xFFF0FBF6), Color(0xFFFAFEFC)],
    heroGradient: [Color(0xFF9CDCC4), Color(0xFF6FBFA3)],
    heroShadowBase: Color(0x266FBFA3),
    heroShadowExpanded: Color(0x406FBFA3),
    heroGlassOpacity: 0.20,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF4A9A80),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFD3EEE2),
    iconDraw: Color(0xFF6FBFA3),
    iconMood: Color(0xFF6FBFA3),
    iconCalendar: Color(0xFF6FBFA3),
    iconPost: Color(0xFF6FBFA3),
    navActiveBg: Color(0xFFDFF3EA),
    navActiveIcon: Color(0xFF6FBFA3),
    promptButtonColor: Color(0xFF6FBFA3),
    timerDialBackground: Color(0xFFBEE2D3),
    isPremium: true,
    price: 30,
  );

  // ── 9: Закатная (Sunset) ─────────────────────────────────────────────────
  static const sunset = AppTheme(
    index: 9,
    name: 'Закатная',
    primary: Color(0xFFFF7E5F),
    primaryLight: Color(0xFFFFEBE2),
    bgGradient: [Color(0xFFFFE9D6), Color(0xFFFFF4ED)],
    heroGradient: [Color(0xFFFFB36B), Color(0xFFFF6F61)],
    heroShadowBase: Color(0x26FF7E5F),
    heroShadowExpanded: Color(0x40FF7E5F),
    heroGlassOpacity: 0.20,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFFFF6F61),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFF3DCCE),
    iconDraw: Color(0xFFFF7E5F),
    iconMood: Color(0xFFFF7E5F),
    iconCalendar: Color(0xFFFF7E5F),
    iconPost: Color(0xFFFF7E5F),
    navActiveBg: Color(0xFFFFE0D2),
    navActiveIcon: Color(0xFFFF7E5F),
    promptButtonColor: Color(0xFFFF7E5F),
    timerDialBackground: Color(0xFFFFC9B5),
    isPremium: true,
    price: 30,
  );

  // ── 10: Монохром (Monochrome) ────────────────────────────────────────────
  static const monochrome = AppTheme(
    index: 10,
    name: 'Монохром',
    primary: Color(0xFF555555),
    primaryLight: Color(0xFFEFEFEF),
    bgGradient: [Color(0xFFF5F5F7), Color(0xFFFCFCFD)],
    heroGradient: [Color(0xFF888888), Color(0xFF3A3A3A)],
    heroShadowBase: Color(0x26555555),
    heroShadowExpanded: Color(0x40555555),
    heroGlassOpacity: 0.18,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF3A3A3A),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFE2E2E4),
    iconDraw: Color(0xFF555555),
    iconMood: Color(0xFF555555),
    iconCalendar: Color(0xFF555555),
    iconPost: Color(0xFF555555),
    navActiveBg: Color(0xFFECECEE),
    navActiveIcon: Color(0xFF555555),
    promptButtonColor: Color(0xFF555555),
    timerDialBackground: Color(0xFFCFCFCF),
    isPremium: true,
    price: 30,
  );

  // ── 11: Лесная (Forest) ──────────────────────────────────────────────────
  static const forest = AppTheme(
    index: 11,
    name: 'Лесная',
    primary: Color(0xFF3F6E47),
    primaryLight: Color(0xFFE4EFE5),
    bgGradient: [Color(0xFFEFF5EF), Color(0xFFF8FBF7)],
    heroGradient: [Color(0xFF6FA078), Color(0xFF284C32)],
    heroShadowBase: Color(0x263F6E47),
    heroShadowExpanded: Color(0x403F6E47),
    heroGlassOpacity: 0.22,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF284C32),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFD4E3D6),
    iconDraw: Color(0xFF3F6E47),
    iconMood: Color(0xFF3F6E47),
    iconCalendar: Color(0xFF3F6E47),
    iconPost: Color(0xFF3F6E47),
    navActiveBg: Color(0xFFDFEBE0),
    navActiveIcon: Color(0xFF3F6E47),
    promptButtonColor: Color(0xFF3F6E47),
    timerDialBackground: Color(0xFFBED3C1),
    isPremium: true,
    price: 30,
  );

  // ── 12: Океан (Ocean) ────────────────────────────────────────────────────
  static const ocean = AppTheme(
    index: 12,
    name: 'Океан',
    primary: Color(0xFF2A7A8C),
    primaryLight: Color(0xFFE1F1F4),
    bgGradient: [Color(0xFFE9F4F7), Color(0xFFF5FAFC)],
    heroGradient: [Color(0xFF5FB3C2), Color(0xFF1F5A6E)],
    heroShadowBase: Color(0x262A7A8C),
    heroShadowExpanded: Color(0x402A7A8C),
    heroGlassOpacity: 0.20,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF1F5A6E),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFD0E5EA),
    iconDraw: Color(0xFF2A7A8C),
    iconMood: Color(0xFF2A7A8C),
    iconCalendar: Color(0xFF2A7A8C),
    iconPost: Color(0xFF2A7A8C),
    navActiveBg: Color(0xFFDCEEF2),
    navActiveIcon: Color(0xFF2A7A8C),
    promptButtonColor: Color(0xFF2A7A8C),
    timerDialBackground: Color(0xFFB4D7DF),
    isPremium: true,
    price: 30,
  );

  // ── 13: Медовая (Honey / Sunny) ──────────────────────────────────────────
  static const honey = AppTheme(
    index: 13,
    name: 'Медовая',
    primary: Color(0xFFE3A11C), // тёплое золото-мёд
    primaryLight: Color(0xFFFDF3DC),
    bgGradient: [Color(0xFFFFF6E0), Color(0xFFFFFDF5)],
    heroGradient: [Color(0xFFFFD56B), Color(0xFFE3A11C)], // солнце → мёд
    heroShadowBase: Color(0x26E3A11C),
    heroShadowExpanded: Color(0x40E3A11C),
    heroGlassOpacity: 0.20,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFFB57E0E),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFF0E2C2),
    iconDraw: Color(0xFFE3A11C),
    iconMood: Color(0xFFE3A11C),
    iconCalendar: Color(0xFFE3A11C),
    iconPost: Color(0xFFE3A11C),
    navActiveBg: Color(0xFFFCEFCF),
    navActiveIcon: Color(0xFFE3A11C),
    promptButtonColor: Color(0xFFE3A11C),
    timerDialBackground: Color(0xFFFBDD93),
    isPremium: true,
    price: 30,
  );

  // ── 14: Лимонная (Toxic Lemon) ───────────────────────────────────────────
  static const lemon = AppTheme(
    index: 14,
    name: 'Лимонная',
    primary: Color(0xFF7FB800), // сочный токсичный лайм
    primaryLight: Color(0xFFF2FAD9),
    bgGradient: [Color(0xFFF4FBDD), Color(0xFFFCFEF3)],
    heroGradient: [Color(0xFFC2E64B), Color(0xFF7FB800)], // неон-лайм → лайм
    heroShadowBase: Color(0x267FB800),
    heroShadowExpanded: Color(0x407FB800),
    heroGlassOpacity: 0.20,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF5E8A00),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFE2EFC0),
    iconDraw: Color(0xFF7FB800),
    iconMood: Color(0xFF7FB800),
    iconCalendar: Color(0xFF7FB800),
    iconPost: Color(0xFF7FB800),
    navActiveBg: Color(0xFFECF7CE),
    navActiveIcon: Color(0xFF7FB800),
    promptButtonColor: Color(0xFF7FB800),
    timerDialBackground: Color(0xFFCBE88C),
    isPremium: true,
    price: 30,
  );

  // ── 15: Песочная (Sand / Beige) ──────────────────────────────────────────
  static const sand = AppTheme(
    index: 15,
    name: 'Песочная',
    primary: Color(0xFFBFA06B), // тёплый песочный
    primaryLight: Color(0xFFF6EFE2),
    bgGradient: [Color(0xFFF7F1E6), Color(0xFFFDFBF6)],
    heroGradient: [Color(0xFFDCC9A4), Color(0xFFBFA06B)],
    heroShadowBase: Color(0x26BFA06B),
    heroShadowExpanded: Color(0x40BFA06B),
    heroGlassOpacity: 0.20,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF8F7647),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFEBE0CC),
    iconDraw: Color(0xFFBFA06B),
    iconMood: Color(0xFFBFA06B),
    iconCalendar: Color(0xFFBFA06B),
    iconPost: Color(0xFFBFA06B),
    navActiveBg: Color(0xFFF1E7D4),
    navActiveIcon: Color(0xFFBFA06B),
    promptButtonColor: Color(0xFFBFA06B),
    timerDialBackground: Color(0xFFE0CEA8),
    isPremium: true,
    price: 30,
  );

  // ── 16: Северное сияние (Aurora) ─────────────────────────────────────────
  // Акцент — электрик-фиолетовый (полярное небо), hero — фиолетово-зелёная
  // лента сияния. Намеренно отличается от Бирюзовой (чистый cyan).
  static const aurora = AppTheme(
    index: 16,
    name: 'Северное сияние',
    primary: Color(0xFF7C5CFF), // электрик-фиолетовый
    primaryLight: Color(0xFFECE7FF),
    bgGradient: [Color(0xFFF0ECFF), Color(0xFFF5FBFF)], // ночь → рассвет
    heroGradient: [Color(0xFF6A4DE0), Color(0xFF2BE0A0)], // фиолет → неон-зелёное сияние
    heroShadowBase: Color(0x267C5CFF),
    heroShadowExpanded: Color(0x407C5CFF),
    heroGlassOpacity: 0.22,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF5B3FD6),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFE1DAF7),
    iconDraw: Color(0xFF7C5CFF),
    iconMood: Color(0xFF7C5CFF),
    iconCalendar: Color(0xFF7C5CFF),
    iconPost: Color(0xFF7C5CFF),
    navActiveBg: Color(0xFFEBE5FF),
    navActiveIcon: Color(0xFF7C5CFF),
    promptButtonColor: Color(0xFF7C5CFF),
    timerDialBackground: Color(0xFFC9BCFF),
    isPremium: true,
    price: 40,
  );

  // ── 17: Бордовая (Bordeaux, шёлк #893439) ────────────────────────────────
  static const bordeaux = AppTheme(
    index: 17,
    name: 'Бордовая',
    primary: Color(0xFF893439), // шелковистый бордо
    primaryLight: Color(0xFFF7E7E8),
    bgGradient: [Color(0xFFFBF0F1), Color(0xFFFFF9FA)],
    heroGradient: [Color(0xFFA8484F), Color(0xFF6E262B)], // шёлк → глубокий бордо
    heroShadowBase: Color(0x26893439),
    heroShadowExpanded: Color(0x40893439),
    heroGlassOpacity: 0.22,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF6E262B),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFEBD6D8),
    iconDraw: Color(0xFF893439),
    iconMood: Color(0xFF893439),
    iconCalendar: Color(0xFF893439),
    iconPost: Color(0xFF893439),
    navActiveBg: Color(0xFFF4E1E3),
    navActiveIcon: Color(0xFF893439),
    promptButtonColor: Color(0xFF893439),
    timerDialBackground: Color(0xFFD9A9AD),
    isPremium: true,
    price: 30,
  );

  // ── 18: Бирюзовая (Teal) — чистый cyan, отличается от ocean/mint/aurora ────
  static const teal = AppTheme(
    index: 18,
    name: 'Бирюзовая',
    primary: Color(0xFF0EA5A5), // равновесная cyan-бирюза
    primaryLight: Color(0xFFDCF5F4),
    bgGradient: [Color(0xFFE6F6F5), Color(0xFFF2FBFA)],
    heroGradient: [Color(0xFF46D6D0), Color(0xFF0B7E7E)], // яркий cyan → глубокий teal
    heroShadowBase: Color(0x260EA5A5),
    heroShadowExpanded: Color(0x400EA5A5),
    heroGlassOpacity: 0.20,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF0A6E6E),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFCBE9E7),
    iconDraw: Color(0xFF0EA5A5),
    iconMood: Color(0xFF0EA5A5),
    iconCalendar: Color(0xFF0EA5A5),
    iconPost: Color(0xFF0EA5A5),
    navActiveBg: Color(0xFFD8F2F0),
    navActiveIcon: Color(0xFF0EA5A5),
    promptButtonColor: Color(0xFF0EA5A5),
    timerDialBackground: Color(0xFF9BDDD9),
    isPremium: true,
    price: 30,
  );

  // ── 19: Нордик (Nord) — скандинавские интерфейсы ─────────────────────────
  static const nord = AppTheme(
    index: 19,
    name: 'Нордик',
    primary: Color(0xFF5E81AC), // Nord frost blue
    primaryLight: Color(0xFFE5EBF2),
    bgGradient: [Color(0xFFECEFF4), Color(0xFFF5F7FA)], // Snow Storm
    heroGradient: [Color(0xFF81A1C1), Color(0xFF3B4252)], // frost → polar night
    heroShadowBase: Color(0x265E81AC),
    heroShadowExpanded: Color(0x405E81AC),
    heroGlassOpacity: 0.20,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF3B4252),
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFD8DEE9),
    iconDraw: Color(0xFF5E81AC),
    iconMood: Color(0xFF5E81AC),
    iconCalendar: Color(0xFF5E81AC),
    iconPost: Color(0xFF5E81AC),
    navActiveBg: Color(0xFFE3EAF3),
    navActiveIcon: Color(0xFF5E81AC),
    promptButtonColor: Color(0xFF5E81AC),
    timerDialBackground: Color(0xFFAEC2DA),
    isPremium: true,
    price: 30,
  );

  // ── 20: Угольная бирюза (нейтральный уголь + спокойный тил) ───────────────
  // Тёмная тема, доведённая «под пару»: НЕЙТРАЛЬНО-угольные слои (без прежнего
  // тёплого сепийного подтона, из-за которого фон читался «коричневым») с ВИДИМОЙ
  // лестницей элевации (ΔL*≈8 фон→карточка — слои не сливаются). Акцент — спокойный
  // приглушённый тил вместо яркой розы: мягче на тёмном, без «конфетности».
  // Кремово-нейтральный текст, чёткие рёбра вместо свечений (useGlow: false).
  // Задаёт brightness.dark и полный набор тёмных токенов (textPrimary/…/
  // surfaceMuted/divider), которые виджеты читают вместо хардкоженных светлых
  // цветов. Тил — обычный СРЕДНИЙ акцент, поэтому (в отличие от серебра нуара)
  // спокойно работает и как ЗАЛИВКА: fillColor == primary, белый текст поверх
  // читается (та же светлота, что была у розы — паритет сохранён). Будущие тёмные
  // темы (янтарь, лёд) — такие же AppTheme со своим акцентом; для тем с почти-белым
  // акцентом заливка автоматически падает на графит darkFill.
  static const warmRoseDark = AppTheme(
    index: 20,
    name: 'Угольная бирюза',
    // Акцент — приглушённый тил: активная навигация, «сегодня», заливки, иконки,
    // кнопка «Я скучаю». Средней светлоты (≈как роза), чтобы белый текст поверх
    // читался, и контрастный как иконка на тёмном (≈6.5 на карточке).
    primary: Color(0xFF5FB3A9),
    primaryLight: Color(0xFF1B2221), // нейтральный тёмный «light»-фон чипов/контейнеров
    bgGradient: [Color(0xFF141718), Color(0xFF0C0E0F)], // нейтральный почти-чёрный уголь
    // Приподнятый нейтральный графит, матовый — объём даёт слой+ребро, без свечения.
    heroGradient: [Color(0xFF252B2D), Color(0xFF161A1B)],
    heroShadowBase: Color(0x59000000),
    heroShadowExpanded: Color(0x73000000),
    heroGlassOpacity: 0.10,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF5FB3A9),
    cardSurface: Color(0xFF1F2426), // поверхность карточки, ΔL*≈8 над фоном — видно
    cardBorder: Color(0xFF343A3C), // чёткое нейтральное ребро вместо ореола
    iconDraw: Color(0xFF5FB3A9),
    iconMood: Color(0xFF5FB3A9),
    iconCalendar: Color(0xFF5FB3A9),
    iconPost: Color(0xFF5FB3A9),
    navActiveBg: Color(0xFF28302F),
    navActiveIcon: Color(0xFF7FC7BC), // тил чуть светлее для активного состояния
    promptButtonColor: Color(0xFF5FB3A9), // «Я скучаю» — тил, белый текст поверх
    timerDialBackground: Color(0xFF28302F), // дорожка таймера / фон ячейки «сегодня»
    isPremium: true,
    price: 30,
    // ── тёмные токены (кремово-нейтральный текст, muted до нормы AA) ──────────
    brightness: Brightness.dark,
    textPrimary: Color(0xFFEEF2F2),
    textSecondary: Color(0xFFA6ADAE),
    textMuted: Color(0xFF889092), // поднят до AA (≈4.75 на карточке)
    // Темнее cardSurface (#1F2426): scaffold-фон экранов темнее карточек
    // (правильная иерархия dark), а поля/чипы на карточке — «утоплены».
    surfaceMuted: Color(0xFF0E1112),
    divider: Color(0xFF343A3C),
    useGlow: false, // матовый нуар: никаких свечений-ореолов
  );

  // ── 21: Кофе (эспрессо + карамельный латте) ──────────────────────────────
  // Вторая тёмная тема, НАМЕРЕННО тёплая: глубокие эспрессо-коричневые слои
  // (здесь коричневый — это эстетика кофе, а не случайный подтон) с ВИДИМОЙ
  // лестницей элевации (ΔL*≈8 фон→карточка — слои не сливаются). Акцент —
  // карамельный латте («кофе с молоком»): тёплый, средней светлоты, поэтому
  // белый текст поверх заливок читается (паритет с розой/тилом), и контрастен
  // как иконка на тёмном (≈6.5 на карточке). Кремово-молочный текст, матовые
  // рёбра без свечений (useGlow: false). Полный набор тёмных токенов — виджеты
  // читают их вместо хардкоженных светлых цветов.
  static const coffeeDark = AppTheme(
    index: 21,
    name: 'Кофе',
    // Акцент — карамельный латте: активная навигация, «сегодня», заливки, иконки,
    // кнопка «Я скучаю». Средней светлоты (белый текст поверх читается).
    primary: Color(0xFFC79A6B),
    primaryLight: Color(0xFF2A1F18), // тёплый тёмный «light»-фон чипов/контейнеров
    bgGradient: [Color(0xFF1E1512), Color(0xFF110B09)], // глубокий эспрессо
    // Приподнятый мокко, матовый — объём даёт слой+ребро, без свечения.
    heroGradient: [Color(0xFF33251E), Color(0xFF1F1611)],
    heroShadowBase: Color(0x59000000),
    heroShadowExpanded: Color(0x73000000),
    heroGlassOpacity: 0.10,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFFC79A6B),
    cardSurface: Color(0xFF2A1E19), // поверхность карточки (мокко), ΔL*≈8 над фоном
    cardBorder: Color(0xFF40312A), // чёткое тёплое ребро вместо ореола
    iconDraw: Color(0xFFC79A6B),
    iconMood: Color(0xFFC79A6B),
    iconCalendar: Color(0xFFC79A6B),
    iconPost: Color(0xFFC79A6B),
    navActiveBg: Color(0xFF362822),
    navActiveIcon: Color(0xFFD9B489), // латте чуть светлее для активного состояния
    promptButtonColor: Color(0xFFC79A6B), // «Я скучаю» — латте, белый текст поверх
    timerDialBackground: Color(0xFF362822), // дорожка таймера / фон ячейки «сегодня»
    isPremium: true,
    price: 30,
    // ── тёмные токены (кремово-молочный текст, тёплый подтон, muted до нормы AA) ─
    brightness: Brightness.dark,
    textPrimary: Color(0xFFF3E9E1),
    textSecondary: Color(0xFFC2B0A4),
    textMuted: Color(0xFFA08C7E), // поднят до AA (≈5.1 на карточке)
    // Темнее cardSurface (#2A1E19): scaffold-фон экранов темнее карточек
    // (правильная иерархия dark), а поля/чипы на карточке — «утоплены».
    surfaceMuted: Color(0xFF130D0B),
    divider: Color(0xFF40312A),
    useGlow: false, // матовый нуар: никаких свечений-ореолов
  );

  // ── 22: Тёмный лес (хвойный уголь + мшистый шалфей) ──────────────────────
  // Тёмная тема с зелёным подтоном (G — старший канал в базе, читается «лесной»,
  // не нейтральной). Слои — глубокий еловый уголь с видимой лестницей элевации
  // (ΔL*≈8 фон→карточка). Акцент — мшисто-шалфейный зелёный средней светлоты:
  // белый текст поверх заливок читается (паритет с тилом/кофе), контраст как
  // иконка ≈6.2 на карточке. Полный набор тёмных токенов, матовые рёбра.
  static const forestDark = AppTheme(
    index: 22,
    name: 'Тёмный лес',
    primary: Color(0xFF6EAE84),
    primaryLight: Color(0xFF18201B),
    bgGradient: [Color(0xFF0F1611), Color(0xFF080C09)], // глубокий хвойный уголь
    heroGradient: [Color(0xFF232C27), Color(0xFF141A16)],
    heroShadowBase: Color(0x59000000),
    heroShadowExpanded: Color(0x73000000),
    heroGlassOpacity: 0.10,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFF6EAE84),
    cardSurface: Color(0xFF19211C), // мшистая поверхность, ΔL*≈8 над фоном
    cardBorder: Color(0xFF2F3A34),
    iconDraw: Color(0xFF6EAE84),
    iconMood: Color(0xFF6EAE84),
    iconCalendar: Color(0xFF6EAE84),
    iconPost: Color(0xFF6EAE84),
    navActiveBg: Color(0xFF26302A),
    navActiveIcon: Color(0xFF8FC7A3), // шалфей чуть светлее для активного
    promptButtonColor: Color(0xFF6EAE84),
    timerDialBackground: Color(0xFF26302A),
    isPremium: true,
    price: 30,
    brightness: Brightness.dark,
    textPrimary: Color(0xFFEAF1EC),
    textSecondary: Color(0xFFAEB8B1),
    textMuted: Color(0xFF8A9A8F), // AA (≈5.5 на карточке)
    surfaceMuted: Color(0xFF0B0F0C),
    divider: Color(0xFF2F3A34),
    useGlow: false,
  );

  // ── 23: Гранат (винный уголь + мягкий красный) ───────────────────────────
  // Тёмная тема тёплого винного семейства (тёмная родня светлой «Бордовой»).
  // Фон — глубокий винный уголь (R — старший канал), лестница элевации ΔL*≈8.
  // Акцент — МЯГКИЙ приглушённый красно-коралловый (не кричащий алый — спокойнее
  // на тёмном): средней светлоты, белый текст поверх читается, контраст как
  // иконка ≈5.6 на карточке. Полный набор тёмных токенов, матовые рёбра.
  static const garnetDark = AppTheme(
    index: 23,
    name: 'Гранат',
    primary: Color(0xFFD67B80),
    primaryLight: Color(0xFF221618),
    bgGradient: [Color(0xFF1A0F10), Color(0xFF0D0708)], // глубокий винный уголь
    heroGradient: [Color(0xFF2E1F20), Color(0xFF1A1213)],
    heroShadowBase: Color(0x59000000),
    heroShadowExpanded: Color(0x73000000),
    heroGlassOpacity: 0.10,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFFD67B80),
    cardSurface: Color(0xFF241819), // винный мокко, ΔL*≈8 над фоном
    cardBorder: Color(0xFF3A2A2B),
    iconDraw: Color(0xFFD67B80),
    iconMood: Color(0xFFD67B80),
    iconCalendar: Color(0xFFD67B80),
    iconPost: Color(0xFFD67B80),
    navActiveBg: Color(0xFF312223),
    navActiveIcon: Color(0xFFE79EA2), // мягкий красный светлее для активного
    promptButtonColor: Color(0xFFD67B80),
    timerDialBackground: Color(0xFF312223),
    isPremium: true,
    price: 30,
    brightness: Brightness.dark,
    textPrimary: Color(0xFFF2E7E7),
    textSecondary: Color(0xFFC0ABAC),
    textMuted: Color(0xFFA08A8C), // AA (≈5.4 на карточке)
    surfaceMuted: Color(0xFF120C0D),
    divider: Color(0xFF3A2A2B),
    useGlow: false,
  );

  // ── 24: Тёмный мёд (янтарный уголь + глубокое золото) ─────────────────────
  // Тёмная тема тёплого золотого семейства (тёмная родня светлой «Медовой»).
  // Фон — тёмный янтарно-жёлтый уголь (жёлтый подтон, отличим от красно-коричне-
  // вого «Кофе»), лестница элевации ΔL*≈8. Акцент — ГЛУБОКОЕ золото-янтарь: мёд
  // светлый сам по себе, поэтому взят насыщённее/темнее, чтобы белый текст поверх
  // заливок читался (паритет), контраст как иконка ≈6.1 на карточке. Активная
  // иконка — яркий медовый блик. Полный набор тёмных токенов, матовые рёбра.
  static const honeyDark = AppTheme(
    index: 24,
    name: 'Тёмный мёд',
    primary: Color(0xFFC8912E),
    primaryLight: Color(0xFF221B0E),
    bgGradient: [Color(0xFF1B1408), Color(0xFF0E0A05)], // тёмный янтарный уголь
    heroGradient: [Color(0xFF2F2713), Color(0xFF1B160A)],
    heroShadowBase: Color(0x59000000),
    heroShadowExpanded: Color(0x73000000),
    heroGlassOpacity: 0.10,
    heroToggleBorder: true,
    heroToggleSelectedColor: Color(0xFFC8912E),
    cardSurface: Color(0xFF241D10), // медовый мокко, ΔL*≈8 над фоном
    cardBorder: Color(0xFF3A3018),
    iconDraw: Color(0xFFC8912E),
    iconMood: Color(0xFFC8912E),
    iconCalendar: Color(0xFFC8912E),
    iconPost: Color(0xFFC8912E),
    navActiveBg: Color(0xFF302816),
    navActiveIcon: Color(0xFFE3B457), // яркий медовый блик для активного
    promptButtonColor: Color(0xFFC8912E),
    timerDialBackground: Color(0xFF302816),
    isPremium: true,
    price: 30,
    brightness: Brightness.dark,
    textPrimary: Color(0xFFF3ECDF),
    textSecondary: Color(0xFFC4B49B),
    textMuted: Color(0xFF9C8E76), // AA (≈5.3 на карточке)
    surfaceMuted: Color(0xFF100C05),
    divider: Color(0xFF3A3018),
    useGlow: false,
  );

  // ── Список всех тем (порядок = индекс) ───────────────────────────────────
  static const List<AppTheme> all = [
    pink,
    purple,
    blue,
    orange,
    green,
    midnight,
    lavender,
    cherry,
    mint,
    sunset,
    monochrome,
    forest,
    ocean,
    honey,
    lemon,
    sand,
    aurora,
    bordeaux,
    teal,
    nord,
    warmRoseDark, // 20 — тёмная тема (нейтральный уголь + спокойный тил)
    coffeeDark, // 21 — тёмная тема (эспрессо + карамельный латте)
    forestDark, // 22 — тёмная тема (хвойный уголь + мшистый шалфей)
    garnetDark, // 23 — тёмная тема (винный уголь + мягкий красный)
    honeyDark, // 24 — тёмная тема (янтарный уголь + глубокое золото)
  ];

  /// Найти тему по индексу; при выходе за границы — возвращает [pink]
  static AppTheme byIndex(int index) {
    if (index >= 0 && index < all.length) return all[index];
    return pink;
  }

  /// Читаемый цвет переднего плана (текст/иконка) ПОВЕРХ акцентного фона
  /// [background]. Тёмный на светлых поверхностях, белый на тёмных/насыщенных.
  ///
  /// Нужен, чтобы паттерн «белый текст на акценте» не исчезал, когда сам акцент
  /// светлый — это характерно для тёмных тем, где `navActiveIcon`/`primary`
  /// намеренно почти белые (светлое-на-тёмном). Порог 0.6 подобран так, что все
  /// средне-тональные акценты 20 светлых тем (макс. яркость ≈0.45) остаются с
  /// белым текстом — прежний вид не меняется, — а почти-белые акценты тёмных тем
  /// получают тёмный текст. Работает для любых будущих тем без правок виджетов.
  static Color onColor(Color background) =>
      background.computeLuminance() > 0.6
          ? const Color(0xFF1B1B1D)
          : Colors.white;
}
