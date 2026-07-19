import 'package:pocketbase/pocketbase.dart';
import 'mood_entry.dart';

/// Данные, которые пользователь делится через парный виджет.
///
/// Firestore path: `groups/{groupId}/widgetData/{uid}`
class WidgetData {
  final String uid;
  final String displayName;
  final String avatarUrl;

  // ── Слоты контента ──
  String status; // текстовый статус
  String moodEmoji; // путь к изображению emoji (из MoodOption)
  String moodLabel; // текстовая метка настроения
  String message; // короткое сообщение / love note
  String? photoUrl; // URL фотографии (для парного виджета)
  String? photoForPartnerUrl; // Фото, которое увидит партнёр в photo-widget
  List<String> photoForPartnerUrls; // Карусель фото для партнёра
  int photoGridCount; // 1, 2 или 4
  List<String> photoGridUrls; // URL фото для сетки
  String? musicTitle; // название песни
  String? musicArtist; // исполнитель
  String? musicUrl; // ссылка на трек
  String? musicCoverUrl; // обложка альбома
  String gender; // 'male' or 'female'
  DateTime? updatedAt;

  WidgetData({
    required this.uid,
    this.displayName = '',
    this.avatarUrl = '',
    this.status = '',
    this.moodEmoji = '',
    this.moodLabel = '',
    this.message = '',
    this.photoUrl,
    this.photoForPartnerUrl,
    this.photoForPartnerUrls = const [],
    this.photoGridCount = 1,
    this.photoGridUrls = const [],

    this.musicTitle,
    this.musicArtist,
    this.musicUrl,
    this.musicCoverUrl,
    this.gender = '',
    this.updatedAt,
  });

  /// Есть ли хоть какой-то контент
  bool get isEmpty =>
      status.isEmpty &&
      moodEmoji.isEmpty &&
      message.isEmpty &&
      photoUrl == null &&
      musicTitle == null;

  bool get hasStatus => status.isNotEmpty;
  bool get hasMood => moodEmoji.isNotEmpty;
  bool get hasMessage => message.isNotEmpty;

  /// Метка настроения на текущем языке (берётся по imagePath из MoodOption).
  String get localizedMoodLabel {
    if (moodEmoji.isEmpty) return moodLabel;
    return MoodOption.byImagePath(moodEmoji)?.localizedLabel ?? moodLabel;
  }

  bool get hasPhoto => photoUrl != null && photoUrl!.isNotEmpty;
  bool get hasMusic => musicTitle != null && musicTitle!.isNotEmpty;

  /// PocketBase-запись (коллекция `widget_data`) → модель. Плоские snake_case
  /// колонки; uid = `user_uid`. Пустые text-поля PB отдаёт как `''` → nullable
  /// слоты (photo/music) коэрсим в null, чтобы `hasPhoto`/`hasMusic` не врали.
  factory WidgetData.fromPb(RecordModel rec) {
    final d = rec.data;
    String? nz(dynamic v) =>
        (v == null || (v is String && v.isEmpty)) ? null : v.toString();
    List<String> strList(dynamic v) =>
        v is List ? v.map((e) => e.toString()).toList() : const <String>[];
    return WidgetData(
      uid: (d['user_uid'] ?? '').toString(),
      displayName: (d['display_name'] ?? '').toString(),
      avatarUrl: (d['avatar_url'] ?? '').toString(),
      status: (d['status'] ?? '').toString(),
      moodEmoji: (d['mood_emoji'] ?? '').toString(),
      moodLabel: (d['mood_label'] ?? '').toString(),
      message: (d['message'] ?? '').toString(),
      photoUrl: nz(d['photo_url']),
      photoForPartnerUrl: nz(d['photo_for_partner_url']),
      photoForPartnerUrls: strList(d['photo_for_partner_urls']),
      photoGridCount: (d['photo_grid_count'] as num?)?.toInt() ?? 1,
      photoGridUrls: strList(d['photo_grid_urls']),
      musicTitle: nz(d['music_title']),
      musicArtist: nz(d['music_artist']),
      musicUrl: nz(d['music_url']),
      musicCoverUrl: nz(d['music_cover_url']),
      gender: (d['gender'] ?? '').toString(),
      updatedAt: DateTime.tryParse((d['updated_at'] ?? '').toString()),
    );
  }

  WidgetData copyWith({
    String? uid,
    String? displayName,
    String? avatarUrl,
    String? status,
    String? moodEmoji,
    String? moodLabel,
    String? message,
    String? photoUrl,
    String? photoForPartnerUrl,
    List<String>? photoForPartnerUrls,
    String? musicTitle,
    String? musicArtist,
    String? musicUrl,
    String? musicCoverUrl,
    String? gender,
    int? photoGridCount,
    List<String>? photoGridUrls,
    DateTime? updatedAt,
  }) {
    return WidgetData(
      uid: uid ?? this.uid,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      status: status ?? this.status,
      moodEmoji: moodEmoji ?? this.moodEmoji,
      moodLabel: moodLabel ?? this.moodLabel,
      message: message ?? this.message,
      photoUrl: photoUrl ?? this.photoUrl,
      photoForPartnerUrl: photoForPartnerUrl ?? this.photoForPartnerUrl,
      photoForPartnerUrls:
          photoForPartnerUrls ?? this.photoForPartnerUrls,
      photoGridCount: photoGridCount ?? this.photoGridCount,
      photoGridUrls: photoGridUrls ?? this.photoGridUrls,
      musicTitle: musicTitle ?? this.musicTitle,
      musicArtist: musicArtist ?? this.musicArtist,
      musicUrl: musicUrl ?? this.musicUrl,
      musicCoverUrl: musicCoverUrl ?? this.musicCoverUrl,
      gender: gender ?? this.gender,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
