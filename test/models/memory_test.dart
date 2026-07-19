import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_app/models/memory.dart';

Memory _buildMemory({
  String id = 'm1',
  MemoryType type = MemoryType.photo,
  DateTime? createdAt,
  bool isPinned = false,
  bool isAdult = false,
  String? title,
  String? caption,
}) {
  return Memory(
    id: id,
    groupId: 'g1',
    authorUid: 'u1',
    authorName: 'Alice',
    type: type,
    createdAt: createdAt ?? DateTime(2025, 4, 10, 12, 0),
    isPinned: isPinned,
    isAdult: isAdult,
    title: title,
    caption: caption,
  );
}

void main() {
  group('Memory — typeLabel', () {
    test(
      'photo',
      () => expect(_buildMemory(type: MemoryType.photo).typeLabel, 'Photo'),
    );
    test(
      'video',
      () => expect(_buildMemory(type: MemoryType.video).typeLabel, 'Video'),
    );
    test(
      'videoLink',
      () => expect(
        _buildMemory(type: MemoryType.videoLink).typeLabel,
        'Video Link',
      ),
    );
    test(
      'location',
      () =>
          expect(_buildMemory(type: MemoryType.location).typeLabel, 'Location'),
    );
    test(
      'music',
      () => expect(_buildMemory(type: MemoryType.music).typeLabel, 'Music'),
    );
    test(
      'text',
      () => expect(_buildMemory(type: MemoryType.text).typeLabel, 'Note'),
    );
  });

  group('Memory — typeEmoji', () {
    test(
      'photo emoji',
      () => expect(_buildMemory(type: MemoryType.photo).typeEmoji, '📷'),
    );
    test(
      'video emoji',
      () => expect(_buildMemory(type: MemoryType.video).typeEmoji, '🎬'),
    );
    test(
      'location emoji',
      () => expect(_buildMemory(type: MemoryType.location).typeEmoji, '📍'),
    );
    test(
      'music emoji',
      () => expect(_buildMemory(type: MemoryType.music).typeEmoji, '🎵'),
    );
    test(
      'text emoji',
      () => expect(_buildMemory(type: MemoryType.text).typeEmoji, '📝'),
    );
  });

  group('Memory — toJson / fromJson round-trip', () {
    test('all fields preserved', () {
      final original = Memory(
        id: 'test-id',
        groupId: 'group-1',
        authorUid: 'uid-1',
        authorName: 'Bob',
        authorAvatar: 'https://example.com/avatar.jpg',
        type: MemoryType.music,
        createdAt: DateTime(2025, 6, 15, 9, 30),
        title: 'Our song',
        caption: 'Playing at the beach',
        musicTitle: 'Blinding Lights',
        musicArtist: 'The Weeknd',
        musicUrl: 'https://spotify.com/track/abc',
        musicCoverUrl: 'https://example.com/cover.jpg',
        isPinned: true,
        isAdult: false,
      );

      final json = original.toJson();
      final restored = Memory.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.groupId, original.groupId);
      expect(restored.authorUid, original.authorUid);
      expect(restored.authorName, original.authorName);
      expect(restored.authorAvatar, original.authorAvatar);
      expect(restored.type, original.type);
      expect(restored.createdAt, original.createdAt);
      expect(restored.title, original.title);
      expect(restored.caption, original.caption);
      expect(restored.musicTitle, original.musicTitle);
      expect(restored.musicArtist, original.musicArtist);
      expect(restored.musicUrl, original.musicUrl);
      expect(restored.musicCoverUrl, original.musicCoverUrl);
      expect(restored.isPinned, original.isPinned);
      expect(restored.isAdult, original.isAdult);
    });

    test('location memory', () {
      final m = Memory(
        id: 'loc-1',
        groupId: 'g1',
        authorUid: 'u1',
        authorName: 'Alice',
        type: MemoryType.location,
        createdAt: DateTime(2024, 12, 31),
        locationName: 'Eiffel Tower',
        latitude: 48.8584,
        longitude: 2.2945,
      );
      final restored = Memory.fromJson(m.toJson());
      expect(restored.locationName, 'Eiffel Tower');
      expect(restored.latitude, closeTo(48.8584, 0.0001));
      expect(restored.longitude, closeTo(2.2945, 0.0001));
    });

    test('photo memory with imageUrls', () {
      final m = Memory(
        id: 'photo-1',
        groupId: 'g1',
        authorUid: 'u1',
        authorName: 'Alice',
        type: MemoryType.photo,
        createdAt: DateTime(2025, 3, 8),
        imageUrls: ['url1.jpg', 'url2.jpg', 'url3.jpg'],
      );
      final restored = Memory.fromJson(m.toJson());
      expect(restored.imageUrls, ['url1.jpg', 'url2.jpg', 'url3.jpg']);
    });

    test('unknown type falls back to text', () {
      final json = {
        'id': 'x',
        'groupId': 'g',
        'authorUid': 'u',
        'authorName': 'User',
        'authorAvatar': '',
        'type': 'nonexistent_type',
        'createdAt': DateTime(2025, 1, 1).toIso8601String(),
        'isPinned': false,
        'isAdult': false,
      };
      final m = Memory.fromJson(json);
      expect(m.type, MemoryType.text);
    });

    test('editedAt preserved', () {
      final original = _buildMemory();
      original.editedAt = DateTime(2025, 5, 20, 10, 0);
      final restored = Memory.fromJson(original.toJson());
      expect(restored.editedAt, DateTime(2025, 5, 20, 10, 0));
    });

    test('isPinned=true preserved', () {
      final m = _buildMemory(isPinned: true);
      expect(Memory.fromJson(m.toJson()).isPinned, isTrue);
    });

    test('isAdult=true preserved', () {
      final m = _buildMemory(isAdult: true);
      expect(Memory.fromJson(m.toJson()).isAdult, isTrue);
    });
  });

  group('Memory — JSON encode/decode via jsonEncode', () {
    test('survives jsonEncode + jsonDecode', () {
      final m = _buildMemory(
        type: MemoryType.text,
        title: 'Hello',
        caption: 'World',
        isPinned: true,
      );
      final encoded = jsonEncode(m.toJson());
      final decoded = Memory.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      expect(decoded.title, 'Hello');
      expect(decoded.caption, 'World');
      expect(decoded.isPinned, isTrue);
    });
  });

  group('Memory — null optional fields', () {
    test('imageUrl is null when not set', () {
      final m = _buildMemory();
      expect(m.imageUrl, isNull);
    });

    test('locationName is null when not set', () {
      final m = _buildMemory();
      expect(m.locationName, isNull);
    });
  });
}
