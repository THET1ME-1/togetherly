import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import 'pocketbase_service.dart';

/// Своё видео пары: либо загруженное во вкладке «Смотрим», либо ролик из
/// ленты воспоминаний.
class WatchVideo {
  final String id;
  final String title;
  final String url;
  final int seconds;

  /// true — файл лежит в защищённом хранилище воспоминаний: приложение его
  /// откроет, а партнёр в браузере нет, там нет сессии.
  final bool appOnly;

  const WatchVideo({
    required this.id,
    required this.title,
    required this.url,
    required this.seconds,
    this.appOnly = false,
  });
}

/// Свои видео: пара загружает ролик в приложение и смотрит его вместе.
///
/// Файл лежит у нас, поэтому обоим он отдаётся обычной прямой ссылкой — это
/// самая точная синхронизация из возможных, секунда в секунду. Ссылка работает
/// без сессии: комнату на сайте открывает анонимный гость.
class WatchVideosService {
  WatchVideosService._();

  static const String _col = 'watch_videos';

  /// Больше сотни мегабайт не берём: это ограничение стоит и в базе.
  static const int maxBytes = 100 * 1024 * 1024;

  static PocketBase get _pb => PocketBaseService.instance.pb;

  static String _fileUrl(RecordModel r) {
    final file = (r.data['file'] ?? '').toString();
    if (file.isEmpty) return '';
    return '${PocketBaseService.baseUrl}/api/files/$_col/${r.id}/$file';
  }

  static WatchVideo _fromRecord(RecordModel r) => WatchVideo(
        id: r.id,
        title: (r.data['title'] ?? '').toString(),
        url: _fileUrl(r),
        seconds: ((r.data['seconds'] ?? 0) as num).round(),
      );

  /// Все ролики пары: сначала загруженные во вкладке «Смотрим», затем видео из
  /// ленты воспоминаний — иначе люди не понимают, куда делись их записи.
  static Future<List<WatchVideo>> list(String groupId) async {
    if (groupId.isEmpty) return const [];
    final own = await _uploaded(groupId);
    final lane = await _fromMemoryLane(groupId);
    return [...own, ...lane];
  }

  static Future<List<WatchVideo>> _uploaded(String groupId) async {
    try {
      final res = await _pb.collection(_col).getList(
            page: 1,
            perPage: 30,
            filter: 'group_id = "$groupId"',
            sort: '-updated',
          );
      return res.items.map(_fromRecord).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Видео-воспоминания. Ссылка на файл в них своя (`pb://media/...`), фильтра
  /// по вложенному json в PocketBase нет, поэтому отбираем на клиенте.
  static Future<List<WatchVideo>> _fromMemoryLane(String groupId) async {
    try {
      final res = await _pb.collection('memories').getList(
            page: 1,
            perPage: 60,
            filter: 'group_id = "$groupId"',
            sort: '-created',
          );
      final out = <WatchVideo>[];
      for (final r in res.items) {
        final raw = r.data['data'];
        if (raw is! Map) continue;
        final url = (raw['videoUrl'] ?? '').toString();
        if (url.isEmpty) continue;
        out.add(WatchVideo(
          id: r.id,
          title: (raw['title'] ?? raw['text'] ?? '').toString(),
          url: url,
          seconds: 0,
          appOnly: url.startsWith('pb://'),
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Загружает ролик. Возвращает запись или null, если файл слишком большой
  /// либо сервер отказал.
  static Future<WatchVideo?> upload({
    required String groupId,
    required File file,
    required String title,
  }) async {
    if (groupId.isEmpty) return null;
    final size = await file.length();
    if (size > maxBytes) return null;

    try {
      final bytes = await file.readAsBytes();
      final rec = await _pb
          .collection(_col)
          .create(
            body: {
              'group_id': groupId,
              'title': title,
              'added_by': PocketBaseService().userId ?? '',
            },
            files: [
              http.MultipartFile.fromBytes('file', bytes, filename: title),
            ],
          )
          // Сто мегабайт по мобильной сети идут долго: минутного таймаута,
          // как у фотографий, тут не хватает.
          .timeout(const Duration(minutes: 10));
      return _fromRecord(rec);
    } catch (_) {
      return null;
    }
  }

  static Future<void> remove(String id) async {
    try {
      await _pb.collection(_col).delete(id);
    } catch (_) {
      // Удаление не критично: пусть остаётся, чем ронять экран.
    }
  }
}
