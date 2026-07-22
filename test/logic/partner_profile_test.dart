import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/partner_profile.dart';

void main() {
  group('полка подарков', () {
    test('считает одинаковые подарки и сортирует по убыванию', () {
      final shelf = tallyGifts([
        {'gift_key': 'heart'},
        {'gift_key': 'hug'},
        {'gift_key': 'heart'},
        {'gift_key': 'heart'},
        {'gift_key': 'hug'},
        {'gift_key': 'cake'},
      ]);
      expect(shelf.map((t) => t.key).toList(), ['heart', 'hug', 'cake']);
      expect(shelf.first.count, 3);
      expect(shelf.last.count, 1);
    });

    test('подарок из будущей версии не роняет полку, а пропускается', () {
      final shelf = tallyGifts([
        {'gift_key': 'heart'},
        {'gift_key': 'подарок-которого-нет'},
      ]);
      expect(shelf.length, 1);
      expect(shelf.single.key, 'heart');
    });

    test('пустой список даёт пустую полку', () {
      expect(tallyGifts(const []), isEmpty);
    });

    test('общее число подарков считается по всем записям', () {
      final shelf = tallyGifts([
        {'gift_key': 'heart'},
        {'gift_key': 'heart'},
        {'gift_key': 'star'},
      ]);
      expect(shelf.fold<int>(0, (s, t) => s + t.count), 3);
    });
  });

  group('«скучаю» по дням недели', () {
    test('разбирает карту дней в семь чисел от понедельника', () {
      final w = parseWeekdays('{"1":4,"2":9,"5":11,"7":7}');
      expect(w.byDay, [4, 9, 0, 0, 11, 0, 7]);
      expect(w.total, 31);
      expect(w.topDay, 5); // пятница
    });

    test('пустая история даёт нули и отсутствие пика', () {
      final w = parseWeekdays(null);
      expect(w.byDay, [0, 0, 0, 0, 0, 0, 0]);
      expect(w.total, 0);
      expect(w.topDay, isNull);
      expect(w.isEmpty, isTrue);
    });

    test('битые данные не роняют экран', () {
      final w = parseWeekdays('это не json');
      expect(w.total, 0);
      expect(w.isEmpty, isTrue);
    });

    test('дни вне диапазона 1..7 игнорируются', () {
      final w = parseWeekdays('{"0":5,"8":3,"3":2}');
      expect(w.byDay, [0, 0, 2, 0, 0, 0, 0]);
      expect(w.total, 2);
    });

    test('при равенстве пиком считается более ранний день', () {
      final w = parseWeekdays('{"2":5,"6":5}');
      expect(w.topDay, 2);
    });
  });
}
