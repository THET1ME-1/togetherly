import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';

import '../pb_media_service.dart';
import '../pocketbase_service.dart';
import 'connectivity_service.dart';
import 'local_store.dart';
import 'outbox_service.dart';
import 'pb_id.dart';

/// Офлайн-медиа: отложенная заливка созданного без сети.
///
/// Когда сети нет, [MediaService.uploadFile] прячет уже СЖАТЫЙ файл сюда и
/// возвращает ссылку схемы `localfile://<абсолютный путь>`. UI ([StorageImage])
/// рисует её прямо с диска (`Image.file`), поэтому своё фото видно сразу и
/// офлайн. При появлении сети [flushPending] заливает файл в PocketBase, получает
/// `pb://`-ссылку и подменяет `localfile://`→`pb://` в кэше воспоминаний и на
/// сервере (через очередь) — после чего партнёр видит настоящее медиа.
///
/// Покрывает медиа ВОСПОМИНАНИЙ (kind memories/music). Аватары/маскоты/холст
/// офлайн пока не откладываются (заливаются только онлайн).
class MediaCache {
  MediaCache._();
  static final MediaCache instance = MediaCache._();
  factory MediaCache() => instance;

  static const String scheme = 'localfile://';
  static const int _maxAttempts = 8;

  bool _flushing = false;
  StreamSubscription<bool>? _connSub;

  StoreRef<String, Map<String, Object?>> get _pending =>
      stringMapStoreFactory.store('pending_media');

  Future<void> init() async {
    _connSub ??= ConnectivityService.instance.onOnlineChanged.listen((online) {
      if (online) unawaited(flushPending());
    });
    unawaited(flushPending());
  }

  bool isLocalRef(String? ref) => ref != null && ref.startsWith(scheme);
  String? localPath(String? ref) =>
      isLocalRef(ref) ? ref!.substring(scheme.length) : null;

  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/offline/pending_media');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Спрятать сжатые байты в локальный pending-файл и вернуть `localfile://`.
  /// Регистрирует запись для последующей заливки (kind/group_id — для ACL media).
  Future<String?> stash(
    List<int> bytes,
    String filename, {
    String? kind,
    String? groupId,
  }) async {
    try {
      final dir = await _dir();
      final ext = filename.contains('.') ? filename.split('.').last : 'bin';
      final path = '${dir.path}/${newPbId()}.$ext';
      await File(path).writeAsBytes(bytes);
      final db = await LocalStore.instance.database();
      if (db != null) {
        await _pending.record(path).put(db, {
          'path': path,
          'filename': filename,
          'kind': kind,
          'groupId': groupId,
          'attempts': 0,
        });
      }
      return '$scheme$path';
    } catch (e) {
      debugPrint('MediaCache.stash failed: $e');
      return null;
    }
  }

  /// Залить все отложенные файлы и подменить ссылки. Идемпотентно к параллельным
  /// вызовам; запускается на реконнекте и на старте.
  Future<void> flushPending() async {
    if (_flushing || !ConnectivityService.instance.isOnline) return;
    final db = await LocalStore.instance.database();
    if (db == null) return;
    _flushing = true;
    try {
      final items = await _pending.find(db);
      for (final it in items) {
        final path = it.value['path'] as String?;
        if (path == null) {
          await _pending.record(it.key).delete(db);
          continue;
        }
        final file = File(path);
        if (!await file.exists()) {
          await _pending.record(it.key).delete(db); // файла нет — снимаем
          continue;
        }
        final pbRef = await PbMediaService().uploadBytes(
          await file.readAsBytes(),
          it.value['filename'] as String? ?? 'file',
          uid: PocketBaseService().userId,
          groupId: it.value['groupId'] as String?,
          kind: it.value['kind'] as String?,
        );
        if (pbRef == null) {
          // не удалось залить — счётчик попыток, чтобы не копить вечно
          final next = ((it.value['attempts'] as num?)?.toInt() ?? 0) + 1;
          if (next >= _maxAttempts) {
            debugPrint('MediaCache: бросаю $path после $next попыток заливки');
            await file.delete().catchError((_) => file);
            await _pending.record(it.key).delete(db);
          } else {
            await _pending.record(it.key).update(db, {'attempts': next});
          }
          continue;
        }
        await _replaceRefInMemories('$scheme$path', pbRef);
        await file.delete().catchError((_) => file);
        await _pending.record(it.key).delete(db);
      }
    } catch (e) {
      debugPrint('MediaCache.flushPending error: $e');
    } finally {
      _flushing = false;
    }
  }

  /// Подменить [localRef]→[pbRef] во всех воспоминаниях кэша (рекурсивно по json
  /// `data`: imageUrl/imageUrls/videoUrl/musicUrl/...), и протолкнуть правку на
  /// сервер через очередь (чтобы партнёр получил `pb://`).
  Future<void> _replaceRefInMemories(String localRef, String pbRef) async {
    final recs = await LocalStore.instance.allRecords('memories');
    for (final rec in recs) {
      final data = rec.data['data'];
      if (data is! Map) continue;
      final dataMap = Map<String, dynamic>.from(data);
      if (!deepReplaceRefs(dataMap, localRef, pbRef)) continue;
      final row = Map<String, dynamic>.from(rec.data)..['data'] = dataMap;
      await LocalStore.instance.upsertRaw('memories', rec.id, row);
      await OutboxService.instance.enqueue('memoryUpsert', {
        'groupId': row['group_id'],
        'id': rec.id,
        'data': dataMap,
      });
    }
  }

  /// Рекурсивная замена строкового значения [from]→[to] в Map/List. Возвращает
  /// true, если что-то заменили.
  @visibleForTesting
  static bool deepReplaceRefs(dynamic node, String from, String to) {
    var changed = false;
    if (node is Map) {
      for (final k in node.keys.toList()) {
        final v = node[k];
        if (v == from) {
          node[k] = to;
          changed = true;
        } else if (v is Map || v is List) {
          if (deepReplaceRefs(v, from, to)) changed = true;
        }
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        final v = node[i];
        if (v == from) {
          node[i] = to;
          changed = true;
        } else if (v is Map || v is List) {
          if (deepReplaceRefs(v, from, to)) changed = true;
        }
      }
    }
    return changed;
  }

  /// Полная очистка отложенных медиа (logout/смена пользователя).
  Future<void> clearPending() async {
    final db = await LocalStore.instance.database();
    if (db != null) await _pending.delete(db);
    try {
      final dir = Directory(
          '${(await getApplicationSupportDirectory()).path}/offline/pending_media');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('MediaCache.clearPending failed: $e');
    }
  }
}
