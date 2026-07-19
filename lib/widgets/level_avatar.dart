import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/level_service.dart';

/// Аватар с кольцом-бордером в цвете ранга, дугой прогресса XP и бейджем уровня.
/// Слушает [LevelService] — обновляется при росте опыта. Позже кольцо заменим
/// на рисованную рамку ранга ([Rank.frameAsset]), API виджета не изменится.
class LevelAvatar extends StatelessWidget {
  /// Содержимое аватарки (Image/StorageImage и т.п.).
  final Widget child;

  /// Диаметр самой аватарки.
  final double size;

  /// Толщина кольца.
  final double ring;

  /// Показывать бейдж с номером уровня.
  final bool showBadge;

  const LevelAvatar({
    super.key,
    required this.child,
    this.size = 56,
    this.ring = 3,
    this.showBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: LevelService.instance,
      builder: (context, _) {
        final p = LevelService.instance.progress;
        final color = p.rank.color;
        final total = size + ring * 4;
        return SizedBox(
          width: total,
          height: total,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: Size(total, total),
                painter: _RingPainter(
                  progress: p.progress,
                  color: color,
                  stroke: ring,
                ),
              ),
              ClipOval(
                child: SizedBox(width: size, height: size, child: child),
              ),
              if (showBadge)
                Positioned(
                  bottom: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Text(
                      '${p.level}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double stroke;

  _RingPainter({
    required this.progress,
    required this.color,
    required this.stroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.width - stroke) / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color.withValues(alpha: 0.18);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawCircle(center, radius, track);
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color || old.stroke != stroke;
}
