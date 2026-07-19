import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

/// Баннер-праздник с анимированным конфетти.
///
/// Показывается на главном экране когда сегодня годовщина или день рождения.
class CelebrationBanner extends StatefulWidget {
  final String message;
  final String emoji;
  final Color color;
  final VoidCallback? onTap;

  const CelebrationBanner({
    super.key,
    required this.message,
    required this.emoji,
    required this.color,
    this.onTap,
  });

  @override
  State<CelebrationBanner> createState() => _CelebrationBannerState();
}

class _CelebrationBannerState extends State<CelebrationBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        height: 80,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              widget.color,
              widget.color.withValues(alpha: 0.75),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.4),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.antiAlias,
          children: [
            // ── Конфетти-частицы ──
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => CustomPaint(
                size: Size.infinite,
                painter: _ConfettiPainter(
                  progress: _ctrl.value,
                  color: widget.color,
                ),
              ),
            ),
            // ── Контент ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    widget.emoji,
                    style: const TextStyle(fontSize: 36),
                  )
                      .animate(onPlay: (c) => c.repeat())
                      .scale(
                        begin: const Offset(0.85, 0.85),
                        end: const Offset(1.15, 1.15),
                        duration: 800.ms,
                        curve: Curves.easeInOut,
                      )
                      .then()
                      .scale(
                        begin: const Offset(1.15, 1.15),
                        end: const Offset(0.85, 0.85),
                        duration: 800.ms,
                        curve: Curves.easeInOut,
                      ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                    ),
                  ),
                  // Стрелку-аффорданс показываем только когда баннер реально
                  // кликабелен (задан onTap), иначе он вводит в заблуждение.
                  if (widget.onTap != null)
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.white70,
                      size: 22,
                    ),
                ],
              ),
            ),
          ],
        ),
      )
          .animate()
          .slideY(
            begin: -0.3,
            end: 0,
            duration: 500.ms,
            curve: Curves.easeOutBack,
          )
          .fadeIn(duration: 400.ms),
    );
  }
}

// ── Конфетти-художник ──────────────────────────────────────────────────────-

class _ConfettiPainter extends CustomPainter {
  final double progress;
  final Color color;

  static final _rand = math.Random(42);

  // Статические позиции/параметры частиц (вычислены один раз).
  static final List<_Particle> _particles = List.generate(30, (i) {
    return _Particle(
      x: _rand.nextDouble(),
      baseY: _rand.nextDouble(),
      size: 3 + _rand.nextDouble() * 5,
      speed: 0.2 + _rand.nextDouble() * 0.8,
      phase: _rand.nextDouble(),
      color: _kColors[i % _kColors.length],
      isCircle: i % 3 != 0,
      rotation: _rand.nextDouble() * math.pi * 2,
    );
  });

  static const List<Color> _kColors = [
    Color(0xFFFFD700),
    Color(0xFFFF6B6B),
    Color(0xFF4ECDC4),
    Color(0xFF45B7D1),
    Color(0xFFFFA07A),
    Color(0xFF98D8C8),
    Color(0xFFDDA0DD),
    Colors.white,
  ];

  const _ConfettiPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in _particles) {
      final t = (progress * p.speed + p.phase) % 1.0;
      final x = p.x * size.width + math.sin(t * math.pi * 2 + p.phase) * 12;
      // Частицы движутся снизу вверх и появляются с разными фазами.
      final y = size.height - (t * (size.height + p.size * 2)) + p.size;
      if (y < -p.size || y > size.height + p.size) continue;

      final paint = Paint()
        ..color = p.color.withValues(alpha: 0.7 + 0.3 * (1 - t))
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.rotation + t * math.pi * 4);

      if (p.isCircle) {
        canvas.drawCircle(Offset.zero, p.size / 2, paint);
      } else {
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset.zero,
            width: p.size,
            height: p.size * 0.6,
          ),
          paint,
        );
      }

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.progress != progress;
}

class _Particle {
  final double x;
  final double baseY;
  final double size;
  final double speed;
  final double phase;
  final Color color;
  final bool isCircle;
  final double rotation;

  const _Particle({
    required this.x,
    required this.baseY,
    required this.size,
    required this.speed,
    required this.phase,
    required this.color,
    required this.isCircle,
    required this.rotation,
  });
}
