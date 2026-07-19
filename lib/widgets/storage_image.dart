import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/offline/media_cache.dart';
import '../services/offline/media_view_cache.dart';
import '../services/pb_media_service.dart';

/// Drop-in замена [CachedNetworkImage] с поддержкой pb:// / gs:// / sb:// путей.
///
/// Fast path: https:// и pb:// (PocketBase) → сразу [CachedNetworkImage] (pb://
/// резолвится синхронно в публичный HTTPS, без FutureBuilder/мигания).
/// Slow path: gs:// (Firebase) / sb:// (Supabase) → асинхронный Signed URL.
/// Старые https:// download URL работают без изменений (обратная совместимость).
class StorageImage extends StatefulWidget {
  const StorageImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit,
    this.placeholder,
    this.progressIndicatorBuilder,
    this.errorWidget,
    this.memCacheWidth,
    this.memCacheHeight,
    this.fadeInDuration = const Duration(milliseconds: 300),
  });

  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, DownloadProgress)? progressIndicatorBuilder;
  final Widget Function(BuildContext, String, dynamic)? errorWidget;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final Duration fadeInDuration;

  @override
  State<StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<StorageImage> {
  Future<String?>? _resolvedUrl;

  // Асинхронного разрешения требуют: gs:// (Firebase signed URL), sb:// (Supabase)
  // И pb:// (PocketBase protected-файл → нужен ?token=, добываемый асинхронно).
  // https:// и локальные пути рендерятся сразу.
  bool get _needsResolve => PbMediaService().isPbRef(widget.imageUrl);

  /// URL для немедленного рендера (только не-резолв-схемы: https/локальные).
  String get _fastUrl => widget.imageUrl;

  @override
  void initState() {
    super.initState();
    if (_needsResolve) _resolvedUrl = _resolve(widget.imageUrl);
  }

  @override
  void didUpdateWidget(StorageImage old) {
    super.didUpdateWidget(old);
    if (old.imageUrl != widget.imageUrl && _needsResolve) {
      _resolvedUrl = _resolve(widget.imageUrl);
    }
  }

  Future<String?> _resolve(String url) async {
    // Только pb:// (PocketBase protected media) → HTTPS с file-токеном.
    // Легаси gs:// / sb:// больше не резолвим (Firebase убран) — отдаём как есть.
    if (PbMediaService().isPbRef(url)) {
      return PbMediaService().resolveUrlAuthed(url);
    }
    return url;
  }

  // Стабильный cacheKey = исходная ссылка (pb://gs://sb://), чтобы смена
  // file-токена/signed-URL НЕ сбрасывала дисковый кэш картинки.
  // Префикс версии 'v2|': прежняя версия могла закэшировать ЧУЖОЕ фото под этим
  // ключом из-за бага переиспользования элементов ленты (FutureBuilder ниже
  // отдавал предыдущий resolved-URL на connectionState=waiting). Смена префикса
  // разово сбрасывает потенциально «отравленные» записи кэша на устройствах.
  Widget _buildCached(String url) => CachedNetworkImage(
        imageUrl: url,
        cacheKey: 'v2|${widget.imageUrl}',
        // Долгоживущий кэш → уже виденное фото гарантированно открывается офлайн.
        cacheManager: OfflineImageCacheManager.instance,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        placeholder: widget.placeholder,
        progressIndicatorBuilder: widget.progressIndicatorBuilder,
        errorWidget: widget.errorWidget,
        memCacheWidth: widget.memCacheWidth,
        memCacheHeight: widget.memCacheHeight,
        fadeInDuration: widget.fadeInDuration,
      );

  Widget _empty() =>
      widget.errorWidget?.call(context, widget.imageUrl, 'empty') ??
      SizedBox(width: widget.width, height: widget.height);

  @override
  Widget build(BuildContext context) {
    final url = widget.imageUrl;

    if (url.isEmpty) return _empty();

    // Офлайн-медиа: созданное без сети показываем прямо с диска (Image.file).
    if (MediaCache.instance.isLocalRef(url)) {
      final p = MediaCache.instance.localPath(url);
      if (p != null && File(p).existsSync()) {
        return Image.file(
          File(p),
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          errorBuilder: (_, _, _) => _empty(),
        );
      }
      return _empty();
    }

    // Fast path: https:// / pb:// → рендерим сразу, без async/мигания
    if (!_needsResolve) return _buildCached(_fastUrl);

    // Slow path: gs:// / sb:// / pb:// → ждём резолв (Signed URL / file-токен)
    return FutureBuilder<String?>(
      future: _resolvedUrl,
      builder: (context, snap) {
        // КРИТИЧНО: пока резолвится новый URL — показываем placeholder, а НЕ
        // snapshot.data. При смене imageUrl (элемент ленты переиспользован под
        // другое воспоминание — записи сортируются «новые сверху», индексы
        // сдвигаются) FutureBuilder временно отдаёт ПРЕДЫДУЩИЙ resolved-URL с
        // connectionState=waiting. Если его отрендерить, плитка нового
        // воспоминания покажет фото предыдущего И закэширует его под своим
        // cacheKey. Поэтому на waiting — строго placeholder.
        if (snap.connectionState == ConnectionState.waiting) {
          return widget.placeholder?.call(context, '') ??
              SizedBox(width: widget.width, height: widget.height);
        }
        final resolved = snap.data;
        if (resolved == null || resolved.isEmpty) return _empty();
        return _buildCached(resolved);
      },
    );
  }
}
