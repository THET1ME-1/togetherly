import 'package:pocketbase/pocketbase.dart';

/// Сообщение постоянного чата пары. Хранится в PocketBase (коллекция
/// `chat_messages`); удаление мягкое (deleted=true + текст затирается).
///
/// Удаление мягкое (deleted=true + текст затирается), чтобы слушатель
/// партнёра мгновенно отрисовал «сообщение удалено», а не пустоту.
class ChatMsg {
  final String id;
  final String uid;
  final String name;
  final String text;
  final int ts;
  final int? editedTs;
  final bool deleted;

  /// Прикреплённый пин (воспоминание): id для перехода + заголовок для отрисовки.
  /// [pinThumb] — URL миниатюры (обложка/кадр/фото), опционально, для предпросмотра.
  final String? pinId;
  final String? pinTitle;
  final String? pinThumb;

  /// Реакции на сообщение: uid → эмодзи (один эмодзи на пользователя).
  /// Лежат в самом узле сообщения (reactions/{uid}), поэтому приходят вместе
  /// с сообщением — без отдельного listener'а.
  final Map<String, String> reactions;

  /// Ответ на сообщение: id оригинала + СНИМОК имени/текста на момент отправки
  /// (цитата остаётся читаемой, даже если оригинал потом отредактирован/удалён).
  final String? replyToId;
  final String? replyToName;
  final String? replyToText;

  /// Выражение мордочки, выбранное ОТПРАВИТЕЛЕМ (имя варианта). null — без лица.
  /// Лицо больше не угадывается по тексту — его осознанно ставит автор.
  final String? face;

  /// Цвет пузыря, выбранный отправителем (ARGB int). null — цвет темы.
  final int? color;

  /// Позиция мордочки на пузыре в долях 0..1 (по ширине/высоте).
  /// null — позиция по умолчанию (низ-центр).
  final double? faceX;
  final double? faceY;

  const ChatMsg({
    required this.id,
    required this.uid,
    required this.name,
    required this.text,
    required this.ts,
    this.editedTs,
    this.deleted = false,
    this.pinId,
    this.pinTitle,
    this.pinThumb,
    this.reactions = const {},
    this.replyToId,
    this.replyToName,
    this.replyToText,
    this.face,
    this.color,
    this.faceX,
    this.faceY,
  });

  bool get isEdited => editedTs != null && !deleted;

  /// PocketBase-запись (`chat_messages`) → модель. id = id записи.
  ///
  /// PB number/text-колонки не nullable (дефолт 0/''), а модель различает
  /// «не задано» (null) и значение. Поэтому коэрсим: `''`→null (face/pin/reply),
  /// `0`→null для edited_ts (нет правки), color (цвет темы) и face_x/face_y
  /// (позиция по умолчанию). Реальные значения этих полей всегда > 0 (color —
  /// непрозрачный ARGB с выставленной альфой; позиция мордочки на пузыре не в
  /// углу 0,0; edited_ts — epoch-ms), поэтому 0 однозначно = «не задано».
  factory ChatMsg.fromPb(RecordModel rec) {
    final m = rec.data;
    String? nz(dynamic v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    int? nzInt(dynamic v) {
      final n = (v as num?)?.toInt() ?? 0;
      return n == 0 ? null : n;
    }

    double? nzDouble(dynamic v) {
      final n = (v as num?)?.toDouble() ?? 0.0;
      return n == 0 ? null : n;
    }

    final rawReactions = m['reactions'];
    final reactions = <String, String>{};
    if (rawReactions is Map) {
      rawReactions.forEach((k, v) {
        if (v is String && v.isNotEmpty) reactions[k.toString()] = v;
      });
    }
    // ts — epoch-ms. У части мигрированных сообщений ts=0 (импортёр не проставил
    // время) → пузырь показывал «1 янв 1970» и пустой разделитель даты. Фолбэк
    // на время создания записи PB (rec.created), чтобы дата была осмысленной.
    final rawTs = (m['ts'] as num?)?.toInt() ?? 0;
    final ts = rawTs > 0
        ? rawTs
        : (DateTime.tryParse(rec.get<String>('created'))?.millisecondsSinceEpoch ??
            0);
    return ChatMsg(
      id: rec.id,
      uid: (m['user_uid'] ?? '').toString(),
      name: (m['user_name'] ?? '').toString(),
      text: (m['text'] ?? '').toString(),
      ts: ts,
      editedTs: nzInt(m['edited_ts']),
      deleted: m['deleted'] == true,
      pinId: nz(m['pin_id']),
      pinTitle: nz(m['pin_title']),
      pinThumb: nz(m['pin_thumb']),
      reactions: reactions,
      replyToId: nz(m['reply_to_id']),
      replyToName: nz(m['reply_to_name']),
      replyToText: nz(m['reply_to_text']),
      face: nz(m['face']),
      color: nzInt(m['color']),
      faceX: nzDouble(m['face_x']),
      faceY: nzDouble(m['face_y']),
    );
  }
}
