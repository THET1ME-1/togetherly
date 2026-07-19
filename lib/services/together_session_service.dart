import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'pb_auth_service.dart';
import 'pb_data_service.dart';
import 'pb_realtime_service.dart';
import 'pocketbase_service.dart';

/// Тип совместного занятия. Сейчас реализован только youtube; music/book
/// переиспользуют тот же канал синхронизации.
enum TogetherActivity { youtube, music, book }

extension TogetherActivityX on TogetherActivity {
  String get id => name;
  static TogetherActivity fromId(String? v) =>
      TogetherActivity.values.firstWhere(
        (a) => a.name == v,
        orElse: () => TogetherActivity.youtube,
      );
}

/// Эфемерное состояние совместного сеанса (PocketBase `live_sessions`, id=pairId).
@immutable
class LiveSessionState {
  final TogetherActivity activity;
  final String mediaId; // youtube videoId (или ключ контента для music/book)
  final bool isPlaying;
  final int positionMs;
  final int lastActionAt; // epoch ms (клиентское время действия)
  final String controllerUid; // кто инициировал последнее действие
  final int seq; // монотонный номер действия для отбрасывания эха

  const LiveSessionState({
    required this.activity,
    required this.mediaId,
    required this.isPlaying,
    required this.positionMs,
    required this.lastActionAt,
    required this.controllerUid,
    required this.seq,
  });

  /// PocketBase-запись `live_sessions` (snake_case колонки) → состояние.
  factory LiveSessionState.fromPb(RecordModel rec) {
    final d = rec.data;
    return LiveSessionState(
      activity: TogetherActivityX.fromId(d['activity'] as String?),
      mediaId: (d['media_id'] ?? '').toString(),
      isPlaying: d['is_playing'] == true,
      positionMs: (d['position_ms'] as num?)?.toInt() ?? 0,
      lastActionAt: (d['last_action_at'] as num?)?.toInt() ?? 0,
      controllerUid: (d['controller_uid'] ?? '').toString(),
      seq: (d['seq'] as num?)?.toInt() ?? 0,
    );
  }

  /// Ожидаемая позиция «сейчас» с поправкой на прошедшее время, когда играет.
  int expectedPositionMs(int nowMs) {
    if (!isPlaying) return positionMs;
    final elapsed = nowMs - lastActionAt;
    return positionMs + (elapsed > 0 ? elapsed : 0);
  }
}

/// Сообщение эфемерного чата сеанса (живёт в RTDB, исчезает с сессией).
@immutable
class ChatMessage {
  final String id;
  final String uid;
  final String name;
  final String text;
  final int ts;

  /// Реакции: uid → эмодзи (один на пользователя). Лежат в узле сообщения.
  final Map<String, String> reactions;

  /// Ответ на сообщение: id оригинала + снимок имени/текста.
  final String? replyToId;
  final String? replyToName;
  final String? replyToText;

  const ChatMessage({
    required this.id,
    required this.uid,
    required this.name,
    required this.text,
    required this.ts,
    this.reactions = const {},
    this.replyToId,
    this.replyToName,
    this.replyToText,
  });

  /// PocketBase-запись `live_session_chat` (snake_case) → сообщение. id = id записи.
  factory ChatMessage.fromPb(RecordModel rec) {
    final m = rec.data;
    String? nz(dynamic v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    final rawReactions = m['reactions'];
    final reactions = <String, String>{};
    if (rawReactions is Map) {
      rawReactions.forEach((k, v) {
        if (v is String && v.isNotEmpty) reactions[k.toString()] = v;
      });
    }
    return ChatMessage(
      id: rec.id,
      uid: (m['uid'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      text: (m['text'] ?? '').toString(),
      ts: (m['ts'] as num?)?.toInt() ?? 0,
      reactions: reactions,
      replyToId: nz(m['reply_to_id']),
      replyToName: nz(m['reply_to_name']),
      replyToText: nz(m['reply_to_text']),
    );
  }
}

/// Сервис совместных занятий на PocketBase (миграция §3): состояние плеера —
/// `live_sessions` (id=pairId), презенс — `live_session_presence` (heartbeat+TTL
/// вместо RTDB onDisconnect), эфемерный чат — `live_session_chat`. Приглашение
/// партнёра — [TogetherInviteRepository] (group.active_session).
class TogetherSessionService {
  TogetherSessionService._();
  static final TogetherSessionService instance = TogetherSessionService._();

  final PbDataService _data = PbDataService();
  final PbRealtimeService _rt = PbRealtimeService();

  String get _uid => PocketBaseService().userId ?? '';
  String get _name =>
      PbAuthService().currentProfile()?['displayName'] as String? ?? '';

  /// Локальный счётчик действий — растёт быстрее серверного seq, чтобы наши
  /// собственные апдейты, вернувшиеся через подписку, можно было отбросить.
  int _localSeq = 0;
  int get lastLocalSeq => _localSeq;

  // ── Презенс на heartbeat+TTL (без RTDB onDisconnect) ──────────────────────
  // Клиент периодически обновляет seen_at; watcher считает участника «в сеансе»,
  // если метка свежее [_presenceFreshMs]. Ungraceful-выход → метка протухает.
  static const int _presenceFreshMs = 20000;
  Timer? _presenceTimer;

  void _startPresenceHeartbeat(String pairId) {
    if (_uid.isEmpty) return;
    unawaited(_data.touchSessionPresence(pairId, _uid));
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_uid.isNotEmpty) unawaited(_data.touchSessionPresence(pairId, _uid));
    });
  }

  void _stopPresenceHeartbeat() {
    _presenceTimer?.cancel();
    _presenceTimer = null;
  }

  /// Создать/перезапустить сеанс (вызывает хост) + начать heartbeat презенса.
  Future<void> startSession({
    required String pairId,
    required String partnerUid,
    required TogetherActivity activity,
    required String mediaId,
  }) async {
    if (pairId.isEmpty || _uid.isEmpty) return;
    _localSeq = 0;
    await _data.startSession(pairId, {
      'activity': activity.id,
      'mediaId': mediaId,
      'isPlaying': false,
      'positionMs': 0,
      'controllerUid': _uid,
      'seq': 0,
    });
    _startPresenceHeartbeat(pairId);
  }

  /// Легаси RTDB-членство больше не нужно (PB-правила — по группе). No-op.
  Future<void> ensureMember(String pairId) async {}

  /// Присоединиться (вызывает приглашённый партнёр) — стартует heartbeat презенса.
  Future<void> joinPresence(String pairId) async {
    if (pairId.isEmpty || _uid.isEmpty) return;
    _startPresenceHeartbeat(pairId);
  }

  /// Поток присутствия: множество uid со свежей меткой seen_at.
  Stream<Set<String>> watchPresence(String pairId) {
    return _rt.watchSessionPresence(pairId).map((rows) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final out = <String>{};
      for (final r in rows) {
        final seen = (r.data['seen_at'] as num?)?.toInt() ?? 0;
        final uid = (r.data['user_uid'] ?? '').toString();
        if (uid.isNotEmpty && now - seen < _presenceFreshMs) out.add(uid);
      }
      return out;
    });
  }

  /// Поток состояния сеанса. null — сеанса нет (запись удалена).
  Stream<LiveSessionState?> watch(String pairId) {
    return _rt.watchSession(pairId).map((rec) {
      if (rec == null) return null;
      final s = LiveSessionState.fromPb(rec);
      return s.mediaId.isEmpty ? null : s;
    });
  }

  /// Запушить действие (play/pause/seek/heartbeat). Возвращает использованный seq.
  Future<int> pushAction({
    required String pairId,
    required bool isPlaying,
    required int positionMs,
    String? mediaId,
  }) async {
    if (pairId.isEmpty || _uid.isEmpty) return _localSeq;
    _localSeq++;
    final seq = _localSeq;
    await _data.pushSessionAction(pairId, {
      'isPlaying': isPlaying,
      'positionMs': positionMs,
      'controllerUid': _uid,
      'seq': seq,
      'mediaId': mediaId,
    });
    return seq;
  }

  // ── Эфемерный чат сеанса (PB live_session_chat) ──────────────────────────
  /// Отправить сообщение в чат сеанса. [replyTo*] — опциональный ответ.
  Future<void> sendChatMessage({
    required String pairId,
    required String text,
    String? replyToId,
    String? replyToName,
    String? replyToText,
  }) async {
    final t = text.trim();
    if (t.isEmpty || pairId.isEmpty || _uid.isEmpty) return;
    await _data.sendSessionChat(pairId, {
      'uid': _uid,
      'name': _name,
      'text': t,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'replyToId': replyToId,
      'replyToName': replyToName,
      'replyToText': replyToText,
    });
  }

  /// Поставить/снять свою реакцию на сообщение. [emoji] == null убирает её.
  Future<void> setChatReaction({
    required String pairId,
    required String messageId,
    required String? emoji,
  }) async {
    if (messageId.isEmpty || _uid.isEmpty) return;
    await _data.setSessionChatReaction(messageId, _uid, emoji);
  }

  /// Живой список сообщений чата сеанса (старые сверху). Заменяет прежние два
  /// delta-стрима (onChildAdded/onChildChanged) — экран пересобирает список и
  /// реакции из снапшота.
  Stream<List<ChatMessage>> watchSessionChat(String pairId) {
    return _rt
        .watchSessionChat(pairId)
        .map((recs) => recs.map(ChatMessage.fromPb).toList());
  }

  /// Завершить сеанс — удалить запись + презенс + чат.
  Future<void> endSession(String pairId) async {
    if (pairId.isEmpty) return;
    _stopPresenceHeartbeat();
    await _data.endSession(pairId);
  }

  /// Покинуть сеанс, не убивая его для партнёра (снять свой презенс).
  Future<void> leavePresence(String pairId) async {
    if (pairId.isEmpty || _uid.isEmpty) return;
    _stopPresenceHeartbeat();
    await _data.removeSessionPresence(pairId, _uid);
  }
}
