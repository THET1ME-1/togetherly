// Точечный смоук-тест раскладки центр-карусели «Подключения»: воспроизводит
// её структуру (Row → соло + Expanded(окно) + «плюс», окно = сосед +
// Expanded(AnimatedSwitcher→пилюля во всю ширину) + сосед) и проверяет, что
// констрейнты не падают ни в покое, ни во время перехода активной группы.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/widgets/connect_expressive.dart';

Widget _peek() => Container(
      width: 56,
      height: 56,
      decoration:
          const BoxDecoration(shape: BoxShape.circle, color: Colors.pink),
    );

Widget _centerPill(String name, Key key) => SizedBox(
      key: key,
      width: double.infinity,
      height: 56,
      child: Container(
        decoration: BoxDecoration(
            color: Colors.pinkAccent,
            borderRadius: BorderRadius.circular(28)),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                    color: Colors.green, shape: BoxShape.circle)),
            const SizedBox(width: 9),
            Flexible(
              child: Text(name,
                  maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );

Widget _carousel(String centerName, String centerId) {
  return SizedBox(
    height: 64,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _peek(),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                _peek(),
                const SizedBox(width: 8),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                                begin: const Offset(0.16, 0), end: Offset.zero)
                            .animate(anim),
                        child: child,
                      ),
                    ),
                    child: _centerPill(centerName, ValueKey('center-$centerId')),
                  ),
                ),
                const SizedBox(width: 8),
                _peek(),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _peek(),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('центр-карусель: раскладка и переход без ошибок констрейнтов',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Widget wrap(String name, String id) => MaterialApp(
          home: Scaffold(
            body: Align(
                alignment: Alignment.topCenter, child: _carousel(name, id)),
          ),
        );

    // Покой: длинный ник, узкий экран — пилюля обязана усечься, не переполнять.
    await tester.pumpWidget(wrap('Очень Длинный Ник Партнёра Плюс Ещё', 'a'));
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Переход активной группы (смена ключа) → крутим AnimatedSwitcher до конца.
    await tester.pumpWidget(wrap('Олена', 'b'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Центральная пилюля реально тянется во всю ширину окна (не схлопнулась).
    final pill = tester.getSize(find.byType(AnimatedSwitcher));
    expect(pill.width, greaterThan(120));
    expect(pill.height, closeTo(56, 1));
  });

  testWidgets('MarqueeText: короткий статичен, длинный едет — без ошибок',
      (tester) async {
    Widget box(double w, String text) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: w,
                height: 40,
                child: MarqueeText(text,
                    style: const TextStyle(fontSize: 15)),
              ),
            ),
          ),
        );

    // Влезает → статичный текст, без прокрутки.
    await tester.pumpWidget(box(320, 'Олена'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Олена'), findsOneWidget);

    // Не влезает → бегущая строка (две копии), крутится без исключений.
    await tester.pumpWidget(
        box(70, 'Очень Длинное Имя Партнёра Которое Не Влезет'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Очень Длинное'), findsWidgets);

    // Уборка: анимация бесконечная — размонтируем, чтобы тикер не «повис».
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('hero-бенто «Ступени»: колонны ровны, без ошибок констрейнтов',
      (tester) async {
    Widget tile([double? h]) => Container(
        height: h, width: double.infinity, color: const Color(0xFFECDCFF));
    final hero = Column(
      children: [
        SizedBox(
          height: 214,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 116,
                child: Column(children: [
                  Container(width: 92, height: 92, color: Colors.purple),
                  const SizedBox(height: 12),
                  Expanded(child: tile()),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(children: [
                  Expanded(child: tile()),
                  const SizedBox(height: 12),
                  SizedBox(height: 46, child: tile()),
                  const SizedBox(height: 10),
                  SizedBox(height: 46, child: tile()),
                ]),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        tile(54),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 350, child: hero),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // верхний ряд ровно 214, обе колонны одной высоты
    expect(tester.getSize(find.byType(Row).first).height, closeTo(214, 1));
  });
}
