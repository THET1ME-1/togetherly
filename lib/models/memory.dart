import 'dart:convert';

import 'package:pocketbase/pocketbase.dart';

/// Types of memory content
enum MemoryType { photo, video, location, music, text, videoLink, book, movie }

/// A single memory entry in the shared Memory Lane
class Memory {
  final String id;
  final String groupId;
  final String authorUid;
  final String authorName;
  final String authorAvatar;
  final MemoryType type;
  final DateTime createdAt;
  DateTime? editedAt;

  // Content fields (used depending on type)
  String? imageUrl; // photo / video thumbnail
  List<String>? imageUrls; // array of photos
  String? videoUrl; // video URL
  String? title; // user-set title/name
  String? caption; // text description
  String? locationName; // e.g. "Central Park Coffee"
  double? latitude;
  double? longitude;
  String? musicTitle; // song name
  String? musicArtist; // artist name
  String? musicUrl; // external link (Spotify, YouTube, etc.) or local file path
  String? musicCoverUrl; // album art

  // Book fields (used for MemoryType.book). Title reuses [title].
  String? bookAuthor; // author(s)
  String? bookCoverUrl; // cover image URL from the books API
  String? bookYear; // publication year
  String? bookPublisher; // publisher name
  String? bookInfoUrl; // link to the book page (Google Books / Open Library)

  // Movie / series fields (used for MemoryType.movie). Title reuses [title]
  // for the localized (Russian) name.
  String? movieOriginalTitle; // original / English name (alternativeName)
  String? moviePosterUrl; // poster image URL from the movies API (TMDB/Kinopoisk)
  String? movieYear; // release year (or "2020–2024" for series)
  String? movieKind; // raw kind: movie / tv-series / cartoon / anime / animated-series
  String? movieGenres; // comma-joined genres ("драма, мелодрама")
  String? movieCountry; // primary country
  String? movieRatingKp; // external rating (e.g. Kinopoisk "7.5")
  String? movieInfoUrl; // link to the movie page (kinopoisk.ru)

  /// User's personal 1–10 rating for this memory. Shared between books and
  /// movies (the "оценка"). The accompanying review text reuses [caption].
  int? rating;

  bool isPinned;
  bool isAdult;

  /// Секретное воспоминание — скрыто из ленты, пока не введён PIN. Живёт в
  /// json-поле `data` (как [isAdult]) → синкается без изменения схемы PB.
  bool isSecret;

  /// «Капсула времени»: запечатано до [openAt] — до этой даты контент скрыт
  /// (карточка-замок), после — раскрывается как обычное воспоминание.
  bool sealed;

  /// Дата открытия капсулы (для [sealed]). null у обычных воспоминаний.
  DateTime? openAt;

  /// UID'ы пользователей, добавивших это воспоминание в «Избранное» (закладка).
  /// Персонально: каждый партнёр видит свой набор закладок.
  List<String> savedBy;

  /// Кэш числа комментариев (для бейджа в ленте — чтобы не подписываться на
  /// комментарии каждой карточки). Инкрементится при добавлении комментария.
  int commentsCount;

  bool isSavedBy(String uid) => uid.isNotEmpty && savedBy.contains(uid);

  /// Капсула ещё запечатана в момент [now] (по умолчанию — сейчас): помечена
  /// [sealed], задана [openAt] и эта дата ещё не наступила. Логика вынесена в
  /// геттер, чтобы её можно было покрыть тестами и переиспользовать в ленте.
  bool sealedNow([DateTime? now]) =>
      sealed && openAt != null && (now ?? DateTime.now()).isBefore(openAt!);

  /// Это капсула, которая уже раскрылась (была запечатана, дата наступила).
  bool openedCapsuleAt([DateTime? now]) =>
      sealed && openAt != null && !(now ?? DateTime.now()).isBefore(openAt!);

  Memory({
    required this.id,
    required this.groupId,
    required this.authorUid,
    required this.authorName,
    this.authorAvatar = '',
    required this.type,
    required this.createdAt,
    this.editedAt,
    this.imageUrl,
    this.imageUrls,
    this.videoUrl,
    this.title,
    this.caption,
    this.locationName,
    this.latitude,
    this.longitude,
    this.musicTitle,
    this.musicArtist,
    this.musicUrl,
    this.musicCoverUrl,
    this.bookAuthor,
    this.bookCoverUrl,
    this.bookYear,
    this.bookPublisher,
    this.bookInfoUrl,
    this.movieOriginalTitle,
    this.moviePosterUrl,
    this.movieYear,
    this.movieKind,
    this.movieGenres,
    this.movieCountry,
    this.movieRatingKp,
    this.movieInfoUrl,
    this.rating,
    this.isPinned = false,
    this.isAdult = false,
    this.isSecret = false,
    this.sealed = false,
    this.openAt,
    List<String>? savedBy,
    int? commentsCount,
  })  : savedBy = savedBy ?? <String>[],
        commentsCount = commentsCount ?? 0;

  /// Human-friendly type label
  String get typeLabel {
    switch (type) {
      case MemoryType.photo:
        return 'Photo';
      case MemoryType.video:
        return 'Video';
      case MemoryType.location:
        return 'Location';
      case MemoryType.music:
        return 'Music';
      case MemoryType.text:
        return 'Note';
      case MemoryType.videoLink:
        return 'Video Link';
      case MemoryType.book:
        return 'Book';
      case MemoryType.movie:
        return 'Movie';
    }
  }

  String get typeEmoji {
    switch (type) {
      case MemoryType.photo:
        return '📷';
      case MemoryType.video:
        return '🎬';
      case MemoryType.location:
        return '📍';
      case MemoryType.music:
        return '🎵';
      case MemoryType.text:
        return '📝';
      case MemoryType.videoLink:
        return '🎬';
      case MemoryType.book:
        return '📚';
      case MemoryType.movie:
        return '🎬';
    }
  }

  /// Local JSON serialization
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'groupId': groupId,
      'authorUid': authorUid,
      'authorName': authorName,
      'authorAvatar': authorAvatar,
      'type': type.name,
      'createdAt': createdAt.toIso8601String(),
      'editedAt': editedAt?.toIso8601String(),
      'imageUrl': imageUrl,
      'imageUrls': imageUrls,
      'videoUrl': videoUrl,
      'title': title,
      'caption': caption,
      'locationName': locationName,
      'latitude': latitude,
      'longitude': longitude,
      'musicTitle': musicTitle,
      'musicArtist': musicArtist,
      'musicUrl': musicUrl,
      'musicCoverUrl': musicCoverUrl,
      'bookAuthor': bookAuthor,
      'bookCoverUrl': bookCoverUrl,
      'bookYear': bookYear,
      'bookPublisher': bookPublisher,
      'bookInfoUrl': bookInfoUrl,
      'movieOriginalTitle': movieOriginalTitle,
      'moviePosterUrl': moviePosterUrl,
      'movieYear': movieYear,
      'movieKind': movieKind,
      'movieGenres': movieGenres,
      'movieCountry': movieCountry,
      'movieRatingKp': movieRatingKp,
      'movieInfoUrl': movieInfoUrl,
      'rating': rating,
      'isPinned': isPinned,
      'isAdult': isAdult,
      'isSecret': isSecret,
      'sealed': sealed,
      'openAt': openAt?.toIso8601String(),
      'savedBy': savedBy,
      'commentsCount': commentsCount,
    };
  }

  factory Memory.fromJson(Map<String, dynamic> json) {
    return Memory(
      id: json['id'] ?? '',
      groupId: json['groupId'] ?? '',
      authorUid: json['authorUid'] ?? '',
      authorName: json['authorName'] ?? '',
      authorAvatar: json['authorAvatar'] ?? '',
      type: MemoryType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => MemoryType.text,
      ),
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      editedAt: json['editedAt'] != null
          ? DateTime.tryParse(json['editedAt'])
          : null,
      imageUrl: json['imageUrl'],
      imageUrls: json['imageUrls'] != null
          ? List<String>.from(json['imageUrls'])
          : null,
      videoUrl: json['videoUrl'],
      title: json['title'],
      caption: json['caption'],
      locationName: json['locationName'],
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      musicTitle: json['musicTitle'],
      musicArtist: json['musicArtist'],
      musicUrl: json['musicUrl'],
      musicCoverUrl: json['musicCoverUrl'],
      bookAuthor: json['bookAuthor'],
      bookCoverUrl: json['bookCoverUrl'],
      bookYear: json['bookYear'],
      bookPublisher: json['bookPublisher'],
      bookInfoUrl: json['bookInfoUrl'],
      movieOriginalTitle: json['movieOriginalTitle'],
      moviePosterUrl: json['moviePosterUrl'],
      movieYear: json['movieYear'],
      movieKind: json['movieKind'],
      movieGenres: json['movieGenres'],
      movieCountry: json['movieCountry'],
      movieRatingKp: json['movieRatingKp'],
      movieInfoUrl: json['movieInfoUrl'],
      rating: (json['rating'] as num?)?.toInt(),
      isPinned: json['isPinned'] ?? false,
      isAdult: json['isAdult'] ?? false,
      isSecret: json['isSecret'] ?? false,
      sealed: json['sealed'] ?? false,
      openAt: json['openAt'] != null ? DateTime.tryParse(json['openAt']) : null,
      savedBy: json['savedBy'] != null
          ? List<String>.from(json['savedBy'])
          : null,
      commentsCount: (json['commentsCount'] as num?)?.toInt(),
    );
  }

  /// PocketBase-запись (коллекция `memories`) → модель. Строка PB хранит полную
  /// camelCase-карту в json-поле `data` (с ISO-датами), поэтому переиспользуем
  /// [Memory.fromJson]. id берём из записи; даты/флаги — из data, при отсутствии
  /// падаем на индексированные колонки (`created_at`/`edited_at`/`is_pinned`).
  factory Memory.fromPb(RecordModel rec) {
    final raw = rec.data['data'];
    // Обычно PB-SDK уже отдаёт json-колонку как Map. Защитно: если прилетела
    // json-СТРОКА — декодируем, иначе НЕ теряем все поля (тип/фото/координаты).
    final map = raw is Map
        ? Map<String, dynamic>.from(raw)
        : (raw is String && raw.isNotEmpty
            ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
            : <String, dynamic>{});
    map['id'] = rec.id;
    map['createdAt'] ??= rec.data['created_at'];
    if (map['editedAt'] == null && rec.data['edited_at'] != null) {
      map['editedAt'] = rec.data['edited_at'];
    }
    map['isPinned'] ??= rec.data['is_pinned'];
    return Memory.fromJson(map);
  }
}
