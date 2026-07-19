import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../utils/safe_pick.dart';

import '../models/draw_stroke.dart';
import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_scope.dart';

// ── Palette (32 colours) ─────────────────────────────────────────────────────

const List<Color> _kPalette = [
  Color(0xFF000000),
  Color(0xFF1C1C1E),
  Color(0xFF374151),
  Color(0xFF6B7280),
  Color(0xFF9CA3AF),
  Color(0xFFD1D5DB),
  Color(0xFFF3F4F6),
  Color(0xFFFFFFFF),
  Color(0xFFEF4444),
  Color(0xFFF97316),
  Color(0xFFFBBF24),
  Color(0xFFEAB308),
  Color(0xFF84CC16),
  Color(0xFF22C55E),
  Color(0xFF10B981),
  Color(0xFF06B6D4),
  Color(0xFF3B82F6),
  Color(0xFF6366F1),
  Color(0xFF8B5CF6),
  Color(0xFFEC4899),
  Color(0xFFF43F5E),
  Color(0xFFFF6B9D),
  Color(0xFF92400E),
  Color(0xFFB45309),
  Color(0xFFDC8B3A),
  Color(0xFFFDE68A),
  Color(0xFFA7F3D0),
  Color(0xFFBFDBFE),
  Color(0xFFE9D5FF),
  Color(0xFFFFD1DC),
  Color(0xFF7C3AED),
  Color(0xFF065F46),
];

// ── Tools ─────────────────────────────────────────────────────────────────────

enum _Tool { brush, pencil, marker, eraser, fill, line, rect, circle, triangle }

// ── Fill layer ────────────────────────────────────────────────────────────────

class _FillLayer {
  final ui.Image img;
  final int order;
  _FillLayer(this.img, this.order);
  void dispose() => img.dispose();
}

// ── Flood fill (top-level — isolate-safe) ─────────────────────────────────────

Uint8List _doFloodFill(Map<String, dynamic> args) {
  final pixels = args['pixels'] as Uint8List;
  final w = args['w'] as int;
  final h = args['h'] as int;
  final tx = args['tx'] as int;
  final ty = args['ty'] as int;
  final fillR = args['fillR'] as int;
  final fillG = args['fillG'] as int;
  final fillB = args['fillB'] as int;
  final fillA = args['fillA'] as int;

  final si = (ty * w + tx) * 4;
  final tgtR = pixels[si];
  final tgtG = pixels[si + 1];
  final tgtB = pixels[si + 2];
  final tgtA = pixels[si + 3];

  if (tgtR == fillR && tgtG == fillG && tgtB == fillB && tgtA == fillA) {
    return Uint8List(0);
  }

  const tol = 32;
  final queue = <int>[ty * w + tx];
  int head = 0;
  final visited = Uint8List(w * h);
  final result = Uint8List(w * h * 4);

  while (head < queue.length) {
    final pos = queue[head++];
    if (visited[pos] != 0) continue;
    visited[pos] = 1;

    final x = pos % w;
    final y = pos ~/ w;
    final idx = pos * 4;

    if ((pixels[idx] - tgtR).abs() > tol ||
        (pixels[idx + 1] - tgtG).abs() > tol ||
        (pixels[idx + 2] - tgtB).abs() > tol ||
        (pixels[idx + 3] - tgtA).abs() > tol)
      continue;

    result[idx] = fillR;
    result[idx + 1] = fillG;
    result[idx + 2] = fillB;
    result[idx + 3] = fillA;

    if (x > 0) queue.add(pos - 1);
    if (x < w - 1) queue.add(pos + 1);
    if (y > 0) queue.add(pos - w);
    if (y < h - 1) queue.add(pos + w);
  }
  return result;
}

// ── Vector drawing utilities (top-level for reuse from painter) ───────────────

/// Velocity-based half-widths.  Slow movement → thick, fast → thin (50–100 %).
/// [endTaper] = false for live strokes whose end is still unknown.
List<double> _velocityHalfWidths(
  List<Offset> pts,
  double maxHalfW, {
  bool endTaper = true,
}) {
  if (pts.length <= 1) return [maxHalfW];

  final dists = <double>[0.0];
  for (int i = 1; i < pts.length; i++) {
    dists.add((pts[i] - pts[i - 1]).distance);
  }

  double maxD = dists.reduce(math.max);
  if (maxD < 1e-6) maxD = 1;

  var widths = dists
      .map((d) => maxHalfW * (1.0 - (d / maxD).clamp(0.0, 1.0) * 0.5))
      .toList();

  // 3-pass box-blur smoothing
  for (int pass = 0; pass < 3; pass++) {
    final next = List<double>.from(widths);
    for (int i = 1; i < widths.length - 1; i++) {
      next[i] = (widths[i - 1] + 2 * widths[i] + widths[i + 1]) / 4;
    }
    widths = next;
  }

  // Smooth-step taper at start
  const taperN = 12;
  final n = pts.length;
  for (int i = 0; i < math.min(taperN, n); i++) {
    final f = i / taperN;
    widths[i] *= f * f * (3 - 2 * f);
  }
  // Smooth-step taper at end (only for committed strokes)
  if (endTaper) {
    for (int i = math.max(0, n - taperN); i < n; i++) {
      final f = (n - 1 - i) / taperN;
      widths[i] *= f * f * (3 - 2 * f);
    }
  }
  return widths;
}

/// Builds the variable-width ribbon Path from smooth spline points + half-widths.
Path _buildRibbonPath(List<Offset> pts, List<double> halfWidths) {
  assert(pts.length == halfWidths.length);
  if (pts.isEmpty) return Path();
  if (pts.length == 1) {
    return Path()..addOval(
      Rect.fromCircle(
        center: pts.first,
        radius: math.max(halfWidths.first, 0.5),
      ),
    );
  }

  // Central-difference tangents
  final tangents = List<Offset>.filled(pts.length, Offset.zero);
  for (int i = 0; i < pts.length; i++) {
    Offset t;
    if (i == 0) {
      t = pts[1] - pts[0];
    } else if (i == pts.length - 1) {
      t = pts[i] - pts[i - 1];
    } else {
      t = pts[i + 1] - pts[i - 1];
    }
    final len = t.distance;
    tangents[i] = len > 1e-6
        ? Offset(t.dx / len, t.dy / len)
        : const Offset(1, 0);
  }

  final left = <Offset>[];
  final right = <Offset>[];
  for (int i = 0; i < pts.length; i++) {
    final t = tangents[i];
    final n = Offset(-t.dy, t.dx); // left normal
    final hw = math.max(halfWidths[i], 0.5);
    left.add(pts[i] + n * hw);
    right.add(pts[i] - n * hw);
  }

  final path = Path();
  path.moveTo(left.first.dx, left.first.dy);
  for (int i = 1; i < left.length; i++) {
    path.lineTo(left[i].dx, left[i].dy);
  }

  // Round end cap
  final eA = math.atan2(tangents.last.dy, tangents.last.dx);
  path.arcTo(
    Rect.fromCircle(center: pts.last, radius: math.max(halfWidths.last, 0.5)),
    eA - math.pi / 2,
    math.pi,
    false,
  );

  for (int i = right.length - 1; i >= 1; i--) {
    path.lineTo(right[i].dx, right[i].dy);
  }

  // Round start cap
  final sA = math.atan2(-tangents.first.dy, -tangents.first.dx);
  path.arcTo(
    Rect.fromCircle(center: pts.first, radius: math.max(halfWidths.first, 0.5)),
    sA - math.pi / 2,
    math.pi,
    false,
  );

  path.close();
  return path;
}

/// Catmull-Rom spline with simultaneous width interpolation.
/// Returns (splinePoints, interpolatedHalfWidths).
(List<Offset>, List<double>) _buildBrushSpline(
  List<Offset> inputPts,
  List<double> inputWidths, {
  int steps = 4,
}) {
  if (inputPts.length < 2) return (inputPts, inputWidths);

  final splinePts = <Offset>[];
  final splineW = <double>[];

  final ext = [inputPts.first, ...inputPts, inputPts.last];
  final extW = [inputWidths.first, ...inputWidths, inputWidths.last];

  for (int i = 1; i < ext.length - 2; i++) {
    final p0 = ext[i - 1], p1 = ext[i], p2 = ext[i + 1], p3 = ext[i + 2];
    final w1 = extW[i], w2 = extW[i + 1];

    for (int s = 0; s < steps; s++) {
      final t = s / steps, t2 = t * t, t3 = t2 * t;
      final x =
          0.5 *
          ((2 * p1.dx) +
              (-p0.dx + p2.dx) * t +
              (2 * p0.dx - 5 * p1.dx + 4 * p2.dx - p3.dx) * t2 +
              (-p0.dx + 3 * p1.dx - 3 * p2.dx + p3.dx) * t3);
      final y =
          0.5 *
          ((2 * p1.dy) +
              (-p0.dy + p2.dy) * t +
              (2 * p0.dy - 5 * p1.dy + 4 * p2.dy - p3.dy) * t2 +
              (-p0.dy + 3 * p1.dy - 3 * p2.dy + p3.dy) * t3);
      splinePts.add(Offset(x, y));
      splineW.add((1 - t) * w1 + t * w2);
    }
  }
  splinePts.add(inputPts.last);
  splineW.add(inputWidths.last);
  return (splinePts, splineW);
}

// ── Result returned when the user saves ──────────────────────────────────────

class MascotDrawResult {
  final Uint8List pngBytes;
  final String name;
  MascotDrawResult({required this.pngBytes, required this.name});
}

// ── Screen ────────────────────────────────────────────────────────────────────

class MascotDrawScreen extends StatefulWidget {
  final AppTheme theme;
  final String? initialName;
  final Uint8List? initialPngBytes;
  final bool isGalleryFull;

  const MascotDrawScreen({
    super.key,
    required this.theme,
    this.initialName,
    this.initialPngBytes,
    this.isGalleryFull = false,
  });

  @override
  State<MascotDrawScreen> createState() => _MascotDrawScreenState();
}

class _MascotDrawScreenState extends State<MascotDrawScreen> {
  final GlobalKey _canvasKey = GlobalKey();

  // ── Strokes ──────────────────────────────────────────────────────────────
  final List<DrawStroke> _strokes = [];
  final List<DrawStroke> _redoStack = [];
  final List<DrawPoint> _currentPoints = [];
  int _orderCounter = 0;

  // Per-stroke brush type (keyed by stroke id)
  final Map<String, int> _strokeTools = {};
  final Map<String, int> _redoTools = {};

  // ── Fill layers ───────────────────────────────────────────────────────────
  final List<_FillLayer> _fillLayers = [];
  final List<_FillLayer> _fillRedoStack = [];
  bool _isFilling = false;

  // ── Path cache: strokeId → (Path, canvasWidth) ────────────────────────────
  final Map<String, (Path, double)> _pathCache = {};

  // ── Previous drawing (edit mode) ───────────────────────────────────
  // Loaded from initialPngBytes; rendered INSIDE RepaintBoundary so it is
  // baked into the exported PNG (the user draws on top of it).
  ui.Image? _prevDrawingImage;

  // ── Photo reference (user-picked guide) ─────────────────────────
  // Rendered OUTSIDE RepaintBoundary — never included in export.
  ui.Image? _refImage;
  bool _showRef = true;

  // ── Tool state ────────────────────────────────────────────────────────────
  _Tool _tool = _Tool.brush;
  Color _color = Colors.black;
  double _strokeWidth = 8.0;
  double _opacity = 1.0;
  bool _fillShapes = false;

  // Recent colours (last 5 used)
  final List<Color> _recentColors = [];

  // Live brush cursor position (canvas-local pixels, null when not drawing)
  Offset? _liveCursor;

  bool _saving = false;

  // ── Canvas transform ──────────────────────────────────────────────────────
  double _canvasScale = 1.0;
  double _canvasRotation = 0.0;
  Offset _canvasPan = Offset.zero;
  double _baseScale = 1.0;
  double _baseRotation = 0.0;
  int _activePointers = 0;

  // Two-finger-tap → undo
  int _twoFingerCount = 0;
  DateTime? _twoFingerStart;

  // True while ≥2 fingers are (or were) on screen; prevents accidental
  // strokes from the last remaining finger after a zoom/rotate gesture.
  bool _gestureMode = false;

  // Canvas side length (tracked to invalidate path cache on resize)
  double _canvasSide = 300;

  AppTheme get _t => widget.theme;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // In edit mode: load the saved PNG as a permanent background layer.
    // It is drawn inside the RepaintBoundary so new strokes appear on top
    // and it is included in the exported PNG.
    if (widget.initialPngBytes != null)
      _loadPrevDrawing(widget.initialPngBytes!);
  }

  @override
  void dispose() {
    for (final f in _fillLayers) f.dispose();
    for (final f in _fillRedoStack) f.dispose();
    _prevDrawingImage?.dispose();
    _refImage?.dispose();
    super.dispose();
  }

  /// Loads the previous drawing into [_prevDrawingImage] (edit background).
  Future<void> _loadPrevDrawing(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _prevDrawingImage = frame.image);
  }

  /// Loads a user-picked photo into [_refImage] (semi-transparent guide).
  Future<void> _loadRefImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _refImage = frame.image);
  }

  // ── Computed helpers ──────────────────────────────────────────────────────

  bool get _isShapeTool =>
      _tool == _Tool.line ||
      _tool == _Tool.rect ||
      _tool == _Tool.circle ||
      _tool == _Tool.triangle;

  bool get _isDrawingTool =>
      _tool == _Tool.brush || _tool == _Tool.pencil || _tool == _Tool.marker;

  bool get _showOpacity => _isDrawingTool;

  DrawShapeType? get _activeShape => switch (_tool) {
    _Tool.line => DrawShapeType.line,
    _Tool.rect => DrawShapeType.rect,
    _Tool.circle => DrawShapeType.circle,
    _Tool.triangle => DrawShapeType.triangle,
    _ => null,
  };

  bool get _canUndo => _strokes.isNotEmpty || _fillLayers.isNotEmpty;
  bool get _canRedo => _redoStack.isNotEmpty || _fillRedoStack.isNotEmpty;

  bool get _isTransformed =>
      _canvasScale != 1.0 ||
      _canvasRotation != 0.0 ||
      _canvasPan != Offset.zero;

  /// Cursor circle radius in canvas-local pixels.
  double get _cursorHalfW => (_strokeWidth * (_canvasSide / 500.0)) / 2;

  // ── Tool / colour helpers ─────────────────────────────────────────────────

  void _selectTool(_Tool t) {
    HapticFeedback.selectionClick();
    setState(() => _tool = t);
  }

  void _selectColor(Color c) {
    setState(() {
      _color = c;
      _addRecent(c);
    });
  }

  void _addRecent(Color c) {
    _recentColors.removeWhere((r) => r.value == c.value);
    _recentColors.insert(0, c);
    if (_recentColors.length > 5) _recentColors.removeLast();
  }

  // ── Pointer events ────────────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent e, Size canvasSize) {
    _activePointers++;

    if (_activePointers >= 2) {
      // Two or more fingers → gesture mode; cancel any in-progress stroke.
      _gestureMode = true;
      if (_activePointers == 2) {
        _twoFingerCount = 2;
        _twoFingerStart = DateTime.now();
      }
      if (_currentPoints.isNotEmpty) {
        setState(() {
          _currentPoints.clear();
          _liveCursor = null;
        });
      }
      return;
    }

    // Don't start a new stroke while gesture mode is still active
    // (can happen when one finger lifts and the other is still on screen).
    if (_gestureMode) return;

    if (_tool == _Tool.fill) {
      _applyFill(canvasSize, e.localPosition);
      return;
    }

    setState(() {
      _currentPoints
        ..clear()
        ..add(_normalize(e.localPosition, canvasSize));
      _liveCursor = e.localPosition;
    });
  }

  void _onPointerMove(PointerMoveEvent e, Size canvasSize) {
    // Ignore moves while multi-touch gesture is in progress.
    if (_activePointers != 1 || _gestureMode) return;
    if (_tool == _Tool.fill) return;

    final pt = _normalize(e.localPosition, canvasSize);

    // Minimum-distance filter: skip points closer than 1.5 px
    if (_currentPoints.isNotEmpty) {
      final last = _currentPoints.last;
      final dx = (pt.x - last.x) * canvasSize.width;
      final dy = (pt.y - last.y) * canvasSize.height;
      if (dx * dx + dy * dy < 2.25) {
        // Still update cursor visual
        if (_liveCursor != null) setState(() => _liveCursor = e.localPosition);
        return;
      }
    }

    setState(() {
      _currentPoints.add(pt);
      _liveCursor = e.localPosition;
    });
  }

  void _onPointerUp(PointerUpEvent e, Size canvasSize) {
    // Only a genuine drawing stroke if we are in single-finger mode AND
    // gesture mode was never triggered during this touch.
    final wasDrawing = _activePointers == 1 && !_gestureMode;
    _activePointers = math.max(0, _activePointers - 1);

    // All fingers lifted → leave gesture mode.
    if (_activePointers == 0) _gestureMode = false;

    // Two-finger tap → undo
    if (_twoFingerCount == 2 && _activePointers == 0) {
      final start = _twoFingerStart;
      if (start != null &&
          DateTime.now().difference(start).inMilliseconds < 300) {
        _twoFingerCount = 0;
        if (_canUndo) {
          HapticFeedback.lightImpact();
          _undo();
        }
        return;
      }
      _twoFingerCount = 0;
    }

    if (!wasDrawing || _tool == _Tool.fill || _currentPoints.isEmpty) {
      if (_activePointers == 0) {
        setState(() {
          _currentPoints.clear();
          _liveCursor = null;
        });
      }
      return;
    }

    // Commit stroke
    final pts = List<DrawPoint>.from(_currentPoints);
    final id = 'local_${_orderCounter++}';
    final effectiveColor = Color.fromARGB(
      (_opacity * 255).round().clamp(0, 255),
      _color.red,
      _color.green,
      _color.blue,
    );

    final stroke = DrawStroke(
      id: id,
      userId: 'local',
      colorValue: effectiveColor.value,
      strokeWidth: _strokeWidth,
      points: pts,
      isEraser: _tool == _Tool.eraser,
      isFilledShape: _fillShapes && _isShapeTool,
      shapeType: _activeShape,
      orderIndex: _orderCounter,
    );

    // Discard redo history on new stroke
    for (final f in _fillRedoStack) f.dispose();

    setState(() {
      _strokes.add(stroke);
      _strokeTools[id] = _tool.index;
      _redoStack.clear();
      _fillRedoStack.clear();
      _redoTools.clear();
      _currentPoints.clear();
      _liveCursor = null;
    });
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _activePointers = math.max(0, _activePointers - 1);
    if (_activePointers == 0) _gestureMode = false;
    setState(() {
      _currentPoints.clear();
      _liveCursor = null;
    });
  }

  DrawPoint _normalize(Offset local, Size size) => DrawPoint(
    (local.dx / size.width).clamp(0.0, 1.0),
    (local.dy / size.height).clamp(0.0, 1.0),
  );

  // ── Flood fill ────────────────────────────────────────────────────────────

  Future<void> _applyFill(Size canvasSize, Offset tapLocal) async {
    if (_isFilling) return;
    setState(() => _isFilling = true);
    try {
      final w = canvasSize.width.round();
      final h = canvasSize.height.round();

      // Render canvas to an off-screen bitmap
      final recorder = ui.PictureRecorder();
      final offCanvas = Canvas(recorder);
      offCanvas.saveLayer(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint(),
      );
      offCanvas.drawRect(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..color = Colors.white,
      );
      // Composite prev drawing below new strokes so flood fill sees boundaries.
      if (_prevDrawingImage != null) {
        offCanvas.drawImageRect(
          _prevDrawingImage!,
          Rect.fromLTWH(
            0,
            0,
            _prevDrawingImage!.width.toDouble(),
            _prevDrawingImage!.height.toDouble(),
          ),
          Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          Paint(),
        );
      }
      _MascotCanvasPainter(
        strokes: _strokes,
        fillLayers: _fillLayers,
        currentPoints: const [],
        currentColor: Colors.black,
        currentWidth: 1,
        isEraser: false,
        shapeType: null,
        fillShapes: false,
        canvasSize: canvasSize.width,
        strokeTools: _strokeTools,
        currentTool: _Tool.brush.index,
        pathCache: {},
      ).paint(offCanvas, Size(w.toDouble(), h.toDouble()));
      offCanvas.restore();

      final picture = recorder.endRecording();
      final snapshot = await picture.toImage(w, h);
      final byteData = await snapshot.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      snapshot.dispose();
      if (byteData == null || !mounted) return;

      final pixels = Uint8List.fromList(byteData.buffer.asUint8List());
      final tx = tapLocal.dx.round().clamp(0, w - 1);
      final ty = tapLocal.dy.round().clamp(0, h - 1);

      final filled = await compute(_doFloodFill, {
        'pixels': pixels,
        'w': w,
        'h': h,
        'tx': tx,
        'ty': ty,
        'fillR': _color.red,
        'fillG': _color.green,
        'fillB': _color.blue,
        'fillA': (_opacity * 255).round().clamp(0, 255),
      });

      if (filled.isEmpty || !mounted) return;

      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        filled,
        w,
        h,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final fillImage = await completer.future;

      if (!mounted) {
        fillImage.dispose();
        return;
      }

      for (final f in _fillRedoStack) f.dispose();
      setState(() {
        _fillLayers.add(_FillLayer(fillImage, _orderCounter++));
        _redoStack.clear();
        _fillRedoStack.clear();
        _redoTools.clear();
      });
    } catch (e) {
      debugPrint('[Fill] error: $e');
    } finally {
      if (mounted) setState(() => _isFilling = false);
    }
  }

  // ── History ───────────────────────────────────────────────────────────────

  void _undo() {
    final lastStroke = _strokes.isEmpty ? -1 : _strokes.last.orderIndex;
    final lastFill = _fillLayers.isEmpty ? -1 : _fillLayers.last.order;
    if (lastStroke == -1 && lastFill == -1) return;
    setState(() {
      if (lastFill > lastStroke) {
        _fillRedoStack.add(_fillLayers.removeLast());
      } else {
        final s = _strokes.removeLast();
        _pathCache.remove(s.id);
        _redoStack.add(s);
        final t = _strokeTools.remove(s.id);
        if (t != null) _redoTools[s.id] = t;
      }
    });
  }

  void _redo() {
    final redoStroke = _redoStack.isEmpty ? -1 : _redoStack.last.orderIndex;
    final redoFill = _fillRedoStack.isEmpty ? -1 : _fillRedoStack.last.order;
    if (redoStroke == -1 && redoFill == -1) return;
    setState(() {
      if (redoFill > redoStroke) {
        _fillLayers.add(_fillRedoStack.removeLast());
      } else {
        final s = _redoStack.removeLast();
        _strokes.add(s);
        final t = _redoTools.remove(s.id);
        if (t != null) _strokeTools[s.id] = t;
      }
    });
  }

  void _clear() {
    setState(() {
      for (final s in _strokes) {
        _pathCache.remove(s.id);
        _redoStack.add(s);
        final t = _strokeTools.remove(s.id);
        if (t != null) _redoTools[s.id] = t;
      }
      _strokes.clear();
      for (final f in _fillLayers) _fillRedoStack.add(f);
      _fillLayers.clear();
    });
  }

  // ── Canvas transform ──────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails _) {
    _baseScale = _canvasScale;
    _baseRotation = _canvasRotation;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount < 2) return;
    setState(() {
      _canvasScale = (_baseScale * d.scale).clamp(0.25, 6.0);
      _canvasRotation = _baseRotation + d.rotation;
      _canvasPan += d.focalPointDelta;
    });
  }

  void _resetTransform() => setState(() {
    _canvasScale = 1.0;
    _canvasRotation = 0.0;
    _canvasPan = Offset.zero;
  });

  // ── Reference image ───────────────────────────────────────────────────────

  Future<void> _pickRefImage() async {
    final xFile = await safePick(
      () => ImagePicker().pickImage(source: ImageSource.gallery),
    );
    if (xFile == null) return;
    final bytes = await xFile.readAsBytes();
    // Always use _loadRefImage so the old _refImage is never confused
    // with _prevDrawingImage (the edit-mode background).
    await _loadRefImage(Uint8List.fromList(bytes));
    if (mounted) setState(() => _showRef = true);
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    // Allow saving when there's a previous drawing even if no new strokes.
    final hasContent =
        _strokes.isNotEmpty ||
        _fillLayers.isNotEmpty ||
        _prevDrawingImage != null;
    if (!hasContent) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(LocaleService.current.drawSomethingFirst)),
      );
      return;
    }
    final name = await _showNameDialog();
    if (name == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final boundary =
          _canvasKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('Canvas not found');

      // Capture the new-strokes layer (transparent background).
      final drawing = await boundary.toImage(pixelRatio: 2.0);
      final w = drawing.width;
      final h = drawing.height;

      // Composite: transparent + prevDrawing (if editing) + new strokes → final PNG.
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder);

      // 1. Previous drawing (edit mode)
      if (_prevDrawingImage != null) {
        c.drawImageRect(
          _prevDrawingImage!,
          Rect.fromLTWH(
            0,
            0,
            _prevDrawingImage!.width.toDouble(),
            _prevDrawingImage!.height.toDouble(),
          ),
          Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          Paint(),
        );
      }

      // 2. New strokes on top
      c.drawImage(drawing, Offset.zero, Paint());
      drawing.dispose();
      final composite = recorder.endRecording();
      final finalImg = await composite.toImage(w, h);
      final byteData = await finalImg.toByteData(
        format: ui.ImageByteFormat.png,
      );
      finalImg.dispose();

      if (byteData == null) throw Exception('PNG conversion failed');
      if (!mounted) return;
      Navigator.of(context).pop(
        MascotDrawResult(pngBytes: byteData.buffer.asUint8List(), name: name),
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(content: Text(LocaleService.current.genericError('$e'))),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _showNameDialog() async {
    final ctrl = TextEditingController(text: widget.initialName ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(LocaleService.current.mascotNameTitle),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          decoration: InputDecoration(
            hintText: LocaleService.current.enterNameHint,
          ),
          onSubmitted: (_) => Navigator.of(ctx).pop(ctrl.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(LocaleService.current.cancel),
          ),
          TextButton(
            onPressed: () {
              final n = ctrl.text.trim();
              if (n.isNotEmpty) Navigator.of(ctx).pop(n);
            },
            child: Text(
              LocaleService.current.save,
              style: TextStyle(color: _t.primary, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // ── Custom colour picker ──────────────────────────────────────────────────

  Future<void> _pickCustomColor() async {
    final result = await showDialog<Color>(
      context: context,
      builder: (ctx) =>
          _ColorPickerDialog(initial: _color, primaryColor: _t.primary),
    );
    if (result != null) _selectColor(result);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _t.surfaceMuted,
      appBar: AppBar(
        backgroundColor: _t.cardSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          LocaleService.current.drawMascotTitle,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(
              onPressed: widget.isGalleryFull ? null : _save,
              child: Text(
                LocaleService.current.save,
                style: TextStyle(
                  color: widget.isGalleryFull ? _t.textMuted : _t.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onDoubleTap: _resetTransform,
        child: Column(
          children: [
            if (widget.isGalleryFull)
              Container(
                color: Colors.orange.shade50,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        LocaleService.current.mascotLimitReached,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(child: Center(child: _buildCanvas())),
            _buildToolbar(),
          ],
        ),
      ),
    );
  }

  // ── Canvas ────────────────────────────────────────────────────────────────

  Widget _buildCanvas() {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final side = math.min(constraints.maxWidth, constraints.maxHeight) - 16;

        // Invalidate path cache when canvas size changes (e.g. rotation)
        if (side != _canvasSide) {
          _canvasSide = side;
          _pathCache.clear();
        }

        return Transform.translate(
          offset: _canvasPan,
          child: Transform(
            transform: Matrix4.identity()
              ..rotateZ(_canvasRotation)
              ..scale(_canvasScale),
            alignment: Alignment.center,
            child: Container(
              width: side,
              height: side,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(28),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    // ── 1. Previous drawing / edit background (not exported separately:
                    //    composited manually in _save). Visible at full opacity so
                    //    the user sees their old mascot while adding new strokes.
                    if (_prevDrawingImage != null)
                      Positioned.fill(
                        child: RawImage(
                          image: _prevDrawingImage!,
                          fit: BoxFit.contain,
                        ),
                      ),

                    // ── 2. Photo reference (semi-transparent, never exported) ───────
                    if (_refImage != null && _showRef)
                      Positioned.fill(
                        child: Opacity(
                          opacity: 0.35,
                          child: RawImage(
                            image: _refImage!,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),

                    // ── 3. Drawing surface (new strokes only) ─────────────────────
                    RepaintBoundary(
                      key: _canvasKey,
                      child: Listener(
                        onPointerDown: (e) =>
                            _onPointerDown(e, Size(side, side)),
                        onPointerMove: (e) =>
                            _onPointerMove(e, Size(side, side)),
                        onPointerUp: (e) => _onPointerUp(e, Size(side, side)),
                        onPointerCancel: _onPointerCancel,
                        child: CustomPaint(
                          size: Size(side, side),
                          painter: _MascotCanvasPainter(
                            strokes: _strokes,
                            fillLayers: _fillLayers,
                            currentPoints: _currentPoints,
                            currentColor: Color.fromARGB(
                              (_opacity * 255).round().clamp(0, 255),
                              _color.red,
                              _color.green,
                              _color.blue,
                            ),
                            currentWidth: _strokeWidth,
                            isEraser: _tool == _Tool.eraser,
                            shapeType: _activeShape,
                            fillShapes: _fillShapes,
                            canvasSize: side,
                            strokeTools: _strokeTools,
                            currentTool: _tool.index,
                            pathCache: _pathCache,
                          ),
                        ),
                      ),
                    ),

                    // ── Live brush cursor (outside RepaintBoundary) ──────────────
                    if (_liveCursor != null && _tool != _Tool.fill)
                      Positioned(
                        left: _liveCursor!.dx - _cursorHalfW,
                        top: _liveCursor!.dy - _cursorHalfW,
                        child: IgnorePointer(
                          child: Container(
                            width: _cursorHalfW * 2,
                            height: _cursorHalfW * 2,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _tool == _Tool.eraser
                                  ? Colors.grey.shade100.withAlpha(180)
                                  : _color.withAlpha(
                                      ((_opacity * 0.35) * 255).round(),
                                    ),
                              border: Border.all(
                                color: _tool == _Tool.eraser
                                    ? Colors.grey.shade500
                                    : Colors.white.withAlpha(200),
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                      ),

                    // ── Fill spinner ─────────────────────────────────────────────
                    if (_isFilling)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Color(0x22000000),
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Toolbar ───────────────────────────────────────────────────────────────

  Widget _buildToolbar() {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      color: _t.cardSurface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(height: 1, color: _t.divider),

          // ── Row 1: Tools ────────────────────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                _ToolBtn(
                  icon: Icons.brush,
                  label: LocaleService.current.toolBrush,
                  active: _tool == _Tool.brush,
                  color: _t.primary,
                  onTap: () => _selectTool(_Tool.brush),
                ),
                _ToolBtn(
                  icon: Icons.edit,
                  label: LocaleService.current.toolPencil,
                  active: _tool == _Tool.pencil,
                  color: _t.primary,
                  onTap: () => _selectTool(_Tool.pencil),
                ),
                _ToolBtn(
                  icon: Icons.highlight,
                  label: LocaleService.current.toolMarker,
                  active: _tool == _Tool.marker,
                  color: _t.primary,
                  onTap: () => _selectTool(_Tool.marker),
                ),
                _ToolBtn(
                  icon: Icons.auto_fix_normal,
                  label: LocaleService.current.toolEraser,
                  active: _tool == _Tool.eraser,
                  color: _t.textSecondary,
                  onTap: () => _selectTool(_Tool.eraser),
                ),
                _ToolBtn(
                  icon: Icons.format_color_fill,
                  label: LocaleService.current.toolFill,
                  active: _tool == _Tool.fill,
                  color: _t.primary,
                  onTap: () => _selectTool(_Tool.fill),
                ),

                Container(
                  height: 32,
                  width: 1,
                  color: _t.divider,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                ),

                _ToolBtn(
                  icon: Icons.horizontal_rule,
                  label: LocaleService.current.toolLine,
                  active: _tool == _Tool.line,
                  color: _t.primary,
                  onTap: () => _selectTool(_Tool.line),
                ),
                _ToolBtn(
                  icon: Icons.rectangle_outlined,
                  label: LocaleService.current.toolRect,
                  active: _tool == _Tool.rect,
                  color: _t.primary,
                  onTap: () => _selectTool(_Tool.rect),
                ),
                _ToolBtn(
                  icon: Icons.circle_outlined,
                  label: LocaleService.current.toolCircle,
                  active: _tool == _Tool.circle,
                  color: _t.primary,
                  onTap: () => _selectTool(_Tool.circle),
                ),
                _ToolBtn(
                  icon: Icons.change_history,
                  label: LocaleService.current.toolTriangle,
                  active: _tool == _Tool.triangle,
                  color: _t.primary,
                  onTap: () => _selectTool(_Tool.triangle),
                ),

                if (_isShapeTool) ...[
                  Container(
                    height: 32,
                    width: 1,
                    color: _t.divider,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  _ToolBtn(
                    icon: _fillShapes
                        ? Icons.square_rounded
                        : Icons.square_outlined,
                    label: LocaleService.current.fillAction,
                    active: _fillShapes,
                    color: _t.primary,
                    onTap: () => setState(() => _fillShapes = !_fillShapes),
                  ),
                ],
              ],
            ),
          ),

          // ── Row 2: Size + Opacity ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              children: [
                // Brush-preview dot
                GestureDetector(
                  onTap: () => setState(() {
                    _strokeWidth = 8.0;
                    _opacity = 1.0;
                  }),
                  child: Tooltip(
                    message: LocaleService.current.resetSize,
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: (_strokeWidth * (_canvasSide / 500.0)).clamp(
                            3.0,
                            32.0,
                          ),
                          height: (_strokeWidth * (_canvasSide / 500.0)).clamp(
                            3.0,
                            32.0,
                          ),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _tool == _Tool.eraser
                                ? Colors.grey.shade300
                                : _color.withAlpha(
                                    (_opacity * 255).round().clamp(0, 255),
                                  ),
                            border: Border.all(
                              color: _t.divider,
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Size slider
                Expanded(
                  child: _thinSlider(
                    value: _strokeWidth,
                    min: 1,
                    max: 60,
                    onChanged: (v) => setState(() => _strokeWidth = v),
                  ),
                ),
                SizedBox(
                  width: 30,
                  child: Text(
                    '${_strokeWidth.round()}',
                    style: TextStyle(fontSize: 11, color: _t.textMuted),
                    textAlign: TextAlign.center,
                  ),
                ),

                if (_showOpacity) ...[
                  Container(
                    width: 1,
                    height: 20,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    color: _t.divider,
                  ),
                  Icon(Icons.opacity, size: 16, color: _t.textMuted),
                  Expanded(
                    child: _thinSlider(
                      value: _opacity,
                      min: 0.05,
                      max: 1.0,
                      onChanged: (v) => setState(() => _opacity = v),
                    ),
                  ),
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${(_opacity * 100).round()}%',
                      style: TextStyle(fontSize: 11, color: _t.textMuted),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── Row 3: Colour palette ────────────────────────────────────────
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              children: [
                if (_recentColors.isNotEmpty) ...[
                  for (final c in _recentColors)
                    _ColorSwatch(
                      color: c,
                      selected: c.value == _color.value,
                      onTap: () => _selectColor(c),
                    ),
                  Container(
                    width: 1,
                    height: 28,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    color: _t.divider,
                  ),
                ],

                for (final c in _kPalette)
                  _ColorSwatch(
                    color: c,
                    selected: c.value == _color.value,
                    onTap: () => _selectColor(c),
                  ),

                // Custom colour button (rainbow wheel)
                GestureDetector(
                  onTap: _pickCustomColor,
                  child: Container(
                    width: 28,
                    height: 28,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _t.divider,
                        width: 1.5,
                      ),
                      gradient: const SweepGradient(
                        colors: [
                          Color(0xFFFF0000),
                          Color(0xFFFFFF00),
                          Color(0xFF00FF00),
                          Color(0xFF00FFFF),
                          Color(0xFF0000FF),
                          Color(0xFFFF00FF),
                          Color(0xFFFF0000),
                        ],
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.add,
                          size: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Row 4: Actions ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                _ActionBtn(
                  icon: Icons.undo,
                  label: LocaleService.current.undoLabel,
                  enabled: _canUndo,
                  onTap: _undo,
                ),
                _ActionBtn(
                  icon: Icons.redo,
                  label: LocaleService.current.redoLabel,
                  enabled: _canRedo,
                  onTap: _redo,
                ),
                _ActionBtn(
                  icon: Icons.delete_outline,
                  label: LocaleService.current.clear,
                  enabled: _canUndo,
                  onTap: _clear,
                  danger: true,
                ),
                const Spacer(),
                if (_isTransformed)
                  _ActionBtn(
                    icon: Icons.fit_screen,
                    label: LocaleService.current.reset,
                    enabled: true,
                    onTap: _resetTransform,
                    highlight: true,
                  ),
                _ActionBtn(
                  icon: Icons.image_outlined,
                  label: LocaleService.current.underlayLabel,
                  enabled: true,
                  onTap: _pickRefImage,
                  highlight: _refImage != null && _showRef,
                ),
                if (_refImage != null)
                  _ActionBtn(
                    icon: _showRef
                        ? Icons.visibility
                        : Icons.visibility_off_outlined,
                    label: '',
                    enabled: true,
                    onTap: () => setState(() => _showRef = !_showRef),
                  ),
              ],
            ),
          ),

          // Hint
          Padding(
            padding: EdgeInsets.only(bottom: math.max(bottom - 4, 4)),
            child: Text(
              _isTransformed
                  ? LocaleService.current.drawHintEdit
                  : LocaleService.current.drawHintDraw,
              style: TextStyle(fontSize: 10, color: _t.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  // Thin styled slider
  Widget _thinSlider({
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: _t.primary.withAlpha(160),
        inactiveTrackColor: _t.divider,
        thumbColor: _t.primary,
        overlayColor: _t.primary.withAlpha(25),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      child: Slider(value: value, min: min, max: max, onChanged: onChanged),
    );
  }
}

// ── Tool button ───────────────────────────────────────────────────────────────

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Color color;
  final VoidCallback? onTap;

  const _ToolBtn({
    required this.icon,
    required this.label,
    required this.active,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final t = context.appTheme;
    return GestureDetector(
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              onTap!();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: active ? color.withAlpha(28) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? color : t.divider,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Icon(
          icon,
          size: 22,
          color: !enabled
              ? t.textMuted
              : active
              ? color
              : t.textSecondary,
        ),
      ),
    );
  }
}

// ── Action button ─────────────────────────────────────────────────────────────

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onTap;
  final bool danger;
  final bool highlight;

  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.enabled,
    this.onTap,
    this.danger = false,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    final Color ic;
    if (!enabled)
      ic = t.textMuted;
    else if (danger)
      ic = Colors.red.shade400;
    else if (highlight)
      ic = Colors.blue.shade400;
    else
      ic = t.textSecondary;

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Icon(icon, size: 22, color: ic),
      ),
    );
  }
}

// ── Colour swatch ─────────────────────────────────────────────────────────────

class _ColorSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 28,
        height: 28,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: selected
              ? Border.all(color: Colors.white, width: 2.5)
              : Border.all(
                  color: color == Colors.white
                      ? Colors.grey.shade300
                      : Colors.transparent,
                  width: 1,
                ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(selected ? 60 : 22),
              blurRadius: selected ? 5 : 2,
            ),
            if (selected)
              BoxShadow(
                color: color.withAlpha(80),
                blurRadius: 6,
                spreadRadius: 1,
              ),
          ],
        ),
      ),
    );
  }
}

// ── Canvas painter ────────────────────────────────────────────────────────────

class _MascotCanvasPainter extends CustomPainter {
  final List<DrawStroke> strokes;
  final List<_FillLayer> fillLayers;
  final List<DrawPoint> currentPoints;
  final Color currentColor;
  final double currentWidth;
  final bool isEraser;
  final DrawShapeType? shapeType;
  final bool fillShapes;
  final double canvasSize;
  final Map<String, int> strokeTools; // id → _Tool.index
  final int currentTool;
  final Map<String, (Path, double)> pathCache; // shared, mutated during paint

  _MascotCanvasPainter({
    required this.strokes,
    required this.fillLayers,
    required this.currentPoints,
    required this.currentColor,
    required this.currentWidth,
    required this.isEraser,
    required this.shapeType,
    required this.fillShapes,
    required this.canvasSize,
    required this.strokeTools,
    required this.currentTool,
    required this.pathCache,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Compositing layer — required for BlendMode.clear (eraser) to work
    // correctly without bleeding outside the canvas bounds.
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());

    // ── All strokes + fills in creation order ────────────────────────────────
    final items = <(int, Object)>[
      for (final s in strokes) (s.orderIndex, s as Object),
      for (final f in fillLayers) (f.order, f as Object),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    for (final (_, item) in items) {
      if (item is DrawStroke) {
        _renderStroke(canvas, size, item, live: false);
      } else if (item is _FillLayer) {
        canvas.drawImageRect(
          item.img,
          Rect.fromLTWH(
            0,
            0,
            item.img.width.toDouble(),
            item.img.height.toDouble(),
          ),
          Rect.fromLTWH(0, 0, size.width, size.height),
          Paint(),
        );
      }
    }

    // ── 4. Live in-progress stroke ────────────────────────────────────────
    if (currentPoints.isNotEmpty) {
      _renderStroke(
        canvas,
        size,
        DrawStroke(
          id: '_live',
          userId: 'local',
          colorValue: currentColor.value,
          strokeWidth: currentWidth,
          points: currentPoints,
          isEraser: isEraser,
          isFilledShape: fillShapes && shapeType != null,
          shapeType: shapeType,
          orderIndex: -1,
        ),
        live: true,
      );
    }

    canvas.restore();
  }

  // ── Stroke dispatcher ─────────────────────────────────────────────────────

  void _renderStroke(
    Canvas canvas,
    Size size,
    DrawStroke stroke, {
    required bool live,
  }) {
    if (stroke.points.isEmpty) return;

    final paint = Paint()..isAntiAlias = true;
    if (stroke.isEraser) {
      paint
        ..blendMode = BlendMode.clear
        ..color = Colors.transparent;
    } else {
      paint.color = Color(stroke.colorValue);
    }

    // Shape tools
    if (stroke.shapeType != null && stroke.points.length >= 2) {
      paint
        ..strokeWidth = stroke.strokeWidth * (size.width / 500.0)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      _drawShape(
        canvas,
        paint,
        stroke.shapeType!,
        stroke.points.first.toOffset(size),
        stroke.points.last.toOffset(size),
        stroke.isFilledShape,
      );
      return;
    }

    final toolIdx = live
        ? currentTool
        : (strokeTools[stroke.id] ?? _Tool.brush.index);
    final tool = _Tool.values[toolIdx];

    if (!stroke.isEraser && tool == _Tool.brush && stroke.points.length > 1) {
      _renderRibbon(canvas, size, stroke, live: live);
    } else {
      _renderBezier(canvas, size, stroke, paint, tool);
    }
  }

  // ── Ribbon brush (Catmull-Rom + velocity widths) ──────────────────────────

  void _renderRibbon(
    Canvas canvas,
    Size size,
    DrawStroke stroke, {
    required bool live,
  }) {
    final maxHalfW = stroke.strokeWidth * (size.width / 500.0) / 2;
    Path path;

    if (!live) {
      final cached = pathCache[stroke.id];
      if (cached != null && cached.$2 == size.width) {
        path = cached.$1;
      } else {
        path = _buildBrushPath(stroke.points, size, maxHalfW, endTaper: true);
        pathCache[stroke.id] = (path, size.width);
      }
    } else {
      path = _buildBrushPath(stroke.points, size, maxHalfW, endTaper: false);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = Color(stroke.colorValue)
        ..isAntiAlias = true
        ..style = PaintingStyle.fill,
    );
  }

  static Path _buildBrushPath(
    List<DrawPoint> inputPts,
    Size size,
    double maxHalfW, {
    required bool endTaper,
  }) {
    if (inputPts.length == 1) {
      return Path()..addOval(
        Rect.fromCircle(
          center: inputPts.first.toOffset(size),
          radius: math.max(maxHalfW, 0.5),
        ),
      );
    }
    final offsets = inputPts.map((p) => p.toOffset(size)).toList();
    final inputWidths = _velocityHalfWidths(
      offsets,
      maxHalfW,
      endTaper: endTaper,
    );
    final (sp, sw) = _buildBrushSpline(offsets, inputWidths);
    return _buildRibbonPath(sp, sw);
  }

  // ── Catmull-Rom cubic bezier path (pencil / marker / eraser) ─────────────

  void _renderBezier(
    Canvas canvas,
    Size size,
    DrawStroke stroke,
    Paint paint,
    _Tool tool,
  ) {
    final pts = stroke.points;
    if (pts.isEmpty) return;

    double widthFactor = 1.0;
    StrokeCap cap = StrokeCap.round;
    StrokeJoin join = StrokeJoin.round;

    if (!stroke.isEraser) {
      switch (tool) {
        case _Tool.pencil:
          widthFactor = 0.65;
        case _Tool.marker:
          widthFactor = 1.3;
          cap = StrokeCap.butt;
          join = StrokeJoin.bevel;
        default:
          break;
      }
    }

    final sw = stroke.strokeWidth * (size.width / 500.0) * widthFactor;
    paint
      ..strokeWidth = sw
      ..strokeCap = cap
      ..strokeJoin = join
      ..style = PaintingStyle.stroke;

    if (pts.length == 1) {
      canvas.drawCircle(
        pts.first.toOffset(size),
        sw / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }

    // Catmull-Rom → cubic bezier (passes through every input point)
    final path = Path()..moveTo(pts[0].x * size.width, pts[0].y * size.height);

    for (int i = 0; i < pts.length - 1; i++) {
      final p0 = pts[i > 0 ? i - 1 : 0];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = pts[i < pts.length - 2 ? i + 2 : pts.length - 1];

      final cp1x = p1.x * size.width + (p2.x - p0.x) * size.width / 6;
      final cp1y = p1.y * size.height + (p2.y - p0.y) * size.height / 6;
      final cp2x = p2.x * size.width - (p3.x - p1.x) * size.width / 6;
      final cp2y = p2.y * size.height - (p3.y - p1.y) * size.height / 6;

      path.cubicTo(
        cp1x,
        cp1y,
        cp2x,
        cp2y,
        p2.x * size.width,
        p2.y * size.height,
      );
    }
    canvas.drawPath(path, paint);
  }

  // ── Shape renderer ────────────────────────────────────────────────────────

  void _drawShape(
    Canvas canvas,
    Paint paint,
    DrawShapeType type,
    Offset start,
    Offset end,
    bool filled,
  ) {
    paint.style = filled ? PaintingStyle.fill : PaintingStyle.stroke;
    final rect = Rect.fromPoints(start, end);
    switch (type) {
      case DrawShapeType.line:
        paint.style = PaintingStyle.stroke;
        canvas.drawLine(start, end, paint);
      case DrawShapeType.rect:
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(4)),
          paint,
        );
      case DrawShapeType.circle:
        canvas.drawOval(rect, paint);
      case DrawShapeType.triangle:
        canvas.drawPath(
          Path()
            ..moveTo((start.dx + end.dx) / 2, start.dy)
            ..lineTo(end.dx, end.dy)
            ..lineTo(start.dx, end.dy)
            ..close(),
          paint,
        );
    }
  }

  @override
  // Always repaint: currentPoints is a shared mutable list — length comparisons
  // between old/new painter would read the *same* object and always be equal.
  bool shouldRepaint(_MascotCanvasPainter old) => true;
}

// ── HSV colour-picker dialog ──────────────────────────────────────────────────

class _ColorPickerDialog extends StatefulWidget {
  final Color initial;
  final Color primaryColor;
  const _ColorPickerDialog({required this.initial, required this.primaryColor});

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final t = context.appTheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        LocaleService.current.colorLabel,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Colour preview
          Container(
            height: 52,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.divider),
            ),
          ),
          const SizedBox(height: 16),

          _HsvSlider(
            label: LocaleService.current.hueLabel,
            value: _hsv.hue,
            min: 0,
            max: 360,
            gradientColors: List.generate(
              13,
              (i) => HSVColor.fromAHSV(1, i * 30.0, 1, 1).toColor(),
            ),
            onChanged: (v) => setState(() => _hsv = _hsv.withHue(v)),
          ),
          const SizedBox(height: 10),

          _HsvSlider(
            label: LocaleService.current.saturationLabel,
            value: _hsv.saturation,
            min: 0,
            max: 1,
            gradientColors: [
              HSVColor.fromAHSV(1, _hsv.hue, 0, _hsv.value).toColor(),
              HSVColor.fromAHSV(1, _hsv.hue, 1, _hsv.value).toColor(),
            ],
            onChanged: (v) => setState(() => _hsv = _hsv.withSaturation(v)),
          ),
          const SizedBox(height: 10),

          _HsvSlider(
            label: LocaleService.current.brightnessLabel,
            value: _hsv.value,
            min: 0,
            max: 1,
            gradientColors: [
              Colors.black,
              HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 1).toColor(),
            ],
            onChanged: (v) => setState(() => _hsv = _hsv.withValue(v)),
          ),
          const SizedBox(height: 4),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(LocaleService.current.cancel),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.primaryColor,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () => Navigator.pop(context, color),
          child: Text(LocaleService.current.selectAction),
        ),
      ],
    );
  }
}

// Gradient slider row used inside the colour picker
class _HsvSlider extends StatelessWidget {
  final String label;
  final double value, min, max;
  final List<Color> gradientColors;
  final ValueChanged<double> onChanged;

  const _HsvSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.gradientColors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: t.textMuted),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Gradient track background
                Positioned(
                  left: 12,
                  right: 12,
                  child: Container(
                    height: 18,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      gradient: LinearGradient(colors: gradientColors),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(25),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
                // Transparent slider overlaid
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 18,
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: Colors.white,
                    overlayColor: Colors.white.withAlpha(40),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 11,
                    ),
                  ),
                  child: Slider(
                    value: value,
                    min: min,
                    max: max,
                    onChanged: onChanged,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
