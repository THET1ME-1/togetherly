import 'dart:async';

import '../models/mood_entry.dart';
import 'offline/local_store.dart';
import 'offline/outbox_service.dart';
import 'offline/pb_id.dart';
import 'pb_data_service.dart';
import 'pb_realtime_service.dart';
import 'pocketbase_service.dart';

/// Репозиторий настроений (mood calendar) поверх PocketBase (миграция §3).
///
/// Доменная обёртка над [PbDataService] (CRUD) и [PbRealtimeService] (live SSE):
/// [MoodService] работает с моделями [MoodEntry], а не с `RecordModel`.
///
/// ВАЖНО: на self-hosted PB чтения БЕСПЛАТНЫ → плоская коллекция `mood_entries`
/// читается ЦЕЛИКОМ по (group, uid) live, без месячных документов, legacy-
/// fallback'а, одноразовой миграции и rollover-таймера, которые были нужны
/// ТОЛЬКО ради экономии чтений Firestore. Запись на ЛЮБУЮ дату появляется через
/// SSE сразу (старый live-слушатель покрывал лишь текущий месяц → нужен был
/// оптимистичный _applyLocalAdd; теперь не нужен).
class MoodRepository {
  MoodRepository._();
  static final MoodRepository instance = MoodRepository._();
  factory MoodRepository() => instance;

  final PbDataService _data = PbDataService();
  final PbRealtimeService _rt = PbRealtimeService();

  String? get _uid => PocketBaseService().userId;

  /// Живой список настроений [uid] в группе (новые сверху — сортировка в
  /// [PbRealtimeService.watchMoods] по timestamp DESC).
  Stream<List<MoodEntry>> watch(String groupId, String uid) =>
      _rt.watchMoods(groupId, uid).map((recs) => recs.map(MoodEntry.fromPb).toList());

  /// Разовая загрузка настроений [uid] (для нестриминговых путей при нужде).
  Future<List<MoodEntry>> load(String groupId, String uid) async {
    final recs = await _data.loadMoods(groupId, uid);
    return recs.map(MoodEntry.fromPb).toList();
  }

  /// Создаёт запись настроения (id генерится локально, принимается сервером).
  /// Оптимистично в кэш + в очередь → работает офлайн. Личность — текущий юзер.
  Future<MoodEntry?> add({
    required String groupId,
    required String moodId,
    required String imagePath,
    required String label,
    required DateTime timestamp,
  }) async {
    final uid = _uid;
    if (uid == null || groupId.isEmpty) return null;
    final id = newPbId();
    final ts = timestamp.toIso8601String();
    await LocalStore.instance.upsertRaw('mood_entries', id, {
      'id': id,
      'group_id': groupId,
      'user_uid': uid,
      'mood_id': moodId,
      'image_path': imagePath,
      'label': label,
      'timestamp': ts,
    });
    await OutboxService.instance.enqueue('moodUpsert', {
      'groupId': groupId,
      'uid': uid,
      'entry': {
        'id': id,
        'moodId': moodId,
        'imagePath': imagePath,
        'label': label,
        'timestamp': ts,
      },
    });
    return MoodEntry(
        id: id,
        moodId: moodId,
        imagePath: imagePath,
        label: label,
        timestamp: timestamp);
  }

  /// Удаляет запись настроения по id: оптимистично из кэша + в очередь.
  Future<void> delete(String entryId) async {
    await LocalStore.instance.deleteRecord('mood_entries', entryId);
    await OutboxService.instance.enqueue('moodDelete', {'id': entryId});
  }
}
