import 'dart:convert';

import 'package:http/http.dart' as http;

import 'pocketbase_service.dart';

/// Комната совместного просмотра.
///
/// Код комнаты выдаёт сервер по связи пары, а не придумывает клиент: оба
/// устройства спрашивают его сами и молча оказываются в одной комнате. Тот же
/// код зовёт партнёра в браузер — на сайте комната ровно та же.
class WatchRoomService {
  WatchRoomService._();

  static final Map<String, String> _cache = {};

  /// Адрес комнаты на сайте для кода [room].
  static String siteUrl(String room) =>
      'https://togetherly.day/watch/room/#$room';

  /// Код комнаты пары. Пустая строка означает отказ сервера — вызывающий
  /// показывает ошибку и не открывает просмотр.
  static Future<String> roomCode(String groupId) async {
    if (groupId.isEmpty) return '';
    final cached = _cache[groupId];
    if (cached != null) return cached;

    final pb = PocketBaseService.instance.pb;
    final token = pb.authStore.token;
    if (token.isEmpty) return '';

    try {
      final res = await http
          .post(
            Uri.parse('${PocketBaseService.baseUrl}/api/watch/room'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': token,
            },
            body: jsonEncode({'groupId': groupId}),
          )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode != 200) return '';
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final room = (data['room'] ?? '').toString();
      if (room.isNotEmpty) _cache[groupId] = room;
      return room;
    } catch (_) {
      return '';
    }
  }
}
