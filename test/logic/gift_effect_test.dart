import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/gift_effect.dart';

void main() {
  test('«Сладких снов» глушит уведомления до утра', () {
    final e = effectOf('night')!;
    expect(e.field, 'mute_until');
    expect(e.kind, GiftEffectKind.untilMorning);
  });

  test('«Солнце» встречает рассветом одно утро', () {
    final e = effectOf('sun')!;
    expect(e.field, 'sunrise_until');
    expect(e.kind, GiftEffectKind.untilMorning);
  });

  test('«Отдых» прячет счётчики на сутки', () {
    final e = effectOf('spa')!;
    expect(e.field, 'spa_until');
    expect(e.duration, const Duration(hours: 24));
  });

  test('«Огонёк» бережёт серию сутки', () {
    expect(effectOf('fire')!.field, 'streak_shield_until');
  });

  test('у подарка без эффекта его и нет', () {
    expect(effectOf('heart'), isNull);
    expect(effectOf('нетакого'), isNull);
  });

  test('эффект активен, пока не вышло время', () {
    final now = DateTime(2026, 7, 22, 12);
    expect(isEffectActive(now.add(const Duration(hours: 1)).millisecondsSinceEpoch, now),
        isTrue);
    expect(isEffectActive(now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch, now),
        isFalse);
    expect(isEffectActive(0, now), isFalse);
    expect(isEffectActive(null, now), isFalse);
  });

  test('«до утра» истекает в восемь утра следующего дня', () {
    // вечер: гасим до утра завтра
    final evening = DateTime(2026, 7, 22, 23, 30);
    expect(untilMorning(evening), DateTime(2026, 7, 23, 8));
    // ночь после полуночи: до утра этого же дня
    final night = DateTime(2026, 7, 23, 2, 15);
    expect(untilMorning(night), DateTime(2026, 7, 23, 8));
    // день: до утра завтра, иначе подарок сгорал бы сразу
    final noon = DateTime(2026, 7, 22, 13);
    expect(untilMorning(noon), DateTime(2026, 7, 23, 8));
  });
}
