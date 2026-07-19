import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/mood_entry.dart';
import '../services/locale_service.dart';
import '../theme/theme_scope.dart';

/// Max moods per day that count as "full heart".
const int _kMaxMoodsPerDay = 5;

/// Two-column mood preview: one large heart per side that fills with water
/// proportional to the latest mood score for today (1–5).
class MoodHeartsPreview extends StatefulWidget {
  final List<MoodEntry> myEntries;
  final List<MoodEntry> partnerEntries;
  final String myName;
  final String partnerName;
  final Color primaryColor;

  const MoodHeartsPreview({
    super.key,
    required this.myEntries,
    required this.partnerEntries,
    required this.myName,
    required this.partnerName,
    required this.primaryColor,
  });

  @override
  State<MoodHeartsPreview> createState() => _MoodHeartsPreviewState();
}

class _MoodHeartsPreviewState extends State<MoodHeartsPreview>
    with TickerProviderStateMixin {
  late final AnimationController _myCtrl;
  late final AnimationController _partnerCtrl;

  @override
  void initState() {
    super.initState();
    _myCtrl = _makeController();
    _partnerCtrl = _makeController();
    _myCtrl.value = _fillLevel(widget.myEntries);
    _partnerCtrl.value = _fillLevel(widget.partnerEntries);
  }

  AnimationController _makeController() => AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  int _score(List<MoodEntry> entries) {
    if (entries.isEmpty) return 0;
    return entries.first.score.clamp(0, _kMaxMoodsPerDay);
  }

  double _fillLevel(List<MoodEntry> entries) =>
      (_score(entries) / _kMaxMoodsPerDay).toDouble();

  @override
  void didUpdateWidget(MoodHeartsPreview old) {
    super.didUpdateWidget(old);
    if (_score(old.myEntries) != _score(widget.myEntries)) {
      _myCtrl.animateTo(
        _fillLevel(widget.myEntries),
        curve: Curves.easeOutCubic,
      );
    }
    if (_score(old.partnerEntries) != _score(widget.partnerEntries)) {
      _partnerCtrl.animateTo(
        _fillLevel(widget.partnerEntries),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _myCtrl.dispose();
    _partnerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            widget.primaryColor.withValues(alpha: 0.04),
            widget.primaryColor.withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: widget.primaryColor.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _HeartColumn(
              name: widget.myName,
              entries: widget.myEntries,
              controller: _myCtrl,
              isLeft: true,
            ),
          ),
          Container(
            width: 1,
            height: 100,
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  t.divider.withValues(alpha: 0),
                  t.divider.withValues(alpha: 0.25),
                  t.divider.withValues(alpha: 0),
                ],
              ),
            ),
          ),
          Expanded(
            child: _HeartColumn(
              name: widget.partnerName,
              entries: widget.partnerEntries,
              controller: _partnerCtrl,
              isLeft: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeartColumn extends StatelessWidget {
  final String name;
  final List<MoodEntry> entries;
  final AnimationController controller;
  final bool isLeft;

  const _HeartColumn({
    required this.name,
    required this.entries,
    required this.controller,
    required this.isLeft,
  });

  Color _waterColor() {
    if (entries.isEmpty) return const Color(0xFFD1D5DB);
    return entries.first.color;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    final lastEntry = entries.isNotEmpty ? entries.first : null;
    final alignment = isLeft
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.end;
    final score = entries.isNotEmpty
        ? entries.first.score.clamp(0, _kMaxMoodsPerDay)
        : 0;
    final waterColor = _waterColor();
    final ratingText = entries.isNotEmpty
        ? LocaleService.current.moodScoreLabel(score, _kMaxMoodsPerDay)
        : '';

    return Column(
      crossAxisAlignment: alignment,
      children: [
        Text(
          name,
          style: GoogleFonts.rubik(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: t.textSecondary,
            letterSpacing: 0.3,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 10),
        AnimatedBuilder(
          animation: controller,
          builder: (_, _) => WaterHeart(
            size: 70,
            fillLevel: Curves.easeOutCubic.transform(controller.value),
            waterColor: waterColor,
            borderColor: entries.isNotEmpty
                ? waterColor.withValues(alpha: 0.5)
                : Colors.grey.shade300,
          ),
        ),
        const SizedBox(height: 6),
        if (ratingText.isNotEmpty) ...[
          Text(
            ratingText,
            style: GoogleFonts.rubik(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: waterColor,
            ),
          ),
          const SizedBox(height: 2),
        ],
        Text(
          lastEntry?.localizedLabel ?? LocaleService.current.noMoodRecorded,
          style: GoogleFonts.rubik(
            fontSize: 11.5,
            fontWeight: lastEntry != null ? FontWeight.w600 : FontWeight.w400,
            color: lastEntry != null ? lastEntry.color : t.textMuted,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Single heart that fills with water proportional to [fillLevel] (0.0–1.0).
class WaterHeart extends StatelessWidget {
  final double size;
  final double fillLevel;
  final Color waterColor;
  final Color borderColor;

  const WaterHeart({
    super.key,
    this.size = 70,
    required this.fillLevel,
    required this.waterColor,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _WaterHeartPainter(
        fillLevel: fillLevel,
        waterColor: waterColor,
        borderColor: borderColor,
      ),
    );
  }
}

class _WaterHeartPainter extends CustomPainter {
  final double fillLevel;
  final Color waterColor;
  final Color borderColor;

  const _WaterHeartPainter({
    required this.fillLevel,
    required this.waterColor,
    required this.borderColor,
  });

  static Path _heartPath(Size size) {
    final w = size.width;
    final h = size.height;
    return Path()
      ..moveTo(w * 0.5, h * 0.27)
      ..cubicTo(w * 0.5, h * 0.245, w * 0.45, h * 0.14, w * 0.25, h * 0.14)
      ..cubicTo(0, h * 0.14, 0, h * 0.46, 0, h * 0.46)
      ..cubicTo(0, h * 0.71, w * 0.25, h * 0.84, w * 0.5, h)
      ..cubicTo(w * 0.75, h * 0.84, w, h * 0.71, w, h * 0.46)
      ..cubicTo(w, h * 0.46, w, h * 0.14, w * 0.75, h * 0.14)
      ..cubicTo(w * 0.6, h * 0.14, w * 0.5, h * 0.245, w * 0.5, h * 0.27)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final heart = _heartPath(size);

    // Empty heart background
    canvas.drawPath(
      heart,
      Paint()
        ..color = borderColor.withValues(alpha: 0.08)
        ..style = PaintingStyle.fill,
    );

    if (fillLevel > 0.005) {
      canvas
        ..save()
        ..clipPath(heart);

      final waterTop = size.height * (1 - fillLevel);
      final waveAmp = size.height * 0.03;

      // Wave surface
      final wavePath = Path()..moveTo(-1, waterTop);
      const steps = 24;
      for (int i = 0; i <= steps; i++) {
        final x = size.width * i / steps;
        final y = waterTop + sin(x / size.width * 2 * pi - pi * 0.5) * waveAmp;
        wavePath.lineTo(x, y);
      }
      wavePath
        ..lineTo(size.width + 1, size.height + 1)
        ..lineTo(-1, size.height + 1)
        ..close();

      final fillRect = Rect.fromLTWH(
        0,
        waterTop,
        size.width,
        size.height - waterTop,
      );
      canvas.drawPath(
        wavePath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              waterColor.withValues(alpha: 0.68),
              waterColor.withValues(alpha: 0.90),
            ],
          ).createShader(fillRect),
      );

      // Highlight bubble
      if (fillLevel > 0.15) {
        canvas.drawCircle(
          Offset(size.width * 0.32, waterTop + size.height * 0.12),
          size.width * 0.06,
          Paint()..color = Colors.white.withValues(alpha: 0.30),
        );
      }

      canvas.restore();
    }

    // Heart outline
    canvas.drawPath(
      heart,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_WaterHeartPainter old) =>
      old.fillLevel != fillLevel ||
      old.waterColor != waterColor ||
      old.borderColor != borderColor;
}
