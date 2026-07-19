import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import 'storage_image.dart';
import '../utils/safe_text.dart';

/// Милая «запечатанная» карточка капсулы времени в ленте: подарок с замочком,
/// дата открытия и обратный отсчёт. Контент капсулы не показывается до срока.
/// При тапе — лёгкое покачивание + подсказка «ещё рано».
class SealedCapsuleCard extends StatefulWidget {
  final AppTheme theme;
  final String authorName;
  final String authorAvatar;
  final DateTime openAt;
  final VoidCallback onTapTooEarly;

  const SealedCapsuleCard({
    super.key,
    required this.theme,
    required this.authorName,
    required this.authorAvatar,
    required this.openAt,
    required this.onTapTooEarly,
  });

  @override
  State<SealedCapsuleCard> createState() => _SealedCapsuleCardState();
}

class _SealedCapsuleCardState extends State<SealedCapsuleCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wiggle;

  @override
  void initState() {
    super.initState();
    _wiggle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
  }

  @override
  void dispose() {
    _wiggle.dispose();
    super.dispose();
  }

  void _onTap() {
    _wiggle.forward(from: 0);
    widget.onTapTooEarly();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final s = LocaleService.current;
    final days = widget.openAt.difference(DateTime.now()).inDays;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: GestureDetector(
        onTap: _onTap,
        child: AnimatedBuilder(
          animation: _wiggle,
          builder: (context, child) {
            // Затухающее покачивание ±0.05 рад.
            final angle =
                math.sin(_wiggle.value * math.pi * 4) * 0.05 * (1 - _wiggle.value);
            return Transform.rotate(angle: angle, child: child);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  t.primary.withValues(alpha: 0.14),
                  t.primaryLight.withValues(alpha: 0.10),
                ],
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: t.primary.withValues(alpha: 0.22),
                width: 1.2,
              ),
            ),
            child: Column(
              children: [
                _gift(t),
                const SizedBox(height: 14),
                Text(
                  s.timeCapsule,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: t.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                // Дата открытия
                Text(
                  s.capsuleOpensOn(_fmt(widget.openAt)),
                  style: TextStyle(
                    fontSize: 13.5,
                    color: t.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                // Обратный отсчёт-пилюля
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: t.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('⏳', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 6),
                      Text(
                        s.capsuleOpensIn(days),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: t.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _fromLine(t, s),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _gift(AppTheme t) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [t.primary, t.primaryLight],
            ),
            boxShadow: [
              BoxShadow(
                color: t.primary.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const Text('🎁', style: TextStyle(fontSize: 38)),
        )
            .animate(onPlay: (c) => c.repeat(reverse: true))
            .scaleXY(begin: 1, end: 1.06, duration: 1400.ms, curve: Curves.easeInOut)
            .moveY(begin: 0, end: -3, duration: 1400.ms, curve: Curves.easeInOut),
        // Замочек
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: t.cardSurface,
              shape: BoxShape.circle,
              border: Border.all(color: t.primary.withValues(alpha: 0.25)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 6,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(Icons.lock_rounded, size: 16, color: t.primary),
          ),
        ),
      ],
    );
  }

  Widget _fromLine(AppTheme t, AppStrings s) {
    final name = widget.authorName.trim();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: ClipOval(
            child: widget.authorAvatar.isNotEmpty
                ? StorageImage(
                    imageUrl: widget.authorAvatar,
                    fit: BoxFit.cover,
                    memCacheWidth: 64,
                    memCacheHeight: 64,
                    errorWidget: (_, __, ___) => _avatarFallback(t, name),
                  )
                : _avatarFallback(t, name),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          s.capsuleFrom(name.isNotEmpty ? name : s.partnerFallback),
          style: TextStyle(
            fontSize: 12.5,
            color: t.textMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _avatarFallback(AppTheme t, String name) {
    final letter = name.firstGraphemeUpper('♥');
    return Container(
      color: t.primary.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: t.primary,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}
