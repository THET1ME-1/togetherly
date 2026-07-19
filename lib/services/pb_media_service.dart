import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'pocketbase_service.dart';

/// Медиа-слой PocketBase (миграция Firebase→PB, Этап 6).
///
/// Заменяет Firebase Storage. В PB файлы крепятся к записям через file-поле —
/// один блоб = одна запись коллекции `media`. В текстовые поля сущностей
/// (photo_url/image_url/music_url/...) кладём ссылку схемы `pb://media/<id>/<file>`,
/// которая резолвится в `<baseUrl>/api/files/media/<id>/<file>`.
///
/// (Схема `pb://` зеркалит прежнюю `sb://` из supabase-слоя — на cutover
/// резолвер медиа в виджетах распознаёт `pb://` так же, как раньше `sb://`.)
class PbMediaService {
  PbMediaService._();
  static final PbMediaService instance = PbMediaService._();
  factory PbMediaService() => instance;

  PocketBase get _pb => PocketBaseService().pb;
  static const String _col = 'media';
  static const String scheme = 'pb://';

  /// Загружает байты как новый media-файл. Возвращает ссылку
  /// `pb://media/<recordId>/<filename>` или null при ошибке.
  Future<String?> uploadBytes(
    List<int> bytes,
    String filename, {
    String? uid,
    String? groupId,
    String? kind,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (uid != null) body['uid'] = uid;
      if (groupId != null) body['group_id'] = groupId;
      if (kind != null) body['kind'] = kind;
      // Жёсткий таймаут: без него зависшая заливка с iOS (медленная сеть/LTE,
      // повисший multipart) крутила «бесконечную загрузку» в лоадере виджет-фото
      // — await никогда не возвращался. По таймауту → исключение → возвращаем
      // null → UI закрывает лоадер и даёт повторить. 60с хватает на фото ~1-2 МБ.
      final rec = await _pb
          .collection(_col)
          .create(
            body: body,
            files: [
              http.MultipartFile.fromBytes('file', bytes, filename: filename),
            ],
          )
          .timeout(const Duration(seconds: 60));
      // PB мог переименовать файл (суффикс против коллизий) → берём фактическое.
      final stored = (rec.data['file'] ?? filename).toString();
      return '$scheme$_col/${rec.id}/$stored';
    } catch (e) {
      debugPrint('PbMedia.uploadBytes failed: $e');
      // Диагностика «не удалось загрузить фото/видео»: реальную причину (403 ACL,
      // 401 протухшая сессия, сеть, валидация) глотал только debugPrint и она не
      // была видна в проде. Кидаем в Bugsink с контекстом — статус-код у
      // ClientException укажет точную причину сбоя загрузки воспоминания.
      final statusCode = e is ClientException ? e.statusCode : null;
      final response = e is ClientException ? e.response.toString() : null;
      unawaited(Sentry.captureException(e, withScope: (s) {
        s.level = SentryLevel.warning;
        s.setExtra('reason', 'PbMedia.uploadBytes failed');
        s.setExtra('kind', kind ?? '(none)');
        s.setExtra('hasUid', (uid != null && uid.isNotEmpty).toString());
        s.setExtra('hasGroupId', (groupId != null && groupId.isNotEmpty).toString());
        s.setExtra('loggedIn', PocketBaseService().isLoggedIn.toString());
        s.setExtra('filename', filename);
        if (statusCode != null) s.setExtra('statusCode', statusCode.toString());
        if (response != null) s.setExtra('pbResponse', response);
      }));
      return null;
    }
  }

  /// Загружает локальный файл по пути. Читает байты, имя — из пути. Возвращает
  /// `pb://`-ссылку или null. Удобная обёртка над [uploadBytes] для call-site'ов,
  /// которые раньше звали `FirebaseService.uploadFile(path, dest)`.
  Future<String?> uploadFile(
    String localPath, {
    String? uid,
    String? groupId,
    String? kind,
  }) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        debugPrint('PbMedia.uploadFile: файла нет: $localPath');
        return null;
      }
      final bytes = await file.readAsBytes();
      final filename = localPath.split(Platform.pathSeparator).last;
      return await uploadBytes(bytes, filename, uid: uid, groupId: groupId, kind: kind);
    } catch (e) {
      debugPrint('PbMedia.uploadFile($localPath) failed: $e');
      return null;
    }
  }

  /// `true`, если ссылка — наша PB-схема.
  bool isPbRef(String? url) => url != null && url.startsWith(scheme);

  /// Готовая к скачиванию/воспроизведению ссылка: `pb://` → authed HTTPS,
  /// остальное (http/локальные) — как есть. Заменяет прежний
  /// FirebaseService.resolveMediaUrl. Легаси `gs://`/`sb://` НЕ резолвятся
  /// (Firebase убран) — вернутся как есть и просто не загрузятся.
  Future<String> resolvePlayable(String url) async {
    if (isPbRef(url)) return (await resolveUrlAuthed(url)) ?? url;
    return url;
  }

  /// Резолвит `pb://media/<id>/<file>` → HTTPS-URL PB БЕЗ токена. Не-pb ссылки
  /// возвращает как есть. Файлы media теперь `protected` → этот «голый» URL без
  /// токена отдаст 403; используется как стабильный cacheKey и для разбора id.
  /// Для РЕАЛЬНОЙ загрузки/показа бери [resolveUrlAuthed].
  String? resolveUrl(String? ref) {
    if (ref == null || ref.isEmpty) return ref;
    if (!isPbRef(ref)) return ref;
    final path = ref.substring(scheme.length); // media/<id>/<file>
    return '${PocketBaseService.baseUrl}/api/files/$path';
  }

  // ── file-токен для protected-файлов ────────────────────────────────────────
  // Один короткоживущий токен открывает ВСЕ файлы, доступные текущему юзеру по
  // viewRule коллекции. Кэшируем и обновляем раньше истечения; стабильный
  // cacheKey (pb://-ссылка) в StorageImage не даёт смене токена сбрасывать кэш.
  String? _fileToken;
  DateTime? _fileTokenAt;
  Future<String?>? _tokenInflight;
  static const Duration _tokenTtl = Duration(seconds: 90);

  Future<String?> _ensureFileToken() {
    final t = _fileToken, at = _fileTokenAt;
    if (t != null && at != null && DateTime.now().difference(at) < _tokenTtl) {
      return Future.value(t);
    }
    final inflight = _tokenInflight;
    if (inflight != null) return inflight;
    final fut = () async {
      try {
        final tok = await _pb.files.getToken();
        _fileToken = tok;
        _fileTokenAt = DateTime.now();
        return tok;
      } catch (e) {
        debugPrint('PbMedia.getToken failed: $e');
        return _fileToken; // прошлый токен может быть ещё валиден
      } finally {
        _tokenInflight = null;
      }
    }();
    _tokenInflight = fut;
    return fut;
  }

  /// Резолвит `pb://` → HTTPS С `?token=` (доступ к protected-файлу). Не-pb
  /// ссылки — как есть. ВСЕ in-app загрузки/показ медиа идут через него.
  Future<String?> resolveUrlAuthed(String? ref) async {
    if (ref == null || ref.isEmpty) return ref;
    if (!isPbRef(ref)) return ref;
    final base = resolveUrl(ref);
    if (base == null) return ref;
    final tok = await _ensureFileToken();
    return (tok == null || tok.isEmpty) ? base : '$base?token=$tok';
  }

  /// Сброс кэша токена (на выходе/смене пользователя).
  void clearFileToken() {
    _fileToken = null;
    _fileTokenAt = null;
  }

  /// Удаляет media-запись по `pb://`-ссылке (или по recordId).
  Future<bool> delete(String refOrId) async {
    try {
      String id = refOrId;
      if (isPbRef(refOrId)) {
        final parts = refOrId.substring(scheme.length).split('/');
        if (parts.length >= 2) id = parts[1]; // media/<id>/<file>
      }
      if (id.isEmpty) return false;
      await _pb.collection(_col).delete(id);
      return true;
    } catch (e) {
      if (e is ClientException && e.statusCode == 404) return true;
      debugPrint('PbMedia.delete($refOrId) failed: $e');
      return false;
    }
  }
}
