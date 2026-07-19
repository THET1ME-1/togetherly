import 'dart:async';

import '../models/draw_stroke.dart';
import 'centrifugo_service.dart';
import 'pb_data_service.dart';
import 'pb_realtime_service.dart';

/// Срез мета холста (bg/rotation/clear) для draw_screen — замена
/// `RemoteCanvasMeta` из firebase_service (ноль Firebase). 0 трактуем как «не
/// задано»→null (PB number-колонки дефолтят в 0; реальные значения: bgColor —
/// ARGB>0, clearVersion — epoch-ms, rotation 0≡нет поворота).
class CanvasMetaUpdate {
  final int? bgColor;
  final int? clearVersion;
  final int? rotationMilliRadians;
  const CanvasMetaUpdate({
    this.bgColor,
    this.clearVersion,
    this.rotationMilliRadians,
  });
}

/// Репозиторий холста-рисования поверх PocketBase (миграция §3).
///
/// Две части: КАТАЛОГ холстов (`canvas_catalogue`, метаданные списка) — для
/// `CanvasStorageService`; и САМО рисование (`canvas_strokes` committed +
/// `canvas_live` in-progress + `canvas_meta` bg/rotation/clear) — для draw_screen.
/// Чтения на PB бесплатны → всё live без лимитов. Presence НЕ переносим — она
/// была write-only (нигде не читалась). Картинки-вставки (uploadFile) — медиа §4.
class CanvasRepository {
  CanvasRepository._();
  static final CanvasRepository instance = CanvasRepository._();
  factory CanvasRepository() => instance;

  final PbDataService _data = PbDataService();
  final PbRealtimeService _rt = PbRealtimeService();

  // ── Каталог холстов ────────────────────────────────────────────────────────
  /// Живой каталог в форме, которую ждёт `CanvasStorageService._mergeRemoteCanvases`:
  /// {id, name, createdAt(ms), updatedAt(ms)}. id холста — в колонке canvas_id.
  Stream<List<Map<String, dynamic>>> watchCatalogue(String groupId) =>
      _rt.watchCanvasCatalogue(groupId).map((recs) => recs
          .map((r) => {
                'id': (r.data['canvas_id'] ?? '').toString(),
                'name': (r.data['name'] ?? '').toString(),
                'createdAt': (r.data['created_at'] as num?)?.toInt() ?? 0,
                'updatedAt': (r.data['updated_at'] as num?)?.toInt() ?? 0,
              })
          .where((m) => (m['id'] as String).isNotEmpty)
          .toList());

  Future<void> upsertCatalogue(
    String groupId,
    String canvasId, {
    required String name,
    required int createdAt,
    required int updatedAt,
    String? createdBy,
  }) =>
      _data.upsertCanvasCatalogue(groupId, canvasId, {
        'name': name,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'createdBy': ?createdBy,
      });

  Future<void> renameCatalogue(String groupId, String canvasId, String name) =>
      _data.upsertCanvasCatalogue(groupId, canvasId, {
        'name': name,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });

  Future<void> deleteCatalogue(String groupId, String canvasId) =>
      _data.deleteCanvasCatalogue(groupId, canvasId);

  Future<void> incrementDrawings(String groupId, int by) =>
      _data.incrementGroupCounter(groupId, 'drawings_count', by);

  // ── Рисование: committed-штрихи ──────────────────────────────────────────
  /// Живые штрихи холста (по order_index). Замена listenToDrawingStrokes.
  Stream<List<DrawStroke>> watchStrokes(String groupId, String canvasId) =>
      _rt.watchCanvasStrokes(groupId, canvasId).map(
          (recs) => recs.map(DrawStroke.fromPb).toList());

  /// Коммит штриха (server-id). Возвращает id записи (для оптимистичного
  /// сопоставления в draw_screen) или ''.
  Future<String> addStroke(
      String groupId, String canvasId, Map<String, dynamic> data) async {
    final rec = await _data.createStroke(groupId, canvasId, data);
    return rec?.id ?? '';
  }

  Future<void> patchStroke(String strokeId, Map<String, dynamic> updates) =>
      _data.patchStroke(strokeId, updates);

  Future<void> deleteStroke(String strokeId) => _data.deleteStroke(strokeId);

  Future<void> clear(
    String groupId,
    String canvasId, {
    required int clearVersion,
    int? bgColor,
  }) =>
      _data.clearCanvas(groupId, canvasId, clearVersion, bgColor: bgColor);

  // ── Рисование: мета (bg/rotation/clear) ───────────────────────────────────
  Stream<CanvasMetaUpdate> watchMeta(String groupId, String canvasId) =>
      _rt.watchCanvasMeta(groupId, canvasId).map((rows) {
        if (rows.isEmpty) return const CanvasMetaUpdate();
        final d = rows.first.data;
        int? nz(dynamic v) {
          final n = (v as num?)?.toInt() ?? 0;
          return n == 0 ? null : n;
        }

        return CanvasMetaUpdate(
          bgColor: nz(d['bg_color']),
          clearVersion: nz(d['clear_version']),
          rotationMilliRadians: nz(d['canvas_rotation']),
        );
      });

  Future<void> setBgColor(String groupId, String canvasId, int color) =>
      _data.upsertCanvasMeta(groupId, canvasId, bgColor: color);

  Future<void> setRotation(
          String groupId, String canvasId, int rotationMilliRadians) =>
      _data.upsertCanvasMeta(groupId, canvasId,
          rotation: rotationMilliRadians);

  // ── Рисование: live-штрихи (in-progress) — ЭФЕМЕРНО через Centrifugo ───────
  // НЕ пишем в БД: раньше каждый in-progress штрих = запись в коллекцию
  // canvas_live → шторм на единственном SQLite-writer'е. Теперь публикуем и
  // слушаем НАПРЯМУЮ через Centrifugo (канал draw:<groupId>): ноль нагрузки на
  // БД, ниже задержка, рисование плавнее. Финальные штрихи как и прежде идут в
  // canvas_strokes (durable). liveData — карта `DrawStroke.toLiveMap()`.
  String _liveChannel(String groupId) => 'draw:$groupId';

  /// Live-штрихи партнёров {uid: liveData} для (group,canvas); СВОЙ uid исключён.
  /// Состояние держим в памяти из публикаций Centrifugo (надгробие — data:null).
  Stream<Map<String, Map<String, dynamic>>> watchLive(
      String groupId, String canvasId, String myUid) {
    final state = <String, Map<String, dynamic>>{};
    RtUnsub? unsub;
    late StreamController<Map<String, Map<String, dynamic>>> ctrl;
    ctrl = StreamController<Map<String, Map<String, dynamic>>>.broadcast(
      onListen: () async {
        if (!ctrl.isClosed) ctrl.add(Map.of(state));
        unsub = await CentrifugoService.instance
            .subscribeRaw(_liveChannel(groupId), (m) {
          final uid = (m['uid'] ?? '').toString();
          if (uid.isEmpty || uid == myUid) return;
          if ((m['canvasId'] ?? '').toString() != canvasId) return;
          final data = m['data'];
          if (data == null) {
            state.remove(uid);
          } else if (data is Map) {
            state[uid] = Map<String, dynamic>.from(data);
          }
          if (!ctrl.isClosed) ctrl.add(Map.of(state));
        });
      },
      onCancel: () async {
        await unsub?.call();
        unsub = null;
      },
    );
    return ctrl.stream;
  }

  /// Опубликовать свой in-progress штрих (эфемерно, мимо БД).
  Future<void> setLive(String groupId, String canvasId, String uid,
          Map<String, dynamic> liveData) =>
      CentrifugoService.instance.publish(_liveChannel(groupId),
          {'uid': uid, 'canvasId': canvasId, 'data': liveData});

  /// Снять свой in-progress штрих (надгробие data:null).
  Future<void> clearLive(String groupId, String canvasId, String uid) =>
      CentrifugoService.instance.publish(_liveChannel(groupId),
          {'uid': uid, 'canvasId': canvasId, 'data': null});
}
