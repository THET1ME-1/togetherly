import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/pair_achievement.dart';
import '../services/locale_service.dart';

/// Праздничный полноэкранный оверлей «Достижение получено!»: медаль уровня с
/// эмодзи + конфетти + подпись. Показывается через [show]; при нескольких
/// разблокировках подряд показывает их по очереди (очередь), не наслаивая.
class AchievementUnlockOverlay {
  AchievementUnlockOverlay._();

  static final Queue<PairAchievement> _queue = Queue<PairAchievement>();
  static OverlayEntry? _current;
  static bool _showing = false;

  static void show(BuildContext context, PairAchievement achievement) {
    _queue.add(achievement);
    if (!_showing) _next(context);
  }

  static void _next(BuildContext context) {
    if (_queue.isEmpty) {
      _showing = false;
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      _showing = false;
      return;
    }
    _showing = true;
    final achievement = _queue.removeFirst();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _AchievementUnlockView(
        achievement: achievement,
        onDismiss: () {
          if (_current == entry) _current = null;
          entry.remove();
          _next(context);
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }
}

class _AchievementUnlockView extends StatefulWidget {
  final PairAchievement achievement;
  final VoidCallback onDismiss;

  const _AchievementUnlockView({
    required this.achievement,
    required this.onDismiss,
  });

  @override
  State<_AchievementUnlockView> createState() => _AchievementUnlockViewState();
}

class _AchievementUnlockViewState extends State<_AchievementUnlockView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _confetti;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _confetti = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    // Автозакрытие — оверлей не липнет, если пользователь отвлёкся.
    Future.delayed(const Duration(milliseconds: 4200), _dismiss);
  }

  @override
  void dispose() {
    _confetti.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.achievement;
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: _dismiss,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            // Затемнение
            const ColoredBox(color: Color(0xCC000000), child: SizedBox.expand())
                .animate()
                .fadeIn(duration: 250.ms),
            // Конфетти поверх затемнения
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _confetti,
                  builder: (_, __) => CustomPaint(
                    painter: _ConfettiRain(progress: _confetti.value),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
            // Карточка достижения
            Center(
              child: _card(a).animate().scale(
                    begin: const Offset(0.6, 0.6),
                    end: const Offset(1, 1),
                    duration: 600.ms,
                    curve: Curves.elasticOut,
                  ).fadeIn(duration: 250.ms),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(PairAchievement a) {
    return Container(
      width: 300,
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
      margin: const EdgeInsets.symmetric(horizontal: 32),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1B24),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: a.tierColor.withValues(alpha: 0.55), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: a.tierColor.withValues(alpha: 0.45),
            blurRadius: 40,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            LocaleService.current.achievementUnlocked.toUpperCase(),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: a.tierColor,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          // Медаль
          Container(
            width: 116,
            height: 116,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: a.tierGradient,
              ),
              boxShadow: [
                BoxShadow(
                  color: a.tierColor.withValues(alpha: 0.6),
                  blurRadius: 24,
                  spreadRadius: 1,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(a.emoji, style: const TextStyle(fontSize: 56)),
          )
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .scale(
                begin: const Offset(1, 1),
                end: const Offset(1.06, 1.06),
                duration: 1200.ms,
                curve: Curves.easeInOut,
              ),
          const SizedBox(height: 20),
          Text(
            a.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            a.description,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Конфетти-дождь (сверху вниз) ────────────────────────────────────────────
class _ConfettiRain extends CustomPainter {
  final double progress;

  static final _rand = math.Random(7);
  static final List<_Bit> _bits = List.generate(46, (i) {
    return _Bit(
      x: _rand.nextDouble(),
      size: 4 + _rand.nextDouble() * 7,
      speed: 0.4 + _rand.nextDouble() * 0.9,
      phase: _rand.nextDouble(),
      color: _kColors[i % _kColors.length],
      isCircle: i % 3 != 0,
      rot: _rand.nextDouble() * math.pi * 2,
      sway: 10 + _rand.nextDouble() * 22,
    );
  });

  static const List<Color> _kColors = [
    Color(0xFFFFD700),
    Color(0xFFFF6B6B),
    Color(0xFF4ECDC4),
    Color(0xFF45B7D1),
    Color(0xFFFFA07A),
    Color(0xFFDDA0DD),
    Colors.white,
  ];

  const _ConfettiRain({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in _bits) {
      final t = (progress * b.speed + b.phase) % 1.0;
      final x = b.x * size.width + math.sin(t * math.pi * 2 + b.phase) * b.sway;
      final y = t * (size.height + b.size * 2) - b.size;
      final paint = Paint()
        ..color = b.color.withValues(alpha: 0.85)
        ..style = PaintingStyle.fill;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(b.rot + t * math.pi * 6);
      if (b.isCircle) {
        canvas.drawCircle(Offset.zero, b.size / 2, paint);
      } else {
        canvas.drawRect(
          Rect.fromCenter(
              center: Offset.zero, width: b.size, height: b.size * 0.55),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiRain old) => old.progress != progress;
}

class _Bit {
  final double x;
  final double size;
  final double speed;
  final double phase;
  final Color color;
  final bool isCircle;
  final double rot;
  final double sway;
  const _Bit({
    required this.x,
    required this.size,
    required this.speed,
    required this.phase,
    required this.color,
    required this.isCircle,
    required this.rot,
    required this.sway,
  });
}
