import 'dart:io';

import 'package:flutter/material.dart';

import '../../widgets/storage_image.dart';

/// Баннер профиля со скруглённым низом. Один виджет для своего профиля
/// (с кнопкой смены) и профиля партнёра (только показ). Источник по приоритету:
/// сетевой URL (синк, виден партнёру) → локальный файл (легаси) → тональный фон.
class ProfileBanner extends StatelessWidget {
  final String bannerUrl;
  final String? localPath;
  final Color background;
  final double height;
  final VoidCallback? onPick; // задан → показываем кнопку смены (свой профиль)

  const ProfileBanner({
    super.key,
    this.bannerUrl = '',
    this.localPath,
    required this.background,
    this.height = 168,
    this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    Widget? img;
    if (bannerUrl.isNotEmpty) {
      img = StorageImage(
        imageUrl: bannerUrl,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => const SizedBox.shrink(),
      );
    } else if (localPath != null) {
      img = Image.file(
        File(localPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
        color: background,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (img != null) img,
          if (onPick != null)
            Positioned(
              top: 12,
              right: 12,
              child: GestureDetector(
                onTap: onPick,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.30),
                  ),
                  child: const Icon(Icons.photo_camera_rounded,
                      size: 18, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
