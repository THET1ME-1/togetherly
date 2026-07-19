import 'dart:async';

import '../models/mascot.dart';
import 'offline/local_store.dart';
import 'offline/outbox_service.dart';
import 'pb_data_service.dart';
import 'pb_realtime_service.dart';
import 'pocketbase_service.dart';

/// Репозиторий маскотов поверх PocketBase (миграция Firebase→PB, §3).
///
/// Маскот — это срез group-дока: ГАЛЕРЕЯ живёт в коллекции `mascots`, а
/// СОСТОЯНИЕ (активный/позиция/серия/xp) — в колонках группы. [MascotService]
/// работает с моделями [Mascot]/[GroupMascotState], а не с `RecordModel`.
/// Чтения на self-hosted PB БЕСПЛАТНЫ → галерея и состояние live без лимитов.
///
/// Картинки маскотов (Storage) НЕ здесь: загрузка/удаление файлов — §4 (медиа),
/// до неё их грузит вызывающий через Firebase (как и медиа воспоминаний).
class MascotRepository {
  MascotRepository._();
  static final MascotRepository instance = MascotRepository._();
  factory MascotRepository() => instance;

  final PbDataService _data = PbDataService();
  final PbRealtimeService _rt = PbRealtimeService();

  String? get _uid => PocketBaseService().userId;

  /// camelCase-карта для PbData.upsertMascot (createdAt — DateTime, НЕ Timestamp:
  /// `Mascot.toFirestore` отдал бы Timestamp, который `_iso` не понимает).
  Map<String, dynamic> _input(Mascot m) => {
        'id': m.id,
        'name': m.name,
        'imageUrl': m.imageUrl,
        'defaultAsset': m.defaultAsset,
        'createdBy': m.createdBy,
        'createdAt': m.createdAt,
        'isDefault': m.isDefault,
        'recordStreak': m.recordStreak,
      };

  // ── Галерея ────────────────────────────────────────────────────────────────
  /// Живая галерея группы (дефолтные первыми, затем по дате — сортировка в
  /// [PbRealtimeService.watchMascots]). Пустые id отфильтрованы.
  Stream<List<Mascot>> watchGallery(String groupId) =>
      _rt.watchMascots(groupId).map((recs) =>
          recs.map(Mascot.fromPb).where((m) => m.id.isNotEmpty).toList());

  Future<void> save(String groupId, Mascot mascot) =>
      _data.upsertMascot(groupId, _input(mascot));

  Future<void> saveBatch(String groupId, List<Mascot> mascots) =>
      _data.upsertMascotsBatch(groupId, mascots.map(_input).toList());

  Future<void> delete(String groupId, String mascotId) =>
      _data.deleteMascot(groupId, mascotId);

  Future<void> rename(String groupId, String mascotId, String newName) =>
      _data.updateMascotFields(groupId, mascotId, {'name': newName});

  // ── Состояние (group-док) ────────────────────────────────────────────────
  /// Живое состояние маскота пары. `watchGroup` шлёт весь group-док при ЛЮБОМ
  /// изменении (настроение/статус/таймеры/...) → де-дуп по подписи mascot-полей,
  /// иначе виджет маскота ребилдится на каждое несвязанное изменение группы
  /// (паритет с прежним listenToGroupMascotState).
  Stream<GroupMascotState> watchState(String groupId) {
    String? prevSig;
    return _rt
        .watchGroup(groupId)
        .map((rec) =>
            rec == null ? const GroupMascotState() : GroupMascotState.fromPb(rec))
        .where((s) {
      final sig = '${s.activeMascotId}|${s.positionX}|${s.positionY}|'
          '${s.scale}|${s.streakDays}|${s.streakLastOpenedDate}|${s.xp}|'
          '${s.mascotStreaks}';
      if (sig == prevSig) return false;
      prevSig = sig;
      return true;
    });
  }

  /// Активный маскот — состояние в group-доке: оптимистично в кэш + в очередь.
  Future<void> setActive(String groupId, String? mascotId) async {
    final cols = {'active_mascot_id': mascotId ?? ''};
    await LocalStore.instance.patchRecordFields('groups', groupId, cols);
    await OutboxService.instance
        .enqueue('groupUpdateFields', {'groupId': groupId, 'cols': cols});
  }

  /// Позиция/масштаб маскота — состояние в group-доке: оптимистично + очередь.
  Future<void> updatePosition(
    String groupId, {
    required double x,
    required double y,
    required double scale,
  }) async {
    final cols = {
      'mascot_position_x': x,
      'mascot_position_y': y,
      'mascot_scale': scale,
    };
    await LocalStore.instance.patchRecordFields('groups', groupId, cols);
    await OutboxService.instance
        .enqueue('groupUpdateFields', {'groupId': groupId, 'cols': cols});
  }

  /// Отметить дневную активность текущего пользователя (ведение «огонька»).
  Future<void> recordActivity(String groupId) async {
    final uid = _uid;
    if (uid == null) return;
    await _data.recordGroupActivity(groupId, uid);
  }
}
