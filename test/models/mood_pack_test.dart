import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/mood_entry.dart';
import 'package:love_app/models/mood_pack.dart';

void main() {
  group('MoodPack catalog', () {
    test('contains classic and pink, both free', () {
      expect(MoodPack.all.map((p) => p.id), containsAll(['classic', 'pink']));
      for (final p in MoodPack.all) {
        expect(p.isFree, isTrue, reason: '${p.id} should be free for now');
        expect(p.moods, isNotEmpty, reason: '${p.id} has no moods');
      }
    });

    test('byId falls back to classic for unknown/null', () {
      expect(MoodPack.byId('nope').id, 'classic');
      expect(MoodPack.byId(null).id, 'classic');
      expect(MoodPack.byId('pink').id, 'pink');
    });

    test('classic uses the full default mood set; pink is the kawaii set', () {
      expect(MoodPack.classic.moods, same(MoodOption.all));
      expect(MoodPack.pink.moods, same(MoodOption.pinkPack));
      expect(MoodPack.pink.tileGradient, isNotNull,
          reason: 'pink stickers are transparent and need a backdrop');
      expect(MoodPack.classic.tileGradient, isNull);
    });
  });

  group('Pink pack moods', () {
    test('all point to existing mood_packs/pink webp assets', () {
      expect(MoodOption.pinkPack.length, 22);
      for (final m in MoodOption.pinkPack) {
        expect(m.imagePath, 'assets/images/mood_packs/pink/${m.id}.webp',
            reason: 'unexpected path for ${m.id}');
        expect(m.label, isNotEmpty);
        expect(m.score, inInclusiveRange(1, 5));
      }
    });

    test('pack-only moods have proper score tiers', () {
      expect(MoodOption.byId('bliss')?.score, 4);
      expect(MoodOption.byId('sleepy')?.score, 3);
      expect(MoodOption.byId('tired')?.score, 3);
      expect(MoodOption.byId('disappointed')?.score, 2);
      expect(MoodOption.byId('upset')?.score, 2);
    });
  });

  group('Registry lookups', () {
    test('byImagePath resolves pink stickers to the right mood id', () {
      final pinkHappy = MoodOption.pinkPack.firstWhere((m) => m.id == 'happy');
      expect(MoodOption.byImagePath(pinkHappy.imagePath)?.id, 'happy');
      expect(MoodOption.byImagePath('')?.id, isNull);
      expect(MoodOption.byImagePath('does/not/exist.webp'), isNull);
    });

    test('byId returns the canonical classic variant for shared ids', () {
      // 'happy' exists in both packs; classic is canonical (listed first).
      final happy = MoodOption.byId('happy');
      expect(happy, isNotNull);
      expect(happy!.imagePath, contains('new emodji'),
          reason: 'shared ids should resolve to the classic image in stats');
    });
  });
}
