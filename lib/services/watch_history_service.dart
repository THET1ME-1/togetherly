import 'package:pocketbase/pocketbase.dart';

import 'pocketbase_service.dart';

/// Одна строчка истории просмотров пары.
class WatchEntry {
  final String id;
  final String url;
  final String kind;
  final String title;
  final String thumb;
  final int seconds;

  const WatchEntry({
    required this.id,
    required this.url,
    required this.kind,
    required this.title,
    required this.thumb,
    required this.seconds,
  });

  factory WatchEntry.fromRecord(RecordModel r) => WatchEntry(
        id: r.id,
        url: (r.data['url'] ?? '').toString(),
        kind: (r.data['kind'] ?? '').toString(),
        title: (r.data['title'] ?? '').toString(),
        thumb: (r.data['thumb'] ?? '').toString(),
        seconds: ((r.data['seconds'] ?? 0) as num).round(),
      );

  /// Что показать в ленте, когда площадка не отдала название.
  String get label {
    if (title.isNotEmpty) return title;
    if (url.startsWith('file://')) return url.substring(7);
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host.replaceFirst('www.', '');
  }
}

/// История просмотров: что пара уже включала и на какой секунде остановилась.
///
/// Одна запись на ролик — повторный просмотр обновляет её, а не плодит новую
/// (в базе на это стоит уникальный индекс по паре и ссылке).
class WatchHistoryService {
  WatchHistoryService._();

  static const String _col = 'watch_history';

  static PocketBase get _pb => PocketBaseService.instance.pb;

  /// Последние просмотры пары, свежие сверху.
  static Future<List<WatchEntry>> recent(String groupId, {int limit = 12}) async {
    if (groupId.isEmpty) return const [];
    try {
      final res = await _pb.collection(_col).getList(
            page: 1,
            perPage: limit,
            filter: 'group_id = "$groupId"',
            sort: '-updated',
          );
      return res.items.map(WatchEntry.fromRecord).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Записывает включённый ролик. Если он уже был, обновляет запись —
  /// так лента показывает последние просмотры, а не список дублей.
  static Future<void> remember({
    required String groupId,
    required String url,
    String kind = '',
    String title = '',
    String thumb = '',
    int seconds = 0,
  }) async {
    if (groupId.isEmpty || url.isEmpty) return;
    final uid = PocketBaseService().userId ?? '';
    final body = <String, dynamic>{
      'group_id': groupId,
      'url': url,
      'kind': kind,
      'title': title,
      'thumb': thumb,
      'seconds': seconds,
      'added_by': uid,
    };

    try {
      final found = await _pb.collection(_col).getList(
            page: 1,
            perPage: 1,
            filter: 'group_id = "$groupId" && url = "${url.replaceAll('"', '')}"',
          );
      if (found.items.isNotEmpty) {
        // Название и обложку не затираем пустыми: их отдаёт не каждая площадка.
        final old = found.items.first;
        if (title.isEmpty) body['title'] = old.data['title'] ?? '';
        if (thumb.isEmpty) body['thumb'] = old.data['thumb'] ?? '';
        await _pb.collection(_col).update(old.id, body: body);
      } else {
        await _pb.collection(_col).create(body: body);
      }
    } catch (_) {
      // История — вещь необязательная: молча пропускаем, просмотр важнее.
    }
  }
}
