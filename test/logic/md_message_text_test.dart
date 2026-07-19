import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/widgets/md_message_text.dart';

/// Плоский лист: текст + активные начертания. Наследование стиля проверяем,
/// схлопывая дерево спанов и складывая эффекты родителей.
class _Leaf {
  final String text;
  final bool bold;
  final bool italic;
  final bool strike;
  final bool mono;
  final bool underline; // = ссылка
  _Leaf(this.text, this.bold, this.italic, this.strike, this.mono, this.underline);
  @override
  String toString() =>
      '"$text"${bold ? " b" : ""}${italic ? " i" : ""}${strike ? " s" : ""}'
      '${mono ? " m" : ""}${underline ? " u" : ""}';
}

List<_Leaf> _flatten(List<InlineSpan> spans, [TextStyle inherited = const TextStyle()]) {
  final out = <_Leaf>[];
  void walk(InlineSpan span, TextStyle acc) {
    if (span is TextSpan) {
      final merged = acc.merge(span.style);
      if (span.text != null && span.text!.isNotEmpty) {
        out.add(_Leaf(
          span.text!,
          (merged.fontWeight?.index ?? FontWeight.w400.index) >= FontWeight.w700.index,
          merged.fontStyle == FontStyle.italic,
          merged.decoration == TextDecoration.lineThrough,
          merged.fontFamily == 'monospace',
          merged.decoration == TextDecoration.underline,
        ));
      }
      for (final c in span.children ?? const <InlineSpan>[]) {
        walk(c, merged);
      }
    }
  }

  for (final s in spans) {
    walk(s, inherited);
  }
  return out;
}

List<_Leaf> _parse(String text) => _flatten(
      MdMessageText.buildSpans(text, const TextStyle(color: Color(0xFF000000))),
    );

void main() {
  test('обычный текст — один лист без начертаний', () {
    final r = _parse('привет, как дела?');
    expect(r.length, 1);
    expect(r.first.text, 'привет, как дела?');
    expect(r.first.bold, false);
    expect(r.first.italic, false);
  });

  test('**жирный**', () {
    final r = _parse('вот **важное** слово');
    expect(r.map((e) => e.text).join(), 'вот важное слово');
    final bold = r.firstWhere((e) => e.text == 'важное');
    expect(bold.bold, true);
    expect(r.firstWhere((e) => e.text == 'вот ').bold, false);
  });

  test('*курсив* и _подчёркиванием не путаем арифметику_', () {
    final r = _parse('это *наклонно*');
    expect(r.firstWhere((e) => e.text == 'наклонно').italic, true);
  });

  test('«5 * 3 = 15» НЕ курсив (пробел у звёздочки)', () {
    final r = _parse('5 * 3 = 15');
    expect(r.length, 1);
    expect(r.first.italic, false);
    expect(r.first.text, '5 * 3 = 15');
  });

  test('~~зачёркнутый~~', () {
    final r = _parse('~~отмена~~ плана');
    expect(r.firstWhere((e) => e.text == 'отмена').strike, true);
  });

  test('`код` — моноширинный, разметка внутри не действует', () {
    final r = _parse('запусти `a**b**c` вот так');
    final code = r.firstWhere((e) => e.text == 'a**b**c');
    expect(code.mono, true);
    expect(code.bold, false); // ** внутри кода — литералы
  });

  test('курсив внутри жирного (вложение)', () {
    final r = _parse('**а *б* в**');
    final b = r.firstWhere((e) => e.text == 'б');
    expect(b.bold, true);
    expect(b.italic, true);
    expect(r.firstWhere((e) => e.text == 'а ').bold, true);
  });

  test('[текст](url) — ссылка подчёркнута, метка = текст', () {
    final r = _parse('открой [сайт](https://example.com) сейчас');
    final link = r.firstWhere((e) => e.text == 'сайт');
    expect(link.underline, true);
    expect(r.any((e) => e.text.contains('https')), false); // сам url не показан
  });

  test('голая ссылка распознаётся, хвостовая точка снаружи', () {
    final r = _parse('см. https://example.com/page.');
    final link = r.firstWhere((e) => e.underline);
    expect(link.text, 'https://example.com/page');
    expect(r.last.text.endsWith('.'), true);
  });

  test(r'экранирование \* даёт литеральную звёздочку', () {
    final r = _parse(r'цена 5\*5');
    expect(r.map((e) => e.text).join(), 'цена 5*5');
    expect(r.every((e) => !e.italic), true);
  });

  test('незакрытый **', () {
    final r = _parse('просто ** без пары');
    expect(r.map((e) => e.text).join(), 'просто ** без пары');
    expect(r.every((e) => !e.bold), true);
  });

  testWidgets('виджет строится и переживает пересборку (без утечки жестов)',
      (tester) async {
    Widget wrap(String t) => MaterialApp(
          home: Scaffold(
            body: MdMessageText(t, style: const TextStyle(fontSize: 15)),
          ),
        );
    await tester.pumpWidget(wrap('привет **мир** и [ссылка](https://example.com)'));
    expect(find.byType(MdMessageText), findsOneWidget);
    // Пересборка с другим текстом — прошлые recognizer'ы освобождаются в build.
    await tester.pumpWidget(wrap('другой текст без разметки'));
    await tester.pumpWidget(wrap('снова `код` тут'));
    expect(tester.takeException(), isNull);
  });
}
