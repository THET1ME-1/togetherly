import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_msg.dart';
import 'offline/local_store.dart';
import 'offline/outbox_service.dart';
import 'offline/pb_id.dart';
import 'pb_data_service.dart';
import 'pb_realtime_service.dart';
import 'pocketbase_service.dart';

/// Сервис постоянного текстового чата пары — на PocketBase (миграция §3).
///
/// История сообщений и статусы прочтения живут в коллекциях PB `chat_messages`
/// и `chat_reads` (раньше — RTDB ради нуля Firestore-чтений; на self-hosted PB
/// чтения бесплатны → вся история live без лимитов/пагинации). «Печатает…» —
/// эфемерный маркер в `chat_typing` (heartbeat+TTL вместо RTDB onDisconnect).
/// Пуш партнёру шлёт [PbPushService] по SSE-дельте `chat_messages` (НЕ Firestore-
/// триггер). Локальные настройки (фон/прокрутка/цвета) — в SharedPreferences.
class ChatService {
  ChatService._();
  static final ChatService instance = ChatService._();

  final PbDataService _data = PbDataService();
  final PbRealtimeService _rt = PbRealtimeService();

  String get _uid => PocketBaseService().userId ?? '';

  /// Маркер «свежести» typing — печатает, если метка партнёра моложе этого.
  static const int _typingFreshMs = 8000;

  /// Легаси-членство RTDB для security-rules больше не нужно (PB-правила —
  /// по группе). No-op, сохранён ради вызова из chat_screen.
  Future<void> ensureMember(String groupId) async {}

  /// Легаси Supabase-бэкфилл (Supabase откатили). No-op, сохранён ради вызова
  /// из мёртвого оркестратора firebase_service; уйдёт с §7.
  Future<int> backfillToSupabase(String groupId) async => 0;

  /// Поток последних сообщений, отсортированных по времени. Ленивый режим:
  /// начальная выборка лишь новейших [limit] сообщений (а не всей истории —
  /// для активных пар история в тысячи сообщений вешала первый синк); догрузку
  /// старых делает экран чата прокруткой вверх (повторная подписка с бо́льшим
  /// [limit]). Кэш хранит просмотренное; новые сообщения приходят live-дельтой.
  Stream<List<ChatMsg>> watchMessages(String groupId, {int limit = 100}) {
    if (groupId.isEmpty) return const Stream.empty();
    return _rt
        .watchMessages(groupId, limit: limit)
        .map((recs) => recs.map(ChatMsg.fromPb).toList());
  }

  /// Отправить сообщение. [pinId]/[pinTitle] — опционально прикреплённый пин.
  /// Возвращает true при успехе. false = сообщение НЕ сохранено (экран должен
  /// вернуть ввод и дать повторить, иначе текст теряется молча).
  Future<bool> send({
    required String groupId,
    required String senderName,
    required String text,
    String? pinId,
    String? pinTitle,
    String? pinThumb,
    String? replyToId,
    String? replyToName,
    String? replyToText,
    String? face,
    int? color,
    double? faceX,
    double? faceY,
  }) async {
    final trimmed = text.trim();
    if (groupId.isEmpty || _uid.isEmpty || trimmed.isEmpty) return false;
    final id = newPbId();
    final ts = DateTime.now().millisecondsSinceEpoch;
    // 1) оптимистично в кэш (snake_case-колонки, как читает ChatMsg.fromPb)
    await LocalStore.instance.upsertRaw('chat_messages', id, {
      'id': id,
      'group_id': groupId,
      'user_uid': _uid,
      'user_name': senderName,
      'text': trimmed,
      'ts': ts,
      'deleted': false,
      'pin_id': ?pinId,
      'pin_title': ?pinTitle,
      'pin_thumb': ?pinThumb,
      'reply_to_id': ?replyToId,
      'reply_to_name': ?replyToName,
      'reply_to_text': ?replyToText,
      'face': ?face,
      'color': ?color,
      'face_x': ?faceX,
      'face_y': ?faceY,
    });
    // 2) в очередь (camelCase — как ожидает PbDataService.chatSend)
    await OutboxService.instance.enqueue('chatUpsert', {
      'groupId': groupId,
      'id': id,
      'msg': {
        'uid': _uid,
        'name': senderName,
        'text': trimmed,
        'ts': ts,
        'pinId': pinId,
        'pinTitle': pinTitle,
        'pinThumb': pinThumb,
        'replyToId': replyToId,
        'replyToName': replyToName,
        'replyToText': replyToText,
        'face': face,
        'color': color,
        'faceX': faceX,
        'faceY': faceY,
      },
    });
    // Пуш партнёру — через PbPushService (SSE на chat_messages при отправке очереди).
    return true; // оптимистично: сообщение в кэше и очереди
  }

  /// Редактировать своё сообщение. null-значения оформления СТИРАЮТ поле:
  /// face→'' и color/face_x/face_y→0 (ChatMsg.fromPb коэрсит ''/0 обратно в null),
  /// чтобы можно было снять лицо/вернуть цвет темы.
  Future<void> edit({
    required String groupId,
    required String messageId,
    required String newText,
    String? face,
    int? color,
    double? faceX,
    double? faceY,
  }) async {
    final trimmed = newText.trim();
    if (messageId.isEmpty || trimmed.isEmpty) return;
    final fields = <String, dynamic>{
      'text': trimmed,
      'edited_ts': DateTime.now().millisecondsSinceEpoch,
      'face': face ?? '',
      'color': color ?? 0,
      'face_x': faceX ?? 0,
      'face_y': faceY ?? 0,
    };
    await _patchCachedMessage(messageId, fields); // оптимистично
    await OutboxService.instance.enqueue('chatUpdate',
        {'id': messageId, 'fields': fields});
  }

  /// Мягко удалить сообщение (томбстоун — партнёр видит «сообщение удалено»).
  Future<void> delete({
    required String groupId,
    required String messageId,
  }) async {
    if (messageId.isEmpty) return;
    final fields = <String, dynamic>{
      'deleted': true,
      'text': '',
      'pin_id': '',
      'pin_title': '',
      'edited_ts': DateTime.now().millisecondsSinceEpoch,
    };
    await _patchCachedMessage(messageId, fields); // оптимистично
    await OutboxService.instance.enqueue('chatUpdate',
        {'id': messageId, 'fields': fields});
  }

  /// Оптимистично применить snake_case-поля к кэш-ряду сообщения.
  Future<void> _patchCachedMessage(
      String messageId, Map<String, dynamic> fields) async {
    final rec = await LocalStore.instance.getRecord('chat_messages', messageId);
    if (rec == null) return;
    final row = Map<String, dynamic>.from(rec.data)..addAll(fields);
    await LocalStore.instance.upsertRaw('chat_messages', messageId, row);
  }

  /// Поставить/снять свою реакцию на сообщение. [emoji] == null убирает её.
  /// Один эмодзи на пользователя: новый перезаписывает прежний (RMW по json).
  Future<void> setReaction({
    required String groupId,
    required String messageId,
    required String? emoji,
  }) async {
    if (messageId.isEmpty || _uid.isEmpty) return;
    // оптимистично: RMW reactions в кэш-ряду
    final rec = await LocalStore.instance.getRecord('chat_messages', messageId);
    if (rec != null) {
      final row = Map<String, dynamic>.from(rec.data);
      final cur = row['reactions'];
      final r =
          cur is Map ? Map<String, dynamic>.from(cur) : <String, dynamic>{};
      if (emoji == null || emoji.isEmpty) {
        r.remove(_uid);
      } else {
        r[_uid] = emoji;
      }
      row['reactions'] = r;
      await LocalStore.instance.upsertRaw('chat_messages', messageId, row);
    }
    // в очередь (setChatReaction идемпотентен: ставит uid→emoji / снимает)
    await OutboxService.instance.enqueue(
        'chatSetReaction', {'id': messageId, 'uid': _uid, 'emoji': emoji});
  }

  // ── «Печатает…» (эфемерный презенс на PB heartbeat+TTL) ─────────────────────

  /// Пометить «я печатаю» / снять. Маркер обновляется клиентом раз в ~3с пока
  /// идёт ввод (typing_at=now) и снимается при отправке/уходе (typing_at=0).
  Future<void> setTyping(String groupId, bool typing) async {
    if (groupId.isEmpty || _uid.isEmpty) return;
    await _data.setTyping(
        groupId, _uid, typing ? DateTime.now().millisecondsSinceEpoch : 0);
  }

  /// true — партнёр сейчас печатает (его маркер свежий, < 8с). Свой маркер не
  /// считаем. Метка протухает по времени → onDisconnect не нужен.
  Stream<bool> watchTyping(String groupId) {
    if (groupId.isEmpty) return Stream.value(false);
    return _rt.watchTyping(groupId).map((marks) {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in marks.entries) {
        if (entry.key == _uid) continue; // свой маркер не считаем
        if (now - entry.value < _typingFreshMs) return true;
      }
      return false;
    });
  }

  // ── Непрочитанные ──────────────────────────────────────────────────────────

  String _lastReadKey(String groupId) => 'chat_last_read_$groupId';

  // Кэш последнего опубликованного ts прочтения по группам — markRead зовётся
  // на каждый кадр, поэтому пишем в сеть только при росте значения.
  final Map<String, int> _syncedReadTs = {};

  /// Отметить чат прочитанным: локально (ts последнего открытия) + публикуем
  /// в PB `chat_reads`, чтобы партнёр увидел галочку.
  Future<void> markRead(String groupId, int lastMessageTs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastReadKey(groupId), lastMessageTs);

    if (groupId.isEmpty || _uid.isEmpty || lastMessageTs <= 0) return;
    if ((_syncedReadTs[groupId] ?? 0) >= lastMessageTs) return;
    _syncedReadTs[groupId] = lastMessageTs;
    final ok = await _data.chatRead(groupId, _uid, lastMessageTs);
    if (!ok) {
      _syncedReadTs.remove(groupId); // не вышло — позволим повторить позже
    }
  }

  /// Поток статусов прочтения {uid: lastReadTs}. Для галочек «прочитано»:
  /// своё сообщение прочитано, если его ts ≤ минимального ts среди остальных.
  Stream<Map<String, int>> watchReads(String groupId) {
    if (groupId.isEmpty) return const Stream.empty();
    return _rt.watchChatReads(groupId);
  }

  Future<int> _lastRead(String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_lastReadKey(groupId)) ?? 0;
  }

  /// ts последнего прочтения — публично, для разделителя «новые сообщения».
  Future<int> lastReadTs(String groupId) => _lastRead(groupId);

  // ── Фон чата (локальный, у каждого свой) ────────────────────────────────────

  String _bgKey(String groupId) => 'chat_bg_$groupId';

  /// Путь к локальному файлу фона чата (null — фон не задан).
  Future<String?> backgroundPath(String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_bgKey(groupId));
  }

  Future<void> setBackgroundPath(String groupId, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bgKey(groupId), path);
  }

  Future<void> clearBackground(String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_bgKey(groupId));
  }

  // ── Позиция прокрутки (локально, чтобы вернуться ровно туда же) ──────────────

  String _scrollKey(String groupId) => 'chat_scroll_$groupId';

  /// Сохранить позицию прокрутки чата (px от верха) — при перезаходе вернём
  /// человека ровно туда, где он остановился.
  Future<void> saveScrollOffset(String groupId, double px) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_scrollKey(groupId), px);
    } catch (_) {}
  }

  /// Сохранённая позиция прокрутки (null — не сохранена).
  Future<double?> loadScrollOffset(String groupId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getDouble(_scrollKey(groupId));
    } catch (_) {
      return null;
    }
  }

  // ── Недавние цвета сообщений (до 5, глобально) ──────────────────────────────

  static const String _kRecentColors = 'chat_recent_colors';

  Future<List<int>> loadRecentColors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_kRecentColors) ?? const <String>[])
          .map(int.tryParse)
          .whereType<int>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveRecentColors(List<int> colors) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _kRecentColors, colors.map((c) => '$c').toList());
    } catch (_) {}
  }

  /// Поток: есть ли непрочитанные сообщения от партнёра (для красной точки).
  /// Достаточно новейшего сообщения → ленивый limit:1 (не тянем всю историю
  /// ради одной точки); из общего кэша чата `recs.last` всё равно = последнее.
  Stream<bool> watchHasUnread(String groupId) {
    if (groupId.isEmpty) return Stream.value(false);
    return _rt.watchMessages(groupId, limit: 1).asyncMap((recs) async {
      if (recs.isEmpty) return false;
      final last = ChatMsg.fromPb(recs.last); // watchMessages сортирует по ts ASC
      if (last.uid == _uid) return false; // своё сообщение
      if (last.deleted) return false;
      final lastRead = await _lastRead(groupId);
      return last.ts > lastRead;
    });
  }
}
