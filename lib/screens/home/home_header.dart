import '../../widgets/mood_image.dart';
import '../../widgets/storage_image.dart';
import 'package:flutter/material.dart';
import '../../utils/safe_text.dart';
import '../../models/pair_data.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common/animations.dart';
import '../miss_you_button.dart';
import 'widgets/relationship_type_dialog.dart';

/// Шапка главного экрана: аватары, бейдж статуса, кнопка «Скучаю».
class HomeHeader extends StatelessWidget {
  final AppTheme theme;
  final bool isPaired;
  final int partnerCount;
  final String myAvatarUrl;
  final String myDisplayName;
  final List<GroupMember> partners;
  final MemberMood myMood;
  final MemberMood Function(String uid) moodOf;
  final String statusBadgeText;
  final String statusBadgeEmoji;
  final VoidCallback? onRelationshipTap;
  final String pairId;

  const HomeHeader({
    super.key,
    required this.theme,
    required this.isPaired,
    required this.partnerCount,
    required this.myAvatarUrl,
    required this.myDisplayName,
    required this.partners,
    required this.myMood,
    required this.moodOf,
    required this.statusBadgeText,
    required this.statusBadgeEmoji,
    this.onRelationshipTap,
    required this.pairId,
  });

  @override
  Widget build(BuildContext context) {
    final primary = theme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 16, 8),
      child: Row(
        children: [
          // Аватары (фиксированная ширина)
          if (isPaired) ...[ 
            SizedBox(
              width: 28.0 + 40.0 + (partnerCount - 1).clamp(0, 3) * 28.0,
              height: 48,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    top: 4,
                    child: _avatarWithMood(
                      myAvatarUrl,
                      name: myDisplayName,
                      mood: myMood,
                      moodPosition: MoodBadgePosition.topLeft,
                      primary: primary,
                    ),
                  ),
                  ...List.generate(
                    partners.length.clamp(0, 4),
                    (i) => Positioned(
                      left: 28.0 + i * 28.0,
                      top: 4,
                      child: _avatarWithMood(
                        partners[i].avatar,
                        name: partners[i].name,
                        mood: moodOf(partners[i].uid),
                        moodPosition: MoodBadgePosition.bottomRight,
                        primary: primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            _avatarCircle(myAvatarUrl, name: myDisplayName, primary: primary),
          ],
          const SizedBox(width: 8),
          // Бейдж статуса — Flexible, чтобы не выталкивал кнопку «Скучаю»
          Flexible(
            child: GestureDetector(
              onTap: isPaired ? onRelationshipTap : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isPaired
                      ? primary.withValues(alpha:0.1)
                      : theme.surfaceMuted,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isPaired
                        ? primary.withValues(alpha:0.1)
                        : theme.divider,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      statusBadgeEmoji.isNotEmpty
                          ? relIconForEmoji(statusBadgeEmoji)
                          : Icons.favorite_border,
                      color: isPaired ? primary : theme.textMuted,
                      size: 15,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        statusBadgeText,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isPaired ? primary : theme.textMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isPaired) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.expand_more_rounded,
                        size: 14,
                        color: primary.withValues(alpha:0.6),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (isPaired) ...[
            const SizedBox(width: 8),
            MissYouButton(
              theme: theme,
              groupId: pairId,
              senderName: myDisplayName,
              enabled: isPaired,
            ),
          ],
        ],
      ),
    );
  }

  static Widget _avatarCircle(
    String url, {
    String? name,
    required Color primary,
  }) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha:0.06), blurRadius: 6),
        ],
      ),
      child: ClipOval(
        child: url.isNotEmpty
            ? StorageImage(
                imageUrl: url,
                fit: BoxFit.cover,
                memCacheWidth: 120,
                memCacheHeight: 120,
                errorWidget: (context, url, error) =>
                    _avatarPlaceholder(name, primary: primary),
              )
            : _avatarPlaceholder(name, primary: primary),
      ),
    );
  }

  static Widget _avatarPlaceholder(String? name, {required Color primary}) {
    final initial = (name ?? '').firstGraphemeUpper('?');
    return Container(
      color: primary.withValues(alpha:0.15),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: primary,
          ),
        ),
      ),
    );
  }

  static Widget _avatarWithMood(
    String url, {
    String? name,
    required MemberMood mood,
    MoodBadgePosition moodPosition = MoodBadgePosition.bottomRight,
    required Color primary,
  }) {
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 4,
            top: 4,
            child: _avatarCircle(url, name: name, primary: primary),
          ),
          if (mood.isNotEmpty)
            Positioned(
              top: moodPosition == MoodBadgePosition.topLeft ? -4 : null,
              bottom: moodPosition == MoodBadgePosition.bottomRight ? -4 : null,
              left: moodPosition == MoodBadgePosition.topLeft ? -4 : null,
              right: moodPosition == MoodBadgePosition.bottomRight ? -4 : null,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha:0.1),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: mood.imagePath.isNotEmpty
                    ? ClipOval(
                        child: MoodImage(
                          mood.imagePath,
                          width: 22,
                          height: 22,
                          fit: BoxFit.cover,
                        ),
                      )
                    : const SizedBox(width: 22, height: 22),
              ),
            ),
        ],
      ),
    );
  }
}
