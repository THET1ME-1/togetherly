import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/canvas_meta.dart';
import '../models/draw_stroke.dart';
import 'canvas_repository.dart';

/// Persists a per-user-per-group list of [CanvasMeta] entries in SharedPreferences
/// **and** syncs the catalogue to PocketBase when the user belongs to a group
/// (миграция §3 — через [CanvasRepository], ноль Firebase).
///
/// The actual drawing strokes live in PocketBase (paired) or in-memory (solo).
class CanvasStorageService {
  CanvasStorageService._();
  static final CanvasStorageService instance = CanvasStorageService._();

  final CanvasRepository _canvas = CanvasRepository();

  /// Active Firebase listener — cancelled in [stopListening].
  StreamSubscription? _catalogueSub;

  /// Callback notified whenever the remote catalogue changes.
  VoidCallback? onRemoteChange;

  // ── helpers ────────────────────────────────────────────────────────────────

  /// Key is scoped by both uid and groupId so each connection has its own
  /// isolated canvas list. Solo mode uses the 'solo' sentinel.
  String _key(String uid, String groupId) =>
      'canvases_v1_${uid}_${groupId.isEmpty ? 'solo' : groupId}';

  // ── public API ─────────────────────────────────────────────────────────────

  /// Returns all canvases for [uid] in [groupId], newest first.
  /// Seeds a default "main" canvas on first call.
  Future<List<CanvasMeta>> getCanvases(String uid,
      {String groupId = ''}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(uid, groupId));
      if (raw == null) return _seedDefault(uid, groupId);
      final decoded = jsonDecode(raw) as List<dynamic>;
      final list = decoded
          .map((e) => CanvasMeta.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (list.isEmpty) return _seedDefault(uid, groupId);
      return list;
    } catch (_) {
      return _seedDefault(uid, groupId);
    }
  }

  /// Creates a new canvas entry (prepended to the list) and returns it.
  /// When [groupId] is non-empty the canvas meta is also pushed to Firebase.
  Future<CanvasMeta> createCanvas(
    String uid, {
    String? name,
    String groupId = '',
  }) async {
    final canvases = await getCanvases(uid, groupId: groupId);
    final id = 'canvas_${DateTime.now().millisecondsSinceEpoch}';
    final meta = CanvasMeta(
      id: id,
      name: name ?? 'Canvas ${canvases.length + 1}',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _save(uid, groupId, [meta, ...canvases]);

    // Push to PocketBase so partner sees the new canvas
    if (groupId.isNotEmpty) {
      _canvas.upsertCatalogue(
        groupId,
        id,
        name: meta.name,
        createdAt: meta.createdAt.millisecondsSinceEpoch,
        updatedAt: meta.updatedAt.millisecondsSinceEpoch,
        createdBy: uid,
      );
      _canvas.incrementDrawings(groupId, 1);
    }

    return meta;
  }

  /// Replaces the matching entry (by id) with [updated].
  Future<void> updateCanvas(
    String uid,
    CanvasMeta updated, {
    String groupId = '',
  }) async {
    final canvases = await getCanvases(uid, groupId: groupId);
    final next = canvases.map((c) => c.id == updated.id ? updated : c).toList();
    await _save(uid, groupId, next);

    if (groupId.isNotEmpty) {
      _canvas.upsertCatalogue(
        groupId,
        updated.id,
        name: updated.name,
        createdAt: updated.createdAt.millisecondsSinceEpoch,
        updatedAt: updated.updatedAt.millisecondsSinceEpoch,
      );
    }
  }

  /// Rename a canvas (local + Firebase).
  Future<void> renameCanvas(
    String uid,
    String canvasId,
    String newName, {
    String groupId = '',
  }) async {
    final canvases = await getCanvases(uid, groupId: groupId);
    final idx = canvases.indexWhere((c) => c.id == canvasId);
    if (idx < 0) return;
    canvases[idx] = canvases[idx].copyWith(
      name: newName,
      updatedAt: DateTime.now(),
    );
    await _save(uid, groupId, canvases);

    if (groupId.isNotEmpty) {
      _canvas.renameCatalogue(groupId, canvasId, newName);
    }
  }

  /// Stores a PNG thumbnail [bytes] for the canvas identified by [canvasId]
  /// and bumps its [updatedAt] timestamp.
  Future<void> updatePreview(
    String uid,
    String canvasId,
    Uint8List bytes, {
    String groupId = '',
  }) async {
    final canvases = await getCanvases(uid, groupId: groupId);
    final idx = canvases.indexWhere((c) => c.id == canvasId);
    if (idx < 0) return;
    canvases[idx] = canvases[idx].copyWith(
      previewBase64: base64Encode(bytes),
      updatedAt: DateTime.now(),
    );
    await _save(uid, groupId, canvases);
  }

  /// Removes the canvas with [canvasId] from the list.
  Future<void> deleteCanvas(
    String uid,
    String canvasId, {
    String groupId = '',
  }) async {
    final canvases = await getCanvases(uid, groupId: groupId);
    await _save(uid, groupId, canvases.where((c) => c.id != canvasId).toList());

    if (groupId.isNotEmpty) {
      _canvas.deleteCatalogue(groupId, canvasId);
      _canvas.incrementDrawings(groupId, -1);
    }
  }

  // ── Firebase real-time sync ───────────────────────────────────────────────

  /// Start listening to the remote canvas catalogue.
  /// Merges remote entries into the local list for this [groupId].
  void startListening({required String uid, required String groupId}) {
    _catalogueSub?.cancel();
    if (groupId.isEmpty) return;

    _catalogueSub = _canvas.watchCatalogue(groupId).listen(
      (remoteList) async {
        await _mergeRemoteCanvases(uid, groupId, remoteList);
        onRemoteChange?.call();
      },
      onError: (e) => debugPrint('[Storage] catalogue error: $e'),
    );
  }

  /// Stop the remote listener (e.g. when the gallery screen is disposed).
  void stopListening() {
    _catalogueSub?.cancel();
    _catalogueSub = null;
  }

  /// Merge remote canvas entries into local storage for [groupId].
  Future<void> _mergeRemoteCanvases(
    String uid,
    String groupId,
    List<Map<String, dynamic>> remoteList,
  ) async {
    final local = await getCanvases(uid, groupId: groupId);
    final localById = {for (final c in local) c.id: c};

    bool changed = false;
    for (final remote in remoteList) {
      final id = remote['id'] as String;
      final name = (remote['name'] as String?) ?? 'Canvas';
      final createdAt = DateTime.fromMillisecondsSinceEpoch(
        (remote['createdAt'] as num?)?.toInt() ?? 0,
      );
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(
        (remote['updatedAt'] as num?)?.toInt() ?? 0,
      );

      if (!localById.containsKey(id)) {
        // New canvas from partner — add it locally
        localById[id] = CanvasMeta(
          id: id,
          name: name,
          createdAt: createdAt,
          updatedAt: updatedAt,
        );
        changed = true;
      } else {
        // Update name if remote is newer
        final existing = localById[id]!;
        if (updatedAt.isAfter(existing.updatedAt) && name != existing.name) {
          localById[id] = existing.copyWith(name: name, updatedAt: updatedAt);
          changed = true;
        }
      }
    }

    // Remove local canvases that were deleted remotely
    final remoteIds = remoteList.map((r) => r['id'] as String).toSet();
    // Keep canvases not yet in remote (freshly created locally, or 'main' default)
    // Only remove if the remote set is non-empty (i.e. we have an established catalogue)
    if (remoteList.isNotEmpty) {
      final toRemove = localById.keys
          .where((id) => !remoteIds.contains(id) && id != 'main')
          .toList();
      for (final id in toRemove) {
        localById.remove(id);
        changed = true;
      }
    }

    if (changed) {
      final merged = localById.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      await _save(uid, groupId, merged);
    }
  }

  /// Push all existing local canvases to Firebase (one-time bootstrap).
  /// Called when a user first pairs or opens the gallery while paired.
  Future<void> pushAllToFirebase(String uid, String groupId) async {
    if (groupId.isEmpty) return;
    final canvases = await getCanvases(uid, groupId: groupId);
    for (final meta in canvases) {
      await _canvas.upsertCatalogue(
        groupId,
        meta.id,
        name: meta.name,
        createdAt: meta.createdAt.millisecondsSinceEpoch,
        updatedAt: meta.updatedAt.millisecondsSinceEpoch,
        createdBy: uid,
      );
    }
  }

  // ── Local stroke persistence (solo mode) ────────────────────────────────

  String _strokesKey(String uid, String groupId, String canvasId) =>
      'strokes_v1_${uid}_${groupId.isEmpty ? 'solo' : groupId}_$canvasId';

  /// Persists [strokes] locally for the given canvas (solo or paired).
  Future<void> saveLocalStrokes(
    String uid,
    String canvasId,
    List<DrawStroke> strokes, {
    String groupId = '',
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(
        strokes.map((s) => {'id': s.id, ...s.toFirestore()}).toList(),
      );
      await prefs.setString(_strokesKey(uid, groupId, canvasId), encoded);
    } catch (e) {
      debugPrint('[Storage] saveLocalStrokes error: $e');
    }
  }

  /// Loads persisted strokes for the given canvas. Returns empty list on error.
  Future<List<DrawStroke>> loadLocalStrokes(
    String uid,
    String canvasId, {
    String groupId = '',
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_strokesKey(uid, groupId, canvasId));
      if (raw == null) return [];
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) {
        final map = Map<String, dynamic>.from(e as Map);
        final id = map['id'] as String? ?? '';
        return DrawStroke.fromFirestore(map, id);
      }).toList();
    } catch (e) {
      debugPrint('[Storage] loadLocalStrokes error: $e');
      return [];
    }
  }

  /// Removes persisted strokes for the given canvas.
  Future<void> clearLocalStrokes(
    String uid,
    String canvasId, {
    String groupId = '',
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_strokesKey(uid, groupId, canvasId));
    } catch (e) {
      debugPrint('[Storage] clearLocalStrokes error: $e');
    }
  }

  // ── private ────────────────────────────────────────────────────────────────

  Future<List<CanvasMeta>> _seedDefault(String uid, String groupId) async {
    final meta = CanvasMeta(
      id: 'main',
      name: 'Canvas 1',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await _save(uid, groupId, [meta]);
    return [meta];
  }

  Future<void> _save(
      String uid, String groupId, List<CanvasMeta> canvases) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(uid, groupId),
      jsonEncode(canvases.map((c) => c.toJson()).toList()),
    );
  }
}
