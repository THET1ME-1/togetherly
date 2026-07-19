import 'dart:math' as math;
import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  True organic blob — liquid / ink-drop / gel shape.
//
//  NOT a rounded rectangle. The perimeter is generated from polar coordinates:
//    r(θ, t) = base + Σ aᵢ · sin(nᵢ·θ + φᵢ(t))
//
//  Multiple sine harmonics with incommensurate frequencies create a
//  continuously morphing, never-repeating, asymmetric amoeba shape.
//
//  Three animation channels:
//    _morphCtrl  (6 s)   — phase scroll that continuously changes the outline
//    _rotCtrl    (10 s)  — slow rotation of the whole blob
//    _breathCtrl (5 s)   — gentle scale breathing 0.96 → 1.04
//
//  60 polar sample points → Catmull-Rom spline = perfectly smooth outline.
//  Content is NEVER blob-clipped (stays readable inside ClipRRect).
// ─────────────────────────────────────────────────────────────────────────────

const _kPoints = 60;

// Sine harmonics: (spatial frequency, amplitude, temporal speed).
// Low freqs = large gentle lobes. Higher freqs = fine organic detail.
// Incommensurate speeds ensure the pattern never exactly repeats.
const _kWaves = [
  (n: 2, amp: 0.025, speed: 1.00), // gentle 2-lobe asymmetry
  (n: 3, amp: 0.018, speed: 0.73), // subtle three-lobe wobble
  (n: 4, amp: 0.010, speed: 1.37), // fine four-lobe detail
  (n: 5, amp: 0.006, speed: 1.83), // micro texture
];

// ─────────────────────────────────────────────────────────────────────────────
//  BlobClipper
// ─────────────────────────────────────────────────────────────────────────────
class BlobClipper extends CustomClipper<Path> {
  /// 0→1 continuously cycling morph phase
  final double morphTime;

  /// Rotation angle in radians (0→2π)
  final double rotation;

  /// Scale multiplier for breathing (e.g. 0.96…1.04)
  final double scale;

  /// 0.0 = full blob, 1.0 = rounded rect (for expand transition)
  final double expandProgress;

  const BlobClipper({
    required this.morphTime,
    required this.rotation,
    required this.scale,
    required this.expandProgress,
  });

  @override
  Path getClip(Size size) {
    final ep = expandProgress.clamp(0.0, 1.0);

    // Fully expanded → plain rounded rect
    if (ep >= 0.995) {
      return Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          const Radius.circular(32),
        ),
      );
    }

    final cx = size.width / 2;
    final cy = size.height / 2;

    // Use the SMALLER half-dimension as base radius for both axes.
    // This keeps the blob circular so rotation never pushes lobes
    // into the shorter dimension causing flat clipping.
    final baseR = math.min(cx, cy) * scale * 0.93;
    final rx = baseR;
    final ry = baseR;

    final blobPts = <Offset>[];
    final rrPts = <Offset>[];

    for (int i = 0; i < _kPoints; i++) {
      final theta = 2 * math.pi * i / _kPoints;
      final rotatedTheta = theta + rotation;

      // Sum all sine harmonics for this angle.
      // Use sin(2π·morphTime) so morphTime 0→1 maps to a full sin cycle
      // — no jump when the controller resets or reverses.
      double distortion = 0;
      for (final w in _kWaves) {
        distortion +=
            w.amp *
            math.sin(
              w.n * rotatedTheta +
                  w.speed * 2 * math.pi * math.sin(2 * math.pi * morphTime),
            );
      }

      final r = 1.0 + distortion;
      blobPts.add(
        Offset(cx + rx * r * math.cos(theta), cy + ry * r * math.sin(theta)),
      );

      // Corresponding rounded-rect point for lerping on expand
      if (ep > 0) {
        final cosT = math.cos(theta);
        final sinT = math.sin(theta);
        // Ray-cast to axis-aligned rounded-rect
        const cr = 32.0;
        final hw = size.width / 2;
        final hh = size.height / 2;
        final tx = cosT.abs() > 1e-9 ? (hw - cr) / cosT.abs() : double.infinity;
        final ty = sinT.abs() > 1e-9 ? (hh - cr) / sinT.abs() : double.infinity;
        final tSide = math.min(tx.abs(), ty.abs());
        rrPts.add(
          Offset(
            (cx + cosT * tSide).clamp(cr, size.width - cr),
            (cy + sinT * tSide).clamp(cr, size.height - cr),
          ),
        );
      }
    }

    // Lerp blob → rounded-rect as expand progresses
    final List<Offset> pts;
    if (ep > 0) {
      pts = List.generate(
        _kPoints,
        (i) => Offset.lerp(blobPts[i], rrPts[i], ep)!,
      );
    } else {
      pts = blobPts;
    }

    return _catmullRom(pts);
  }

  /// Closed Catmull-Rom spline through all points → butter-smooth outline.
  static Path _catmullRom(List<Offset> pts) {
    final n = pts.length;
    final path = Path();

    for (int i = 0; i < n; i++) {
      final p0 = pts[(i - 1 + n) % n];
      final p1 = pts[i];
      final p2 = pts[(i + 1) % n];
      final p3 = pts[(i + 2) % n];

      final cp1 = Offset(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
      );
      final cp2 = Offset(
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
      );

      if (i == 0) path.moveTo(p1.dx, p1.dy);
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(BlobClipper old) =>
      old.morphTime != morphTime ||
      old.rotation != rotation ||
      old.scale != scale ||
      old.expandProgress != expandProgress;
}

// ─────────────────────────────────────────────────────────────────────────────
//  AnimatedBlobClip
//
//  Three independent animation channels for organic liquid motion:
//    _morphCtrl  — 6 s, repeat, linear → continuous shape morphing
//    _rotCtrl    — 10 s, repeat, linear → 1 full rotation every ~10 s
//    _breathCtrl — 5 s, repeat+reverse, ease-in-out → gentle scale pulse
//
//  Background: clipped by the blob path.
//  Content:    always ClipRRect(32) — never deformed.
// ─────────────────────────────────────────────────────────────────────────────
class AnimatedBlobClip extends StatefulWidget {
  final Widget background;
  final Widget child;
  final bool enabled;
  final Animation<double> expandAnim;

  const AnimatedBlobClip({
    super.key,
    required this.background,
    required this.child,
    required this.enabled,
    required this.expandAnim,
  });

  @override
  State<AnimatedBlobClip> createState() => _AnimatedBlobClipState();
}

class _AnimatedBlobClipState extends State<AnimatedBlobClip>
    with TickerProviderStateMixin {
  late AnimationController _morphCtrl;
  late AnimationController _rotCtrl;
  late AnimationController _breathCtrl;

  @override
  void initState() {
    super.initState();

    // Morph: seamless phase via sin(2π·t) inside clipper (14 seconds)
    _morphCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 14000),
    );

    // Rotation: seamless sway via sin(2π·t) in builder (20 seconds)
    _rotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 20000),
    );

    // Breathing: seamless scale via sin(2π·t) in builder (10 seconds)
    _breathCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 10000),
    );

    if (widget.enabled) _startAll();
  }

  void _startAll() {
    _morphCtrl.repeat(); // sin(2π·t) in clipper = seamless loop
    _rotCtrl.repeat(); // sin(2π·t) in builder = smooth sway
    _breathCtrl.repeat(); // sin(2π·t) in builder = smooth breathing
  }

  void _stopAll() {
    _morphCtrl
      ..stop()
      ..value = 0;
    _rotCtrl
      ..stop()
      ..value = 0;
    _breathCtrl
      ..stop()
      ..value = 0;
  }

  @override
  void didUpdateWidget(AnimatedBlobClip old) {
    super.didUpdateWidget(old);
    if (widget.enabled == old.enabled) return;
    widget.enabled ? _startAll() : _stopAll();
  }

  @override
  void dispose() {
    _morphCtrl.dispose();
    _rotCtrl.dispose();
    _breathCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(child: widget.background),
            widget.child,
          ],
        ),
      );
    }

    return AnimatedBuilder(
      animation: Listenable.merge([
        _morphCtrl,
        _rotCtrl,
        _breathCtrl,
        widget.expandAnim,
      ]),
      builder: (context, _) {
        final ep = Curves.easeInOut.transform(
          widget.expandAnim.value.clamp(0.0, 1.0),
        );
        return Stack(
          fit: StackFit.passthrough,
          children: [
            // Layer 1: blob-clipped background (gradient / photo)
            Positioned.fill(
              child: ClipPath(
                clipper: BlobClipper(
                  morphTime: _morphCtrl.value,
                  // sin(2π·t) → smooth ±0.25 rad (~14°) sway, seamless
                  rotation: math.sin(2 * math.pi * _rotCtrl.value) * 0.25,
                  // sin(2π·t) → scale 0.97…1.03, seamless
                  scale: 1.0 + 0.03 * math.sin(2 * math.pi * _breathCtrl.value),
                  expandProgress: ep,
                ),
                child: widget.background,
              ),
            ),
            // Layer 2: content — stable, never deformed
            ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: RepaintBoundary(child: widget.child),
            ),
          ],
        );
      },
    );
  }
}
