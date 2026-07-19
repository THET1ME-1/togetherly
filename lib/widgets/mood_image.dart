import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/mood_entry.dart';
import '../theme/theme_scope.dart';

/// Единый рендер картинки настроения по [imagePath].
///
/// Путь может быть:
///   • бандленным ассетом  ('assets/images/...')      → [Image.asset]
///   • удалённым URL пака из каталога ('https://...')  → [CachedNetworkImage]
///     (качается один раз, лежит в дисковом кэше; публичный bucket, без подписи).
///
/// Для удалённых паков, которых нет в текущей сборке, при ошибке загрузки
/// пытаемся показать классический эквивалент по id ([MoodOption.classicFallbackFor])
/// — чтобы у партнёра на старой сборке/без сети не было «битой» картинки.
class MoodImage extends StatelessWidget {
  final String imagePath;
  final BoxFit fit;
  final double? width;
  final double? height;

  const MoodImage(
    this.imagePath, {
    super.key,
    this.fit = BoxFit.contain,
    this.width,
    this.height,
  });

  static bool _isRemote(String p) =>
      p.startsWith('http://') || p.startsWith('https://');

  @override
  Widget build(BuildContext context) {
    if (imagePath.isEmpty) return SizedBox(width: width, height: height);

    if (!_isRemote(imagePath)) {
      return Image.asset(
        imagePath,
        fit: fit,
        width: width,
        height: height,
        errorBuilder: (ctx, __, ___) => _fallback(ctx),
      );
    }

    return CachedNetworkImage(
      imageUrl: imagePath,
      fit: fit,
      width: width,
      height: height,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, __) => SizedBox(width: width, height: height),
      errorWidget: (ctx, __, ___) => _fallback(ctx),
    );
  }

  /// Фолбэк: классический ассет по id настроения, иначе нейтральная иконка.
  Widget _fallback(BuildContext context) {
    final classic = MoodOption.classicFallbackFor(imagePath);
    if (classic != null) {
      return Image.asset(
        classic,
        fit: fit,
        width: width,
        height: height,
        errorBuilder: (ctx, __, ___) => _icon(ctx),
      );
    }
    return _icon(context);
  }

  Widget _icon(BuildContext context) => Icon(
        Icons.sentiment_satisfied_alt_rounded,
        size: (width ?? height ?? 32) * 0.7,
        color: context.appTheme.textMuted,
      );
}
