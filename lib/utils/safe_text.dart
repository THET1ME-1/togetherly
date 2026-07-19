import 'package:characters/characters.dart';

/// Безопасная работа с пользовательским текстом ПО ГРАФЕМАМ, а не по code units.
///
/// Индексация строки `s[0]` или `s.substring(0, n)` режет суррогатную пару
/// UTF-16 пополам, если на границе стоит эмодзи (а имена/подписи у пар часто
/// начинаются с эмодзи). Полученный «полусимвол» при рендере в `Text` бросает
/// `ArgumentError: Invalid argument(s): string is not well-formed UTF-16` в
/// `RenderParagraph.performLayout`. См. Bugsink (issue ArgumentError).
extension SafeText on String {
  /// Первая ГРАФЕМА (эмодзи целиком) в верхнем регистре — для аватарок-инициалов.
  /// [fallback] возвращается, если строка пустая.
  String firstGraphemeUpper([String fallback = '?']) {
    final t = trim();
    if (t.isEmpty) return fallback;
    return t.characters.first.toUpperCase();
  }

  /// Обрезка до [n] графем без разрыва эмодзи. [ellipsis] добавляется только
  /// если строка реально длиннее [n].
  String truncateGraphemes(int n, {String ellipsis = ''}) {
    final chars = characters;
    if (chars.length <= n) return this;
    return chars.take(n).toString() + ellipsis;
  }
}
