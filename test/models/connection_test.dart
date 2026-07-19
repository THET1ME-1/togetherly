import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/connection.dart';

void main() {
  // ────────────────────────────────────────────────────────────────────────────
  // GroupMember
  // ────────────────────────────────────────────────────────────────────────────
  group('GroupMember — toJson / fromJson', () {
    test('round-trip preserves all fields', () {
      const member = GroupMember(
        uid: 'uid-123',
        name: 'Alice',
        avatar: 'https://example.com/alice.jpg',
      );
      final json = member.toJson();
      final restored = GroupMember.fromJson(json);

      expect(restored.uid, 'uid-123');
      expect(restored.name, 'Alice');
      expect(restored.avatar, 'https://example.com/alice.jpg');
    });

    test('missing fields fall back to empty strings', () {
      final restored = GroupMember.fromJson({'uid': 'u1'});
      expect(restored.uid, 'u1');
      expect(restored.name, '');
      expect(restored.avatar, '');
    });

    test('empty uid is preserved', () {
      final restored = GroupMember.fromJson({});
      expect(restored.uid, '');
    });

    test('toJson contains expected keys', () {
      const member = GroupMember(uid: 'u1', name: 'Bob', avatar: 'a.jpg');
      final json = member.toJson();
      expect(json.containsKey('uid'), isTrue);
      expect(json.containsKey('name'), isTrue);
      expect(json.containsKey('avatar'), isTrue);
    });
  });

  // ────────────────────────────────────────────────────────────────────────────
  // MemberMood
  // ────────────────────────────────────────────────────────────────────────────
  group('MemberMood — isToday / isEmpty / isNotEmpty', () {
    test('mood updated today is not empty', () {
      final mood = MemberMood(
        imagePath: 'assets/images/emoji/007-happy.png',
        label: 'Happy',
        updatedAt: DateTime.now(),
      );
      expect(mood.isToday, isTrue);
      expect(mood.isEmpty, isFalse);
      expect(mood.isNotEmpty, isTrue);
    });

    test('mood updated yesterday is empty', () {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final mood = MemberMood(
        imagePath: 'assets/images/emoji/007-happy.png',
        label: 'Happy',
        updatedAt: yesterday,
      );
      expect(mood.isToday, isFalse);
      expect(mood.isEmpty, isTrue);
      expect(mood.isNotEmpty, isFalse);
    });

    test('mood without updatedAt is empty', () {
      const mood = MemberMood(imagePath: 'a.png', label: 'X');
      expect(mood.isToday, isFalse);
      expect(mood.isEmpty, isTrue);
    });

    test('default MemberMood is empty', () {
      const mood = MemberMood();
      expect(mood.imagePath, isEmpty);
      expect(mood.label, isEmpty);
      expect(mood.isEmpty, isTrue);
    });

    test('fromJson restores imagePath and label', () {
      final mood = MemberMood.fromJson({
        'imagePath': 'assets/images/emoji/007-happy.png',
        'label': 'Happy',
        'updatedAt': DateTime.now(),
      });
      expect(mood.imagePath, 'assets/images/emoji/007-happy.png');
      expect(mood.label, 'Happy');
    });

    test('fromJson uses legacy emoji key when imagePath absent', () {
      final mood = MemberMood.fromJson({
        'emoji': 'assets/images/emoji/001-sad.png',
        'label': 'Sad',
      });
      expect(mood.imagePath, 'assets/images/emoji/001-sad.png');
    });

    test('isToday is false when updatedAt is null', () {
      const mood = MemberMood(imagePath: 'x.png', label: 'test');
      expect(mood.isToday, isFalse);
    });

    test('mood updated exactly at midnight today is today', () {
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      final mood = MemberMood(
        imagePath: 'a.png',
        label: 'x',
        updatedAt: midnight,
      );
      expect(mood.isToday, isTrue);
    });
  });
}
