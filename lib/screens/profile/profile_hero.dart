import 'package:flutter/material.dart';

import '../../theme/profile_theme.dart';
import '../../widgets/avatar_widget.dart';
import 'profile_banner.dart';

/// Шапка профиля (приём Kadr): баннер со скруглённым низом + аватар, свисающий
/// в кольце поверхности, справа имя и чип. Общая для СВОЕГО профиля
/// (редактируемая: заданы [onEdit]/[onPickBanner]/[onTapAvatar]) и профиля
/// ПАРТНЁРА (только показ — колбэки null: нет карандаша и кнопок камеры).
class ProfileHero extends StatelessWidget {
  final ColorScheme cs;
  final String uid;
  final String avatarUrl;
  final String name;
  final String bannerUrl;
  final String? localBannerPath;
  final String subtitle;
  final VoidCallback? onEdit;
  final VoidCallback? onPickBanner;
  final VoidCallback? onTapAvatar;

  const ProfileHero({
    super.key,
    required this.cs,
    required this.uid,
    required this.avatarUrl,
    required this.name,
    required this.bannerUrl,
    this.localBannerPath,
    this.subtitle = '',
    this.onEdit,
    this.onPickBanner,
    this.onTapAvatar,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            ProfileBanner(
              bannerUrl: bannerUrl,
              localPath: localBannerPath,
              background: cs.primaryContainer,
              onPick: onPickBanner,
            ),
            Positioned(
              left: 20,
              bottom: -40,
              child: GestureDetector(
                onTap: onTapAvatar,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: cs.surface),
                      child: AvatarWidget(
                        uid: uid,
                        liveUrl: avatarUrl,
                        name: name,
                        size: 84,
                        primary: cs.primary,
                      ),
                    ),
                    if (onTapAvatar != null)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: cs.primary,
                            border: Border.all(color: cs.surface, width: 2),
                          ),
                          child: Icon(Icons.photo_camera_rounded,
                              size: 14, color: cs.onPrimary),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(122, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: ProfileTheme.displayFont,
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  if (onEdit != null) ...[
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: onEdit,
                      child: Icon(Icons.edit_rounded,
                          size: 18, color: cs.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 9),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    subtitle,
                    style: TextStyle(
                      fontFamily: ProfileTheme.bodyFont,
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
