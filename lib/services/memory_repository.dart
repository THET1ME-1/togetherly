import 'dart:async';

import 'package:sentry_flutter/sentry_flutter.dart';

import '../models/comment.dart';
import '../models/memory.dart';
import 'analytics_service.dart';
import 'level_service.dart';
import 'offline/local_store.dart';
import 'offline/outbox_service.dart';
import 'offline/pb_id.dart';
import 'pb_auth_service.dart';
import 'pb_data_service.dart';
import 'pb_realtime_service.dart';
import 'pocketbase_service.dart';

/// Репозиторий «Воспоминаний» поверх PocketBase + offline-first.
///
/// Чтения: живая лента из локального кэша (sembast) с фоновой синхронизацией
/// (см. [PbRealtimeService.watchMemories]). Записи: оптимистично применяются в
/// кэш (UI обновляется мгновенно) и кладутся в очередь отправки
/// ([OutboxService]); при наличии сети очередь сливается на сервер. Поэтому
/// создание/правка/удаление воспоминания работают офлайн.
class MemoryRepository {
  MemoryRepository._();
  static final MemoryRepository instance = MemoryRepository._();
  factory MemoryRepository() => instance;

  final PbDataService _data = PbDataService();
  final PbRealtimeService _rt = PbRealtimeService();
  final LocalStore _cache = LocalStore.instance;
  final OutboxService _outbox = OutboxService.instance;

  String? get _uid => PocketBaseService().userId;

  // ── Лента ────────────────────────────────────────────────────────────────
  /// Живая лента группы (новые сверху), soft-deleted скрыты. Из локального кэша.
  Stream<List<Memory>> watch(String groupId) =>
      _rt.watchMemories(groupId).map((recs) => recs.map(Memory.fromPb).toList());

  /// Точечное чтение пина (deep-link из чата). Сперва кэш, затем сеть.
  Future<Memory?> getById(String memoryId) async {
    final cached = await _cache.getRecord('memories', memoryId);
    if (cached != null && cached.data['deleted'] != true) {
      return Memory.fromPb(cached);
    }
    final rec = await _data.loadMemoryById(memoryId);
    return rec == null ? null : Memory.fromPb(rec);
  }

  /// «Сырой» ряд колонок коллекции `memories` для кэша (= тело upsertMemory без
  /// серверных id/created/updated). [Memory.fromPb] читает его без изменений.
  Map<String, dynamic> _row(String groupId, Memory m) => {
        'id': m.id,
        'group_id': groupId,
        'type': m.type.name,
        'author_uid': m.authorUid,
        'author_name': m.authorName,
        'author_avatar': m.authorAvatar,
        'created_at': m.createdAt.toIso8601String(),
        'edited_at': m.editedAt?.toIso8601String(),
        'is_pinned': m.isPinned,
        'deleted': false,
        'data': m.toJson(),
      };

  // ── Запись ───────────────────────────────────────────────────────────────
  /// Создаёт воспоминание (id генерится локально и принимается сервером).
  /// Оптимистично в кэш + в очередь. Возвращает модель с этим id.
  Future<Memory?> add({
    required String groupId,
    required String authorName,
    required String authorAvatar,
    required MemoryType type,
    String? imageUrl,
    List<String>? imageUrls,
    String? videoUrl,
    String? title,
    String? caption,
    String? locationName,
    double? latitude,
    double? longitude,
    String? musicTitle,
    String? musicArtist,
    String? musicUrl,
    String? musicCoverUrl,
    String? bookAuthor,
    String? bookCoverUrl,
    String? bookYear,
    String? bookPublisher,
    String? bookInfoUrl,
    String? movieOriginalTitle,
    String? moviePosterUrl,
    String? movieYear,
    String? movieKind,
    String? movieGenres,
    String? movieCountry,
    String? movieRatingKp,
    String? movieInfoUrl,
    int? rating,
    bool isAdult = false,
    bool isSecret = false,
    bool sealed = false,
    DateTime? openAt,
    DateTime? customDate,
  }) async {
    final uid = _uid;
    if (uid == null || groupId.isEmpty) {
      // Тихий дроп воспоминания — самая частая причина жалоб «добавил фото, а в
      // ленте нет» (виджет-пути uid не требуют и проходят по токену, поэтому
      // фото «уходит в виджет, но не в воспоминания»). После фолбэка userId на
      // JWT (см. PocketBaseService.userId) uid==null означает реально нет
      // сессии — фиксируем, чтобы такие случаи были видимы, а не терялись молча.
      unawaited(Sentry.captureMessage(
        'MemoryRepository.add dropped: uid=${uid == null ? "null" : "ok"}, '
        'groupId=${groupId.isEmpty ? "empty" : "ok"}, type=${type.name}',
        withScope: (s) => s.level = SentryLevel.warning,
      ));
      return null;
    }
    final memory = Memory(
      id: newPbId(), // валидный PB-id, который сервер примет при отправке
      groupId: groupId,
      authorUid: uid,
      authorName: authorName,
      authorAvatar: authorAvatar,
      type: type,
      createdAt: customDate ?? DateTime.now(),
      imageUrl: imageUrl,
      imageUrls: imageUrls,
      videoUrl: videoUrl,
      title: title,
      caption: caption,
      locationName: locationName,
      latitude: latitude,
      longitude: longitude,
      musicTitle: musicTitle,
      musicArtist: musicArtist,
      musicUrl: musicUrl,
      musicCoverUrl: musicCoverUrl,
      bookAuthor: bookAuthor,
      bookCoverUrl: bookCoverUrl,
      bookYear: bookYear,
      bookPublisher: bookPublisher,
      bookInfoUrl: bookInfoUrl,
      movieOriginalTitle: movieOriginalTitle,
      moviePosterUrl: moviePosterUrl,
      movieYear: movieYear,
      movieKind: movieKind,
      movieGenres: movieGenres,
      movieCountry: movieCountry,
      movieRatingKp: movieRatingKp,
      movieInfoUrl: movieInfoUrl,
      rating: rating == 0 ? null : rating,
      isAdult: isAdult,
      isSecret: isSecret,
      sealed: sealed,
      openAt: openAt,
    );
    // 1) оптимистично в кэш → лента показывает сразу (и офлайн)
    await _cache.upsertRaw('memories', memory.id, _row(groupId, memory));
    // 2) в очередь: создание + инкремент счётчика воспоминаний
    await _outbox.enqueue('memoryUpsert',
        {'groupId': groupId, 'id': memory.id, 'data': memory.toJson()});
    await _outbox.enqueue('counterInc',
        {'groupId': groupId, 'field': 'memories_count', 'by': 1});
    // XP/аналитика — best-effort (онлайн); офлайн просто не начислится.
    unawaited(LevelService.instance.award(XpAction.addMemory));
    unawaited(AnalyticsService.instance.logMemoryAdded(type: type.name));
    return memory;
  }

  /// Частичное редактирование: RMW по кэшированной карте `data`, оптимистично в
  /// кэш + полный upsert в очередь.
  Future<void> update({
    required String groupId,
    required String memoryId,
    String? title,
    String? caption,
    String? locationName,
    double? latitude,
    double? longitude,
    String? musicTitle,
    String? musicArtist,
    String? bookAuthor,
    int? rating,
    String? imageUrl,
    bool? isPinned,
    bool? isAdult,
    bool? isSecret,
    DateTime? customDate,
  }) async {
    var cached = await _cache.getRecord('memories', memoryId);
    if (cached == null) {
      // Нет в кэше (напр. дип-линк) — подтягиваем с сервера (только онлайн).
      final rec = await _data.loadMemoryById(memoryId);
      if (rec == null) return;
      await _cache.upsert('memories', rec);
      cached = await _cache.getRecord('memories', memoryId);
      if (cached == null) return;
    }
    final row = Map<String, dynamic>.from(cached.data);
    final map = (row['data'] is Map)
        ? Map<String, dynamic>.from(row['data'] as Map)
        : <String, dynamic>{};
    void put(String k, dynamic v) {
      if (v != null) map[k] = v;
    }

    put('title', title);
    put('caption', caption);
    put('locationName', locationName);
    put('latitude', latitude);
    put('longitude', longitude);
    put('musicTitle', musicTitle);
    put('musicArtist', musicArtist);
    put('bookAuthor', bookAuthor);
    if (rating != null) map['rating'] = rating == 0 ? null : rating;
    put('imageUrl', imageUrl);
    if (isPinned != null) map['isPinned'] = isPinned;
    if (isAdult != null) map['isAdult'] = isAdult;
    if (isSecret != null) map['isSecret'] = isSecret;
    if (customDate != null) map['createdAt'] = customDate.toIso8601String();
    map['editedAt'] = DateTime.now().toIso8601String();

    // Синхронизируем индексные колонки кэш-ряда (для scope/сортировки/fromPb).
    row['data'] = map;
    if (isPinned != null) row['is_pinned'] = isPinned;
    if (customDate != null) row['created_at'] = customDate.toIso8601String();
    row['edited_at'] = map['editedAt'];

    await _cache.upsertRaw('memories', memoryId, row);
    await _outbox.enqueue(
        'memoryUpsert', {'groupId': groupId, 'id': memoryId, 'data': map});
  }

  Future<void> togglePin({
    required String groupId,
    required String memoryId,
    required bool isPinned,
  }) =>
      update(groupId: groupId, memoryId: memoryId, isPinned: isPinned);

  /// Переключает «Избранное» для ТЕКУЩЕГО пользователя (персонально). Оптимистично
  /// в кэш + идемпотентная set-saved операция в очередь (на сервере приводит
  /// присутствие uid к желаемому — не затирает партнёра, повтор безопасен).
  Future<void> toggleSaved({
    required String groupId,
    required String memoryId,
  }) async {
    final uid = _uid;
    if (uid == null || uid.isEmpty) return;
    final cached = await _cache.getRecord('memories', memoryId);
    if (cached == null) return;
    final row = Map<String, dynamic>.from(cached.data);
    final map = (row['data'] is Map)
        ? Map<String, dynamic>.from(row['data'] as Map)
        : <String, dynamic>{};
    final saved = (map['savedBy'] is List)
        ? List<String>.from((map['savedBy'] as List).map((e) => e.toString()))
        : <String>[];
    final willSave = !saved.contains(uid);
    if (willSave) {
      saved.add(uid);
    } else {
      saved.remove(uid);
    }
    map['savedBy'] = saved;
    row['data'] = map;
    await _cache.upsertRaw('memories', memoryId, row);
    await _outbox.enqueue('memorySetSaved',
        {'memoryId': memoryId, 'uid': uid, 'saved': willSave});
  }

  /// Удаляет воспоминание: оптимистично из кэша + удаление (с чисткой PB-медиа)
  /// и декремент счётчика в очередь.
  Future<void> delete({
    required String groupId,
    required String memoryId,
    String? imageUrl,
    String? videoUrl,
    String? musicUrl,
    String? musicCoverUrl,
  }) async {
    await _cache.deleteRecord('memories', memoryId);
    final refs = [imageUrl, videoUrl, musicUrl, musicCoverUrl]
        .whereType<String>()
        .toList();
    await _outbox.enqueue('memoryDelete',
        {'groupId': groupId, 'id': memoryId, 'mediaRefs': refs});
    await _outbox.enqueue('counterInc',
        {'groupId': groupId, 'field': 'memories_count', 'by': -1});
  }

  // ── Комментарии ──────────────────────────────────────────────────────────
  /// Живые комментарии воспоминания (старые сверху). Из локального кэша.
  /// [groupId] нужен для realtime-канала пары (Centrifugo).
  Stream<List<MemoryComment>> watchComments(String groupId, String memoryId) =>
      _rt
          .watchComments(groupId, memoryId)
          .map((recs) => recs.map(MemoryComment.fromPb).toList());

  /// Добавляет комментарий: оптимистично в кэш (+ бейдж commentsCount) и в
  /// очередь (создание + RMW-бамп счётчика) → работает офлайн.
  Future<void> addComment({
    required String groupId,
    required String memoryId,
    required String text,
    String? authorName,
    String? authorAvatar,
  }) async {
    final uid = _uid;
    if (uid == null) return;
    final profile = PbAuthService().currentProfile();
    final rawName = authorName ?? (profile?['displayName'] as String? ?? '');
    final name = rawName.isNotEmpty ? rawName : 'User';
    final avatar = authorAvatar ?? (profile?['avatarUrl'] as String? ?? '');
    final id = newPbId();
    final createdAt = DateTime.now().toIso8601String();
    // 1) оптимистично сам комментарий
    await _cache.upsertRaw('memory_comments', id, {
      'id': id,
      'group_id': groupId,
      'memory_id': memoryId,
      'deleted': false,
      'author_uid': uid,
      'author_name': name,
      'author_avatar': avatar,
      'text': text,
      'created_at': createdAt,
    });
    // 2) оптимистично бейдж commentsCount в кэш-ряду воспоминания
    final memRec = await _cache.getRecord('memories', memoryId);
    if (memRec != null) {
      final row = Map<String, dynamic>.from(memRec.data);
      final m = (row['data'] is Map)
          ? Map<String, dynamic>.from(row['data'] as Map)
          : <String, dynamic>{};
      m['commentsCount'] = ((m['commentsCount'] as num?)?.toInt() ?? 0) + 1;
      row['data'] = m;
      await _cache.upsertRaw('memories', memoryId, row);
    }
    // 3) в очередь
    await _outbox.enqueue('commentUpsert', {
      'groupId': groupId,
      'memoryId': memoryId,
      'id': id,
      'data': {
        'authorUid': uid,
        'authorName': name,
        'authorAvatar': avatar,
        'text': text,
        'createdAt': createdAt,
      },
    });
    await _outbox.enqueue('memoryBumpComments',
        {'groupId': groupId, 'memoryId': memoryId, 'by': 1});
  }

  Future<void> deleteComment(String commentId) async {
    await _cache.deleteRecord('memory_comments', commentId);
    await _outbox.enqueue('commentDelete', {'id': commentId});
  }
}
