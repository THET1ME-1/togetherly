import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/locale_service.dart';
import '../theme/app_theme.dart';

/// Data for a single petal segment.
class _PetalData {
  final String label;
  final int value;
  final int maxValue;
  final double exactValue;

  const _PetalData({
    required this.label,
    required this.value,
    required this.maxValue,
    required this.exactValue,
  });

  /// Normalised 0..1 brightness factor based on exact continuous value.
  double get factor =>
      maxValue > 0 ? (exactValue / maxValue).clamp(0.0, 1.0) : 0.0;
}

/// A donut-like diagram with 6 rounded petal segments arranged in a ring.
///
/// Each segment represents: Years, Months, Days, Hours, Minutes, Seconds.
/// The ring can be rotated by finger drag (with physics-based inertia).
/// Segment brightness depends on their value; size is identical for all.
class PetalTimerDial extends StatefulWidget {
  /// Application theme for colours
  final AppTheme theme;

  /// Start date for computing elapsed time.
  final DateTime startDate;

  /// Whether the timer counts down instead of up.
  final bool isCountdown;

  /// Called when user taps on Days or Months petal. Passes the label.
  final ValueChanged<String>? onPetalTap;

  const PetalTimerDial({
    super.key,
    required this.theme,
    required this.startDate,
    this.isCountdown = false,
    this.onPetalTap,
  });

  @override
  State<PetalTimerDial> createState() => _PetalTimerDialState();
}

class _PetalTimerDialState extends State<PetalTimerDial>
    with TickerProviderStateMixin {
  double _rotationAngle = 0.0;
  double _prevAngle = 0.0;

  late AnimationController _flingCtrl;
  late Ticker _chaseTicker;
  List<double> _displayFactors = List.filled(6, 0.0);
  List<double> _presenceFactors = List.filled(6, 1.0);
  List<_PetalData> _currentPetals = [];
  final Set<int> _hiddenIndices = {};

  @override
  void initState() {
    super.initState();
    _flingCtrl = AnimationController.unbounded(vsync: this);
    _flingCtrl.addListener(_onFlingTick);

    // Инициализируем текущие значения лепестков и display factors
    _currentPetals = _computePetals();
    _displayFactors = _currentPetals.map((p) => p.factor).toList();

    // Запускаем ticker для плавной анимации
    _chaseTicker = createTicker(_onChaseTick)..start();
  }

  void _onChaseTick(Duration elapsed) {
    _currentPetals = _computePetals();
    bool changed = false;
    for (int i = 0; i < 6; i++) {
      final target = _currentPetals[i].factor;
      final diff = target - _displayFactors[i];
      if (diff.abs() > 0.0005) {
        _displayFactors[i] += diff * 0.15;
        changed = true;
      } else if (_displayFactors[i] != target) {
        _displayFactors[i] = target;
        changed = true;
      }

      // Анимируем присутствие (ширину) лепестка
      final targetPresence = _hiddenIndices.contains(i) ? 0.0 : 1.0;
      final pDiff = targetPresence - _presenceFactors[i];
      if (pDiff.abs() > 0.001) {
        _presenceFactors[i] += pDiff * 0.2;
        changed = true;
      } else if (_presenceFactors[i] != targetPresence) {
        _presenceFactors[i] = targetPresence;
        changed = true;
      }
    }
    if (changed && mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _flingCtrl.dispose();
    _chaseTicker.dispose();
    super.dispose();
  }

  void _onFlingTick() {
    setState(() {
      _rotationAngle = _flingCtrl.value;
    });
  }

  Offset _center = Offset.zero;

  void _onPanStart(DragStartDetails d) {
    _flingCtrl.stop();
    final box = context.findRenderObject() as RenderBox;
    _center = box.size.center(Offset.zero);
    _prevAngle = _angleOf(d.localPosition);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final newAngle = _angleOf(d.localPosition);
    var delta = newAngle - _prevAngle;
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta < -math.pi) delta += 2 * math.pi;
    setState(() {
      _rotationAngle += delta;
    });
    _prevAngle = newAngle;
  }

  void _onPanEnd(DragEndDetails d) {
    final vx = d.velocity.pixelsPerSecond.dx;
    final vy = d.velocity.pixelsPerSecond.dy;
    final radius = _center.dx.abs().clamp(60.0, 200.0);
    var angularVelocity = (vx.abs() + vy.abs()) / radius;
    final sign = _tangentSign(d.velocity.pixelsPerSecond);
    angularVelocity *= sign;

    _flingCtrl.value = _rotationAngle;
    final simulation = FrictionSimulation(
      0.0008,
      _rotationAngle,
      angularVelocity,
    );
    _flingCtrl.animateWith(simulation);
  }

  double _angleOf(Offset pos) {
    return math.atan2(pos.dy - _center.dy, pos.dx - _center.dx);
  }

  double _tangentSign(Offset velocity) {
    final cross = -velocity.dx * 0.5 + velocity.dy * 0.5;
    return cross >= 0 ? 1.0 : -1.0;
  }

  List<_PetalData> _computePetals() {
    final now = DateTime.now();
    final DateTime from, to;
    if (widget.isCountdown) {
      from = now;
      to = widget.startDate;
    } else {
      from = widget.startDate;
      to = now;
    }

    if (!to.isAfter(from)) {
      return _zeroPetals();
    }

    // Calendar-aware years / months / days
    int years  = to.year  - from.year;
    int months = to.month - from.month;
    int days   = to.day   - from.day;

    if (days < 0) {
      months--;
      // day 0 = last day of the month before `to`
      days += DateTime(to.year, to.month, 0).day;
    }
    if (months < 0) {
      years--;
      months += 12;
    }

    // Sub-day components derived from total elapsed ms
    final diffMs = to.difference(from).inMilliseconds;
    final hI   = (diffMs ~/ 3600000) % 24;
    final minI = (diffMs ~/ 60000)   % 60;
    final sI   = (diffMs ~/ 1000)    % 60;

    return [
      _PetalData(
        label: LocaleService.current.yearsLabel,
        value: years,
        maxValue: 100,
        exactValue: years  + months / 12.0,
      ),
      _PetalData(
        label: LocaleService.current.monthsShortLabel,
        value: months,
        maxValue: 12,
        exactValue: months + days  / 30.0,
      ),
      _PetalData(
        label: LocaleService.current.daysShortLabel,
        value: days,
        maxValue: 30,
        exactValue: days   + hI   / 24.0,
      ),
      _PetalData(
        label: LocaleService.current.hoursLabel,
        value: hI,
        maxValue: 24,
        exactValue: hI    + minI  / 60.0,
      ),
      _PetalData(
        label: LocaleService.current.minLabel,
        value: minI,
        maxValue: 60,
        exactValue: minI  + sI   / 60.0,
      ),
      _PetalData(
        label: LocaleService.current.secLabel,
        value: sI,
        maxValue: 60,
        exactValue: sI.toDouble(),
      ),
    ];
  }

  List<_PetalData> _zeroPetals() => [
        _PetalData(label: LocaleService.current.yearsLabel,       value: 0, maxValue: 100, exactValue: 0),
        _PetalData(label: LocaleService.current.monthsShortLabel, value: 0, maxValue: 12,  exactValue: 0),
        _PetalData(label: LocaleService.current.daysShortLabel,   value: 0, maxValue: 30,  exactValue: 0),
        _PetalData(label: LocaleService.current.hoursLabel,       value: 0, maxValue: 24,  exactValue: 0),
        _PetalData(label: LocaleService.current.minLabel,         value: 0, maxValue: 60,  exactValue: 0),
        _PetalData(label: LocaleService.current.secLabel,         value: 0, maxValue: 60,  exactValue: 0),
      ];

  /// Which petal index is at [localPos]? Returns -1 if outside the ring.
  int _petalIndexAt(Offset localPos) {
    final box = context.findRenderObject() as RenderBox;
    final sz = box.size;
    final center = sz.center(Offset.zero);
    final off = localPos - center;
    final dist = off.distance;
    final outerR = math.min(center.dx, center.dy) - 2;
    final innerR = outerR * 0.15;
    if (dist < innerR || dist > outerR) return -1;

    double a = math.atan2(off.dy, off.dx) - _rotationAngle + math.pi / 2;
    while (a < 0) a += 2 * math.pi;
    while (a >= 2 * math.pi) a -= 2 * math.pi;
    final tp = _presenceFactors.reduce((x, y) => x + y);
    if (tp < 0.001) return -1;
    double norm = a * (tp / (2 * math.pi));
    double run = 0;
    for (int i = 0; i < 6; i++) {
      run += _presenceFactors[i];
      if (norm < run) return i;
    }
    return -1;
  }

  void _handleInteraction(Offset localPos, {bool isLongPress = false}) {
    final box = context.findRenderObject() as RenderBox;
    final size = box.size;
    final center = size.center(Offset.zero);
    final offset = localPos - center;
    final distance = offset.distance;

    final outerR = math.min(center.dx, center.dy) - 2;
    final innerR = outerR * 0.25;

    if (distance < innerR) {
      if (_hiddenIndices.isNotEmpty) {
        HapticFeedback.selectionClick();
        setState(() => _hiddenIndices.clear());
      }
      return;
    }

    // Regular tap — detect Days / Months petal
    if (!isLongPress) {
      final idx = _petalIndexAt(localPos);
      if (idx >= 0 && _presenceFactors[idx] > 0.5) {
        final label = _currentPetals[idx].label;
        if (label == LocaleService.current.daysShortLabel ||
            label == LocaleService.current.monthsShortLabel) {
          HapticFeedback.lightImpact();
          widget.onPetalTap?.call(label);
        }
      }
      return;
    }

    if (distance > outerR || distance < outerR * 0.15) return;

    // Determine angle
    double angle = math.atan2(offset.dy, offset.dx);
    angle -= _rotationAngle;
    angle += math.pi / 2;

    while (angle < 0) angle += 2 * math.pi;
    while (angle >= 2 * math.pi) angle -= 2 * math.pi;

    final totalPres = _presenceFactors.reduce((a, b) => a + b);
    if (totalPres < 0.001) return;

    double normalizedTapped = angle * (totalPres / (2 * math.pi));
    double runningPres = 0;
    int tappedIdx = -1;
    for (int i = 0; i < 6; i++) {
      runningPres += _presenceFactors[i];
      if (normalizedTapped < runningPres) {
        tappedIdx = i;
        break;
      }
    }

    if (tappedIdx != -1) {
      // Запрещаем удалять последний оставшийся лепесток (всего 6)
      if (_hiddenIndices.length >= 5) return;

      HapticFeedback.mediumImpact();
      setState(() {
        _hiddenIndices.add(tappedIdx);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    _currentPetals = _computePetals();
    final petals = _currentPetals;
    final factors = _displayFactors;
    final presence = _presenceFactors;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Find the maximum available square size
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        // Base scale factor. 280 was the original hardcoded size.
        final scale = size / 280.0;

        return GestureDetector(
          onTapUp: (details) => _handleInteraction(details.localPosition),
          onLongPressStart: (details) =>
              _handleInteraction(details.localPosition, isLongPress: true),
          onScaleStart: (details) => _onPanStart(
            DragStartDetails(
              localPosition: details.localFocalPoint,
              globalPosition: details.focalPoint,
            ),
          ),
          onScaleUpdate: (details) => _onPanUpdate(
            DragUpdateDetails(
              localPosition: details.localFocalPoint,
              globalPosition: details.focalPoint,
              delta: details.focalPointDelta,
            ),
          ),
          onScaleEnd: (details) =>
              _onPanEnd(DragEndDetails(velocity: details.velocity)),
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _PetalDialPainter(
                petals: petals,
                displayFactors: factors,
                presenceFactors: presence,
                rotationAngle: _rotationAngle,
                theme: widget.theme,
                scale: scale,
                totalPresence: presence.reduce((a, b) => a + b),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PetalDialPainter extends CustomPainter {
  final List<_PetalData> petals;
  final List<double> displayFactors;
  final List<double> presenceFactors;
  final double rotationAngle;
  final AppTheme theme;
  final double scale;
  final double totalPresence;

  _PetalDialPainter({
    required this.petals,
    required this.displayFactors,
    required this.presenceFactors,
    required this.rotationAngle,
    required this.theme,
    required this.scale,
    required this.totalPresence,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Outer boundary of the entire widget
    final outerR = math.min(cx, cy) - 2;
    // Tiny hole inside, matching the photo (~15%)
    final innerR = outerR * 0.15;

    // Corner radius of EVERY edge
    final cr = 4.0 * scale;

    // Width of the parallel gap lines separating the petals
    final gapWidth = 6.0 * scale;

    // We shrink logical parameters to leave room for the `cr` thick round stroke.
    // When the fill+stroke is combined, the visual gap and corner radii are exactly as requested.
    final rigidInner = innerR + cr;
    final rigidOuter = outerR - cr;
    final h = (gapWidth / 2) + cr;

    if (totalPresence < 0.001) return;

    canvas.save();
    canvas.translate(cx, cy);

    // Draw restore hint in the center if any petals are hidden
    if (totalPresence < 5.9) {
      final restoreAlpha = (6.0 - totalPresence).clamp(0.0, 1.0);
      final restorePaint = Paint()
        ..color = theme.fillColor.withValues(alpha: 0.3 * restoreAlpha)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset.zero, innerR * 0.8, restorePaint);

      _drawText(
        canvas,
        text: '↺',
        x: 0,
        y: 0,
        fontSize: 16 * scale,
        fontWeight: FontWeight.bold,
        color: Colors.white.withValues(alpha: restoreAlpha),
        counterRotation: 0,
      );
    }

    canvas.rotate(rotationAngle);

    double currentStartAngle = -math.pi / 2;

    for (int i = 0; i < petals.length; i++) {
      final pres = presenceFactors[i];
      if (pres < 0.01) continue;

      final petal = petals[i];
      final sweep = (2 * math.pi / totalPresence) * pres;
      final sweepHalf = sweep / 2;

      // Rotate canvas per-segment so the petal is constructed along the local X-axis (angle 0).
      final segAngle = currentStartAngle + sweepHalf;

      canvas.save();
      canvas.rotate(segAngle);

      // ── 1. Draw Background Track (the placeholder for max value) ──
      // Фон лепестков берётся из новой настройки темы
      final bgPath = _buildParallelRigidSector(
        rigidOuter,
        rigidInner,
        h,
        sweepHalf,
      );

      // Квадратичное (и даже кубическое) затухание прозрачности для лепестка,
      // чтобы он исчезал быстрее, чем текст
      final petalAlpha = (pres * pres * pres).clamp(0.0, 1.0);
      final textAlpha = pres.clamp(0.0, 1.0);

      final bgPaintFill = Paint()
        ..color = theme.timerDialBackground.withValues(alpha: petalAlpha)
        ..style = PaintingStyle.fill;

      final bgPaintStroke = Paint()
        ..color = theme.timerDialBackground.withValues(alpha: petalAlpha)
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = cr * 2;

      canvas.drawPath(bgPath, bgPaintFill);
      canvas.drawPath(bgPath, bgPaintStroke);

      // ── 2. Draw Bright Value Segment ──
      final factor = displayFactors[i].clamp(0.0, 1.0);

      if (factor > 0.01) {
        final currentOuterR = innerR + (outerR - innerR) * factor;
        final rigidFgOuter = math.max(rigidInner + 0.1, currentOuterR - cr);

        final fgPath = _buildParallelRigidSector(
          rigidFgOuter,
          rigidInner,
          h,
          sweepHalf,
        );

        // Цвет заполнения с учетом прозрачности при анимации
        final fgColor = theme.fillColor.withValues(alpha: petalAlpha);

        final fgPaintFill = Paint()
          ..color = fgColor
          ..style = PaintingStyle.fill;

        final fgPaintStroke = Paint()
          ..color = fgColor
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = cr * 2;

        canvas.drawPath(fgPath, fgPaintFill);
        canvas.drawPath(fgPath, fgPaintStroke);
      }

      final textR = (innerR + outerR) / 2;
      final txColor = Colors.white.withValues(alpha: 0.95 * textAlpha);

      // Масштабируем размер текста пропорционально, но нелинейно (корень), чтобы не переборщить
      // При 1 лепестке рост будет около 2.45x вместо 6x
      final textScale = math.sqrt(6.0 / totalPresence).clamp(1.0, 2.5);

      canvas.save();
      canvas.translate(textR, 0);
      canvas.rotate(-(rotationAngle + segAngle));

      _drawText(
        canvas,
        text: '${petal.value}',
        x: 0,
        y: -9 * scale * textScale,
        fontSize: 18 * scale * textScale,
        fontWeight: FontWeight.w800,
        color: txColor,
        counterRotation: 0,
      );

      _drawText(
        canvas,
        text: petal.label,
        x: 0,
        y: 11 * scale * textScale,
        fontSize: 9 * scale * textScale,
        fontWeight: FontWeight.w600,
        color: txColor.withValues(alpha: 0.65),
        counterRotation: 0,
      );

      canvas.restore();

      canvas.restore();

      currentStartAngle += sweep;
    }

    canvas.restore();
  }

  Path _buildParallelRigidSector(
    double outer,
    double inner,
    double h,
    double sweepHalf,
  ) {
    final path = Path();

    // Bounds for segments based on total count.
    final topA = sweepHalf;
    final botA = -sweepHalf;

    if (outer <= h || outer <= inner) return path;

    // Outer intersections
    final tOut = math.sqrt(outer * outer - h * h);
    final pOutTop = Offset(
      tOut * math.cos(topA) + h * math.sin(topA),
      tOut * math.sin(topA) - h * math.cos(topA),
    );
    final pOutBot = Offset(
      tOut * math.cos(botA) - h * math.sin(botA),
      tOut * math.sin(botA) + h * math.cos(botA),
    );

    double tIn = 0;
    Offset pInTop = Offset.zero;
    Offset pInBot = Offset.zero;

    if (inner > h) {
      tIn = math.sqrt(inner * inner - h * h);
      pInTop = Offset(
        tIn * math.cos(topA) + h * math.sin(topA),
        tIn * math.sin(topA) - h * math.cos(topA),
      );
      pInBot = Offset(
        tIn * math.cos(botA) - h * math.sin(botA),
        tIn * math.sin(botA) + h * math.cos(botA),
      );
    } else {
      final xIntersect = h / math.sin(sweepHalf);
      pInTop = Offset(xIntersect, 0);
      pInBot = Offset(xIntersect, 0);
    }

    final aOutTop = math.atan2(pOutTop.dy, pOutTop.dx);
    final aOutBot = math.atan2(pOutBot.dy, pOutBot.dx);

    path.moveTo(pInBot.dx, pInBot.dy);
    path.lineTo(pOutBot.dx, pOutBot.dy);

    if (aOutTop > aOutBot) {
      path.arcTo(
        Rect.fromCircle(center: Offset.zero, radius: outer),
        aOutBot,
        aOutTop - aOutBot,
        false,
      );
    }

    path.lineTo(pInTop.dx, pInTop.dy);

    if (inner > h) {
      final aInTop = math.atan2(pInTop.dy, pInTop.dx);
      final aInBot = math.atan2(pInBot.dy, pInBot.dx);
      path.arcTo(
        Rect.fromCircle(center: Offset.zero, radius: inner),
        aInTop,
        aInBot - aInTop,
        false,
      );
    } else {
      path.lineTo(pInBot.dx, pInBot.dy);
    }

    path.close();
    return path;
  }

  void _drawText(
    Canvas canvas, {
    required String text,
    required double x,
    required double y,
    required double fontSize,
    required FontWeight fontWeight,
    required Color color,
    required double counterRotation,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: GoogleFonts.rubik(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();

    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(counterRotation);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PetalDialPainter old) =>
      old.rotationAngle != rotationAngle ||
      old.petals != petals ||
      old.displayFactors != displayFactors ||
      old.presenceFactors != presenceFactors ||
      old.scale != scale ||
      old.totalPresence != totalPresence;
}
