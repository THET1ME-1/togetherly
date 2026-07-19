import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Лёгкий ИНЛАЙНОВЫЙ Markdown для пузырей чата — без внешних зависимостей и без
/// блочной разметки (заголовки/списки/цитаты), которая распирала бы компактный
/// пузырь. Всё наследует цвет и размер [style] (важно: текст авто-контрастный к
/// цвету пузыря), ссылки открываются во внешнем браузере.
///
/// Поддерживается:
///   **жирный**            *курсив*            ~~зачёркнутый~~
///   `моноширинный`        [текст](https://…)  «голая» ссылка http(s)://…
///
/// Экранирование: `\*` `\_` `` \` `` `\~` `\\` — символ выводится буквально.
///
/// Парсер [buildSpans] — сканер «самого раннего совпадения»: на каждой позиции
/// берём правило, чьё совпадение начинается левее (при равном старте — по
/// приоритету списка [_rules]), содержимое рекурсивно доразбираем (жирный внутри
/// курсива и т.п.). Ссылки не рекурсятся по URL, код — не рекурсится вовсе.
/// TapGestureRecognizer живёт ровно один build (пересоздаём и освобождаем
/// прошлые) — иначе утечка при перестроении списка на прокрутке.
class MdMessageText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const MdMessageText(this.text, {super.key, required this.style});

  @override
  State<MdMessageText> createState() => _MdMessageTextState();

  /// Разбирает [text] в инлайновые спаны поверх [base]. [onLink]/[recognizers]
  /// опциональны: без них ссылки рендерятся как подчёркнутый текст без нажатия
  /// (удобно для юнит-тестов).
  static List<InlineSpan> buildSpans(
    String text,
    TextStyle base, {
    void Function(String url)? onLink,
    List<TapGestureRecognizer>? recognizers,
  }) {
    // Быстрый путь: в тексте нет ни одного спецсимвола разметки → отдаём обычный
    // спан без сканера. Подавляющее большинство сообщений такие — на прокрутке
    // это экономит запуск всех регэкспов на каждый кадр.
    if (!_markup.hasMatch(text)) {
      return [TextSpan(text: text, style: base)];
    }

    final out = <InlineSpan>[];
    var pos = 0;
    while (pos < text.length) {
      _Hit? best;
      for (var r = 0; r < _rules.length; r++) {
        final m = _rules[r].re.firstMatch(text.substring(pos));
        if (m == null) continue;
        final start = pos + m.start;
        if (best == null || start < best.start) {
          best = _Hit(r, start, pos + m.end, m);
        }
      }

      if (best == null) {
        // Дальше разметки нет — остаток как есть.
        out.add(TextSpan(text: text.substring(pos), style: base));
        break;
      }

      if (best.start > pos) {
        out.add(TextSpan(text: text.substring(pos, best.start), style: base));
      }
      out.add(_rules[best.rule].build(best.match, base, onLink, recognizers));
      pos = best.end;
    }
    return out;
  }

  /// Есть ли в тексте хоть один потенциальный маркер разметки (для быстрого пути).
  static final RegExp _markup = RegExp(r'''[*_~`\[\\]|https?://''');

  static final List<_Rule> _rules = [
    // Экранирование `\X` — высший приоритет: следующий символ выводится буквально
    // (в т.ч. в «обычном» участке перед другой разметкой).
    _Rule(
      RegExp(r'\\(.)'),
      (m, base, onLink, recs) => TextSpan(text: m.group(1), style: base),
    ),
    // Код — без рекурсии внутрь (внутри разметка не действует).
    _Rule(
      RegExp(r'`([^`\n]+)`'),
      (m, base, onLink, recs) => TextSpan(
        text: m.group(1),
        style: base.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Courier', 'monospace'],
          backgroundColor: base.color?.withOpacity(0.14),
        ),
      ),
    ),
    // [текст](url)
    _Rule(
      RegExp(r'\[([^\]\n]+)\]\((https?://[^)\s]+)\)'),
      (m, base, onLink, recs) =>
          _link(m.group(1)!, m.group(2)!, base, onLink, recs),
    ),
    // **жирный**
    _Rule(
      RegExp(r'\*\*(?=\S)(.+?)(?<=\S)\*\*'),
      (m, base, onLink, recs) => TextSpan(
        children: buildSpans(m.group(1)!, base.copyWith(fontWeight: FontWeight.w700),
            onLink: onLink, recognizers: recs),
      ),
    ),
    // __жирный__
    _Rule(
      RegExp(r'__(?=\S)(.+?)(?<=\S)__'),
      (m, base, onLink, recs) => TextSpan(
        children: buildSpans(m.group(1)!, base.copyWith(fontWeight: FontWeight.w700),
            onLink: onLink, recognizers: recs),
      ),
    ),
    // ~~зачёркнутый~~
    _Rule(
      RegExp(r'~~(?=\S)(.+?)(?<=\S)~~'),
      (m, base, onLink, recs) => TextSpan(
        children: buildSpans(
            m.group(1)!, base.copyWith(decoration: TextDecoration.lineThrough),
            onLink: onLink, recognizers: recs),
      ),
    ),
    // *курсив* — без пробела сразу за/перед звёздочкой (чтобы «5 * 3» не ловилось).
    _Rule(
      RegExp(r'\*(?=\S)([^*\n]+?)(?<=\S)\*'),
      (m, base, onLink, recs) => TextSpan(
        children: buildSpans(
            m.group(1)!, base.copyWith(fontStyle: FontStyle.italic),
            onLink: onLink, recognizers: recs),
      ),
    ),
    // «Голая» http(s)-ссылка. Завершающую пунктуацию (. , ) ] и т.п.) не съедаем.
    _Rule(
      RegExp(r'https?://[^\s<]*[^\s<.,;:!?)\]}>"]'),
      (m, base, onLink, recs) =>
          _link(m.group(0)!, m.group(0)!, base, onLink, recs),
    ),
  ];

  static InlineSpan _link(
    String label,
    String url,
    TextStyle base,
    void Function(String url)? onLink,
    List<TapGestureRecognizer>? recs,
  ) {
    final style = base.copyWith(decoration: TextDecoration.underline);
    TapGestureRecognizer? recognizer;
    if (onLink != null) {
      recognizer = TapGestureRecognizer()..onTap = () => onLink(url);
      recs?.add(recognizer);
    }
    return TextSpan(text: label, style: style, recognizer: recognizer);
  }
}

class _MdMessageTextState extends State<MdMessageText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    // Прошлые распознаватели жестов больше не нужны — пересобираем спаны заново.
    _disposeRecognizers();
    final spans = MdMessageText.buildSpans(
      widget.text,
      widget.style,
      onLink: _openLink,
      recognizers: _recognizers,
    );
    return Text.rich(TextSpan(children: spans, style: widget.style));
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {/* нет обработчика ссылки — молча игнорируем */}
  }
}

class _Rule {
  final RegExp re;
  final InlineSpan Function(
    RegExpMatch m,
    TextStyle base,
    void Function(String url)? onLink,
    List<TapGestureRecognizer>? recs,
  ) build;
  const _Rule(this.re, this.build);
}

class _Hit {
  final int rule;
  final int start;
  final int end;
  final RegExpMatch match;
  const _Hit(this.rule, this.start, this.end, this.match);
}
