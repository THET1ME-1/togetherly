import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import '../utils/safe_pick.dart';
import '../utils/safe_text.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../utils/share_origin.dart';

import '../models/draw_stroke.dart';
import '../models/pair_data.dart';
import '../models/user_data.dart';
import '../services/analytics_service.dart';
import '../services/canvas_storage_service.dart';
import '../services/canvas_repository.dart';
import '../services/media_service.dart';
import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../widgets/storage_image.dart';


//  Palette

const List<Color> _kPalette = [
  Color(0xFF000000),
  Color(0xFF374151),
  Color(0xFF6B7280),
  Color(0xFFD1D5DB),
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
  Color(0xFF92400E),
  Color(0xFF065F46),
];

const List<Color> _kUserColors = [
  Color(0xFF3B82F6),
  Color(0xFFEC4899),
  Color(0xFF22C55E),
  Color(0xFFF97316),
];

//  DrawScreen

class DrawScreen extends StatefulWidget {
  final UserData userData;
  final PairData pairData;
  final AppTheme theme;

  /// Unique identifier for this canvas (default: 'main').
  final String canvasId;

  /// Human-readable title shown in the top bar.
  final String? canvasName;

  const DrawScreen({
    super.key,
    required this.userData,
    required this.pairData,
    required this.theme,
    this.canvasId = 'main',
    this.canvasName,
  });

  @override
  State<DrawScreen> createState() => _DrawScreenState();
}

class _DrawScreenState extends State<DrawScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const double _kCanvasPad = 16.0;
  // Live cursor throttle. 60ms felt great but produced ~16 writes/sec per
  // drawing user — combined with the partner's snapshot listener that's
  // ~16 reads/sec on the other side. 150ms (~6.6 fps) still feels fluid for
  // a follow-along cursor and roughly halves both reads and writes.
  static const int _liveThrottleMs = 150;
  static const double _kMinScale = 0.2;
  static const double _kMaxScale = 10.0;

  /// Только для загрузки картинок-вставок в Storage (медиа §4). Холст/штрихи —
  /// на PocketBase через [_canvas].
  final MediaService _fb = MediaService();
  final CanvasRepository _canvas = CanvasRepository();
  final GlobalKey _canvasKey = GlobalKey();

  final ValueNotifier<int> _repaintNotifier = ValueNotifier<int>(0);
  final ValueNotifier<List<DrawStroke>> _partnerNotifier =
      ValueNotifier<List<DrawStroke>>([]);

  final List<String> _myStrokeIds = [];
  final List<DrawStroke> _redoStack = [];
  final Map<String, DrawStroke> _pendingLocalStrokes = {};
  final Set<String> _cancelledPendingStrokeIds = {};
  final Map<String, DrawStroke> _partnerLiveMap = {};
  final Map<String, int> _partnerTimestamps = {};
  final Set<int> _activePointers = <int>{};

  List<DrawStroke> _remoteStrokes = [];
  List<DrawStroke> _visibleStrokes = [];
  final List<DrawPoint> _currentPoints = [];

  DrawTool _activeTool = DrawTool.brush;
  Color _activeColor = const Color(0xFF000000);
  double _strokeWidth = 5.0;
  Color _bgColor = Colors.white;

  int _currentColorValue = 0xFF000000;
  double _currentStrokeWidth = 5.0;
  bool _currentIsEraser = false;
  bool _currentIsFilledShape = false;
  DrawShapeType? _currentShapeType;
  bool _isDrawing = false;
  bool _fillShapes = false;

  // ── Image tool ────────────────────────────────────────────────────────────
  String? _selectedImageId;
  DrawStroke? _imgDragBase;
  Offset _imgDragStartPx = Offset.zero;
  double _imgScaleBaseW = 0.5;
  double _imgScaleBaseH = 0.5;
  double _imgScaleBaseRot = 0.0;

  // Hint / onboarding
  bool _showHint = true;
  int _hintStep = 0; // 0=draw, 1=tools, 2=pinch - auto-dismiss

  bool _saving = false;

  // Pan / zoom / rotation
  Size _canvasSize = Size.zero;
  double _scale = 1.0;
  double _canvasRotation = 0.0; // radians
  Offset _canvasOffset = Offset.zero;
  double _baseScale = 1.0;
  double _baseRotation = 0.0;
  Offset _baseOffset = Offset.zero;
  Offset _baseFocalPoint = Offset.zero;
  bool _isZooming = false;
  int? _drawingPointerId;
  int _orderCounter = 0;
  DateTime _lastLivePush = DateTime.fromMillisecondsSinceEpoch(0);

  // Palm tool
  Offset _palmPanStart = Offset.zero;
  Offset _palmBaseOffset = Offset.zero;

  // Toolbar expansion
  bool _toolbarExpanded = false;
  late AnimationController _toolbarAnim;

  // Partner cursor pulse animation
  late AnimationController _pulseAnim;

  StreamSubscription? _strokesSub;
  StreamSubscription? _liveSub;
  StreamSubscription? _canvasMetaSub;
  Timer? _staleTimer;
  Timer? _hintTimer;
  int? _lastClearVersion;

  String get _myUid => widget.userData.uid;
  String get _groupId => widget.pairData.pairId;
  String get _canvasId => widget.canvasId;
  bool get _hasSharedCanvas => _groupId.isNotEmpty;

  bool get _isShapeTool =>
      _activeTool == DrawTool.line ||
      _activeTool == DrawTool.rect ||
      _activeTool == DrawTool.circle ||
      _activeTool == DrawTool.triangle;

  DrawShapeType? get _activeShapeType {
    switch (_activeTool) {
      case DrawTool.line:
        return DrawShapeType.line;
      case DrawTool.rect:
        return DrawShapeType.rect;
      case DrawTool.circle:
        return DrawShapeType.circle;
      case DrawTool.triangle:
        return DrawShapeType.triangle;
      default:
        return null;
    }
  }

  bool get _canUndo => _myStrokeIds.isNotEmpty;
  bool get _canRedo => _redoStack.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _activeColor = widget.pairData.isPaired
        ? _colorForUser(_myUid)
        : const Color(0xFF000000);
    _currentColorValue = _activeColor.toARGB32();

    _toolbarAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );

    _pulseAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _startFirebaseListeners();
    if (!_hasSharedCanvas) _loadSoloStrokes();
    _markPresence(true);
    _scheduleHints();
    unawaited(
      AnalyticsService.instance.logCanvasOpened(shared: _hasSharedCanvas),
    );
  }

  // ── Solo stroke persistence ───────────────────────────────────────────────

  Future<void> _loadSoloStrokes() async {
    final strokes = await CanvasStorageService.instance.loadLocalStrokes(
      _myUid,
      _canvasId,
      groupId: _groupId,
    );
    if (!mounted || strokes.isEmpty) return;
    setState(() {
      _visibleStrokes = List<DrawStroke>.from(strokes)
        ..sort(_compareStrokes);
      // Restore undo history so the user can undo loaded strokes.
      _myStrokeIds
        ..clear()
        ..addAll(strokes.map((s) => s.id));
      if (strokes.isNotEmpty) {
        _orderCounter =
            strokes.map((s) => s.orderIndex).reduce((a, b) => a > b ? a : b) +
                1;
      }
    });
  }

  void _saveSoloStrokes() {
    CanvasStorageService.instance.saveLocalStrokes(
      _myUid,
      _canvasId,
      _visibleStrokes,
      groupId: _groupId,
    );
  }

  //  Thumbnail capture

  /// Saves a PNG thumbnail to [CanvasStorageService] then pops the route.
  Future<void> _captureThumbnailAndExit() async {
    await _captureThumbnail();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _captureThumbnail() async {
    try {
      final boundary =
          _canvasKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      await CanvasStorageService.instance.updatePreview(
        _myUid,
        _canvasId,
        byteData.buffer.asUint8List(),
        groupId: _groupId,
      );
    } catch (e) {
      debugPrint('[Draw] thumbnail error: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _markPresence(false);
    _strokesSub?.cancel();
    _liveSub?.cancel();
    _canvasMetaSub?.cancel();
    _staleTimer?.cancel();
    _hintTimer?.cancel();
    _toolbarAnim.dispose();
    _pulseAnim.dispose();
    _clearLiveStroke();
    _repaintNotifier.dispose();
    _partnerNotifier.dispose();
    super.dispose();
  }

  /// No-op: presence была write-only (нигде не читалась) → при переезде на PB
  /// не переносим (миграция §3). Метод оставлен ради вызовов из lifecycle.
  void _markPresence(bool present) {}

  /// ���������� ��� ��������� ������ ��� ����� ���������� � ���.
  /// ��� ������������� ���������� ����� ����, ��� �������
  /// ���������� PointerUp-������� (������ �����������, ������ � �.�.).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _activePointers.clear();
      _isZooming = false;
      _cancelCurrentGesture();
      _markPresence(false);
    } else if (state == AppLifecycleState.resumed) {
      _markPresence(true);
    }
  }

  void _scheduleHints() {
    _hintTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || !_showHint) return;
      setState(() => _hintStep = 1);
      _hintTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted || !_showHint) return;
        setState(() => _hintStep = 2);
        _hintTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _showHint = false);
        });
      });
    });
  }

  //  Colour helpers

  Color _colorForUser(String uid) {
    final members = widget.pairData.members;
    final idx = members.indexWhere((m) => m.uid == uid);
    if (idx < 0) return _kUserColors.first;
    return _kUserColors[idx % _kUserColors.length];
  }

  //  Snackbar

  void _showMessage(String message, {Color? backgroundColor}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: backgroundColor,
        duration: const Duration(seconds: 3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  //  Firebase listeners

  void _startFirebaseListeners() {
    if (!_hasSharedCanvas) return;

    _strokesSub = _canvas
        .watchStrokes(_groupId, _canvasId)
        .handleError((e) => debugPrint('[Draw] strokes error: $e'))
        .listen(_onRemoteStrokes);

    _liveSub = _canvas
        .watchLive(_groupId, _canvasId, _myUid)
        .handleError((e) => debugPrint('[Draw] live error: $e'))
        .listen(_onLiveStrokes);

    // Мета холста (bgColor + clearVersion + rotation) одной подпиской на запись
    // canvas_meta — все три поля в одном документе.
    _canvasMetaSub = _canvas
        .watchMeta(_groupId, _canvasId)
        .handleError((e) => debugPrint('[Draw] canvasMeta error: $e'))
        .listen(_onCanvasMeta);

    // Safety: ensure listeners don't crash the app if rules are restrictive
    _strokesSub?.onError((e) => debugPrint('[Draw] global strokes error: $e'));

    _staleTimer = Timer.periodic(
      const Duration(seconds: 2),
      _removeStalePartners,
    );
  }

  void _onRemoteStrokes(List<DrawStroke> rawList) {
    if (!mounted) return;

    // CanvasRepository уже отдаёт распарсенные DrawStroke (через fromPb) —
    // копируем перед сортировкой (список из стрима неизменяемый).
    final parsed = List<DrawStroke>.from(rawList);
    parsed.sort(_compareStrokes);
    _remoteStrokes = parsed;

    final remainingPending = Map<String, DrawStroke>.from(_pendingLocalStrokes);
    final updatedMyIds = List<String>.from(_myStrokeIds);

    for (final remote in parsed) {
      final matchKey = remainingPending.entries
          .where((e) => _looksLikeSameStroke(remote, e.value))
          .map((e) => e.key)
          .firstOrNull;
      if (matchKey != null) {
        remainingPending.remove(matchKey);
        for (int i = 0; i < updatedMyIds.length; i++) {
          if (updatedMyIds[i] == matchKey) updatedMyIds[i] = remote.id;
        }
      }
    }

    _pendingLocalStrokes
      ..clear()
      ..addAll(remainingPending);
    _myStrokeIds
      ..clear()
      ..addAll(updatedMyIds);

    if (parsed.isNotEmpty || remainingPending.isNotEmpty) {
      final maxOrder = [
        ...parsed.map((s) => s.orderIndex),
        ...remainingPending.values.map((s) => s.orderIndex),
      ].reduce(math.max);
      _orderCounter = maxOrder + 1;
    }

    setState(() => _visibleStrokes = _composeVisibleStrokes());
  }

  void _onCanvasMeta(CanvasMetaUpdate meta) {
    if (!mounted) return;

    final version = meta.clearVersion;
    if (version != null && _lastClearVersion != version) {
      _lastClearVersion = version;
      _myStrokeIds.clear();
      _redoStack.clear();
      _pendingLocalStrokes.clear();
      _cancelledPendingStrokeIds.clear();
      _remoteStrokes = [];
      _partnerLiveMap.clear();
      _partnerTimestamps.clear();
      _partnerNotifier.value = const [];
      _visibleStrokes = [];
    }

    bool rotationChanged = false;
    final rot = meta.rotationMilliRadians;
    if (rot != null) {
      final remoteRotation = rot / 1000.0;
      if ((_canvasRotation - remoteRotation).abs() >= 0.001) {
        _canvasRotation = remoteRotation;
        rotationChanged = true;
      }
    }

    bool bgChanged = false;
    final bg = meta.bgColor;
    if (bg != null) {
      final next = Color(bg);
      if (next.toARGB32() != _bgColor.toARGB32()) {
        _bgColor = next;
        bgChanged = true;
      }
    }

    if (version != null || rotationChanged || bgChanged) {
      setState(() {});
    }
  }

  void _onLiveStrokes(Map<String, Map<String, dynamic>> liveMap) {
    if (!mounted) return;
    bool changed = false;

    for (final entry in liveMap.entries) {
      final uid = entry.key;
      final data = entry.value;

      if (data.isEmpty) {
        if (_partnerLiveMap.containsKey(uid)) {
          _partnerLiveMap.remove(uid);
          _partnerTimestamps.remove(uid);
          changed = true;
        }
        continue;
      }

      try {
        final stroke = DrawStroke.fromLiveMap(data, uid);
        _partnerLiveMap[uid] = stroke;
        _partnerTimestamps[uid] =
            (data['ts'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch;
        _partnerNotifier.value = List.of(_partnerLiveMap.values);
        changed = true;
      } catch (e) {
        debugPrint('[Draw] parse live error: $e');
      }
    }

    final missing = _partnerLiveMap.keys
        .where((uid) => !liveMap.containsKey(uid))
        .toList();
    if (missing.isNotEmpty) {
      for (final uid in missing) {
        _partnerLiveMap.remove(uid);
        _partnerTimestamps.remove(uid);
      }
      _partnerNotifier.value = List.of(_partnerLiveMap.values);
      changed = true;
    }

    if (changed && mounted) setState(() {});
  }

  void _removeStalePartners(Timer _) {
    if (!mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final stale = _partnerTimestamps.entries
        .where((e) => now - e.value > 4000)
        .map((e) => e.key)
        .toList();
    if (stale.isEmpty) return;
    for (final uid in stale) {
      _partnerLiveMap.remove(uid);
      _partnerTimestamps.remove(uid);
    }
    _partnerNotifier.value = List.of(_partnerLiveMap.values);
    setState(() {});
  }

  //  Stroke helpers

  int _compareStrokes(DrawStroke a, DrawStroke b) {
    final o = a.orderIndex.compareTo(b.orderIndex);
    if (o != 0) return o;
    // Стабильный тай-брейкер по userId: id у локального optimistic-штриха
    // отличается от id, который вернёт Firestore, и при коллизии orderIndex
    // между двумя рисующими порядок слоёв «прыгал» после подтверждения записи.
    final u = a.userId.compareTo(b.userId);
    return u != 0 ? u : a.id.compareTo(b.id);
  }

  List<DrawStroke> _composeVisibleStrokes() {
    final combined = <DrawStroke>[
      ..._remoteStrokes,
      ..._pendingLocalStrokes.values,
    ];
    combined.sort(_compareStrokes);
    return combined;
  }

  bool _looksLikeSameStroke(DrawStroke remote, DrawStroke local) {
    if (remote.userId != local.userId) return false;
    if (remote.orderIndex != local.orderIndex) return false;
    if (remote.colorValue != local.colorValue) return false;
    if ((remote.strokeWidth - local.strokeWidth).abs() > 0.01) return false;
    if (remote.isEraser != local.isEraser) return false;
    if (remote.shapeType != local.shapeType) return false;
    if (remote.isImageStroke != local.isImageStroke) return false;

    if (remote.isImageStroke) {
      // Match by userId + orderIndex only — URL changes after upload, position changes on drag
      return true;
    }

    if (remote.points.length != local.points.length) return false;
    if (remote.points.isEmpty) return true;

    final rf = remote.points.first;
    final lf = local.points.first;
    final rl = remote.points.last;
    final ll = local.points.last;
    return (rf.x - lf.x).abs() < 0.0001 &&
        (rf.y - lf.y).abs() < 0.0001 &&
        (rl.x - ll.x).abs() < 0.0001 &&
        (rl.y - ll.y).abs() < 0.0001;
  }

  //  Coordinate transforms

  /// Rotates [o] by [angle] radians around the origin.
  Offset _rotateOffset(Offset o, double angle) {
    final cos = math.cos(angle);
    final sin = math.sin(angle);
    return Offset(o.dx * cos - o.dy * sin, o.dx * sin + o.dy * cos);
  }

  /// Converts a screen-local point to canvas coordinates,
  /// accounting for pan, rotation, and scale.
  Offset _screenToCanvas(Offset localPoint) {
    final translated = localPoint - _canvasOffset;
    final rotated = _rotateOffset(translated, -_canvasRotation);
    return rotated / _scale;
  }

  //  Tool selection

  void _selectTool(DrawTool tool) {
    _cancelCurrentGesture();
    setState(() {
      _activeTool = tool;
      if (tool != DrawTool.image) _selectedImageId = null;
    });
    if (_showHint) setState(() => _showHint = false);
  }

  void _cancelCurrentGesture() {
    final had = _isDrawing || _currentPoints.isNotEmpty;
    _isDrawing = false;
    _drawingPointerId = null;
    _currentShapeType = null;
    _currentPoints.clear();
    if (had) {
      _clearLiveStroke();
      _repaintNotifier.value++;
    }
  }

  //  Drawing gestures

  void _startStroke(Offset localPoint) {
    if (_canvasSize.isEmpty) return;

    if (_activeTool == DrawTool.fill) {
      _applyFill(localPoint);
      return;
    }

    _redoStack.clear();
    _lastLivePush = DateTime.fromMillisecondsSinceEpoch(0);
    _lastPushedPointsCount = 0;
    _lastPushedTipX = double.nan;
    _lastPushedTipY = double.nan;
    if (_showHint) setState(() => _showHint = false);

    if (_isShapeTool) {
      final pt = DrawPoint.fromOffset(_screenToCanvas(localPoint), _canvasSize);
      setState(() {
        _currentPoints
          ..clear()
          ..add(pt)
          ..add(pt);
        _currentShapeType = _activeShapeType;
        _currentColorValue = _activeColor.toARGB32();
        _currentStrokeWidth = _strokeWidth;
        _currentIsEraser = false;
        _currentIsFilledShape = _fillShapes;
        _isDrawing = true;
      });
      _repaintNotifier.value++;
      return;
    }

    setState(() {
      _currentPoints
        ..clear()
        ..add(DrawPoint.fromOffset(_screenToCanvas(localPoint), _canvasSize));
      _currentShapeType = null;
      _currentColorValue = _activeTool == DrawTool.eraser
          ? _bgColor.toARGB32()
          : _activeColor.toARGB32();
      _currentStrokeWidth = _strokeWidth;
      _currentIsEraser = _activeTool == DrawTool.eraser;
      _currentIsFilledShape = false;
      _isDrawing = true;
    });
    _repaintNotifier.value++;
  }

  void _updateStroke(Offset localPoint) {
    if (!_isDrawing || _canvasSize.isEmpty) return;
    if (_currentShapeType != null) {
      final end = DrawPoint.fromOffset(
        _screenToCanvas(localPoint),
        _canvasSize,
      );
      if (_currentPoints.length >= 2) {
        _currentPoints[1] = end;
      } else {
        _currentPoints.add(end);
      }
    } else {
      _currentPoints.add(
        DrawPoint.fromOffset(_screenToCanvas(localPoint), _canvasSize),
      );
    }
    _repaintNotifier.value++;
    _pushLiveStrokeIfNeeded();
  }

  void _finishStroke() {
    if (!_isDrawing) return;
    _isDrawing = false;
    _drawingPointerId = null;
    _commitCurrentStroke();
  }

  void _pushLiveStrokeIfNeeded() {
    final now = DateTime.now();
    if (now.difference(_lastLivePush).inMilliseconds >= _liveThrottleMs) {
      _lastLivePush = now;
      unawaited(_pushLiveStrokeAsync());
    }
  }

  int _lastPushedPointsCount = 0;
  double _lastPushedTipX = double.nan;
  double _lastPushedTipY = double.nan;

  Future<void> _pushLiveStrokeAsync() async {
    if (!_hasSharedCanvas || _currentPoints.isEmpty) return;
    // Skip the write if the stroke is identical to the last one we pushed.
    // For freehand strokes the point count grows, for shape tools the count
    // stays at 2 but the endpoint moves — both cases need to be covered.
    final tip = _currentPoints.last;
    if (_currentPoints.length == _lastPushedPointsCount &&
        tip.x == _lastPushedTipX &&
        tip.y == _lastPushedTipY) {
      return;
    }
    _lastPushedPointsCount = _currentPoints.length;
    _lastPushedTipX = tip.x;
    _lastPushedTipY = tip.y;

    final stroke = DrawStroke(
      id: 'live_$_myUid',
      userId: _myUid,
      colorValue: _currentColorValue,
      strokeWidth: _currentStrokeWidth,
      points: List<DrawPoint>.unmodifiable(_currentPoints),
      isEraser: _currentIsEraser,
      isFilledShape: _currentIsFilledShape,
      shapeType: _currentShapeType,
      orderIndex: -1,
    );
    try {
      await _canvas.setLive(_groupId, _canvasId, _myUid, stroke.toLiveMap());
    } catch (e) {
      debugPrint('[Draw] live push error: $e');
    }
  }

  void _clearLiveStroke() {
    if (!_hasSharedCanvas) return;
    _canvas
        .clearLive(_groupId, _canvasId, _myUid)
        .catchError((e) => debugPrint('[Draw] clear live error: $e'));
  }

  void _onPointerDown(PointerDownEvent event) {
    // ���� ����� ����� �������� � Set ��� �������� �������, ��
    // ����� ����� �������� � ��� ������� ������������ PointerUp
    // (�����������, ������). ������� ��������� �����.
    if (_activePointers.isEmpty) {
      _isZooming = false;
      if (_isDrawing) _cancelCurrentGesture();
    }

    _activePointers.add(event.pointer);

    if (_activePointers.length >= 2) {
      _isZooming = false; // ����� ����������� onScaleStart
      _cancelCurrentGesture();
      return;
    }

    // ���� ����� � ������������� ���������� zoom, ���� �� �����
    _isZooming = false;

    // Palm tool
    if (_activeTool == DrawTool.palm) {
      _palmPanStart = event.localPosition;
      _palmBaseOffset = _canvasOffset;
      return;
    }

    // Image tool
    if (_activeTool == DrawTool.image) {
      final hit = _findImageAt(event.localPosition);
      if (hit != null) {
        // Tapped on an image — select and prepare for drag
        setState(() => _selectedImageId = hit.id);
        _imgDragBase = hit;
        _imgDragStartPx = _screenToCanvas(event.localPosition);
      } else {
        // Tapped on empty space — keep selection so pinch still works
        _imgDragBase = null;
      }
      return;
    }

    _drawingPointerId = event.pointer;
    _startStroke(event.localPosition);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_isZooming || _activePointers.length != 1) return;

    // Palm tool
    if (_activeTool == DrawTool.palm) {
      final delta = event.localPosition - _palmPanStart;
      setState(() => _canvasOffset = _palmBaseOffset + delta);
      return;
    }

    // Image drag
    if (_activeTool == DrawTool.image &&
        _imgDragBase != null &&
        _selectedImageId != null &&
        !_canvasSize.isEmpty) {
      final canvasPx = _screenToCanvas(event.localPosition);
      final delta = canvasPx - _imgDragStartPx;
      final newX = (_imgDragBase!.imageX ?? 0.5) + delta.dx / _canvasSize.width;
      final newY =
          (_imgDragBase!.imageY ?? 0.5) + delta.dy / _canvasSize.height;
      _applyImageUpdate(_copyImageStroke(_imgDragBase!, x: newX, y: newY));
      return;
    }

    if (_drawingPointerId != event.pointer) return;
    _updateStroke(event.localPosition);
  }

  void _onPointerUp(PointerEvent event) {
    final wasDrawing = _drawingPointerId == event.pointer;
    _activePointers.remove(event.pointer);

    if (wasDrawing && !_isZooming) {
      _finishStroke();
    }

    if (_activePointers.isEmpty) {
      _drawingPointerId = null;
      _isZooming = false;
      if (_isDrawing) _cancelCurrentGesture();
      // Sync image position to Firestore when drag ends
      if (_activeTool == DrawTool.image && _imgDragBase != null) {
        final img = _findImageById(_selectedImageId ?? '');
        if (img != null) unawaited(_syncImageToFirestore(img));
        _imgDragBase = null;
      }
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (details.pointerCount < 2) return;
    _isZooming = true;
    _cancelCurrentGesture();
    _baseScale = _scale;
    _baseOffset = _canvasOffset;
    _baseFocalPoint = details.localFocalPoint;
    _baseRotation = _canvasRotation;
    // Save image base transform for pinch on selected image
    if (_activeTool == DrawTool.image && _selectedImageId != null) {
      final img = _findImageById(_selectedImageId!);
      if (img != null) {
        _imgDragBase = img;
        _imgScaleBaseW = img.imageWidth ?? 0.5;
        _imgScaleBaseH = img.imageHeight ?? 0.5;
        _imgScaleBaseRot = img.imageRotation ?? 0.0;
      }
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (!_isZooming && details.pointerCount < 2) return;
    _isZooming = true;

    // Image pinch: scale + rotate the selected image
    if (_activeTool == DrawTool.image &&
        _imgDragBase != null &&
        _selectedImageId != null) {
      final newW = (_imgScaleBaseW * details.scale).clamp(0.05, 2.0);
      final newH = (_imgScaleBaseH * details.scale).clamp(0.05, 2.0);
      final newRot = _imgScaleBaseRot + details.rotation;
      _applyImageUpdate(
        _copyImageStroke(_imgDragBase!, w: newW, h: newH, rot: newRot),
      );
      return;
    }

    final nextScale = (_baseScale * details.scale).clamp(
      _kMinScale,
      _kMaxScale,
    );
    final nextRotation = _baseRotation + details.rotation;
    final focalCanvas = _rotateOffset(
      (_baseFocalPoint - _baseOffset) / _baseScale,
      -_baseRotation,
    );
    final nextOffset =
        details.localFocalPoint -
        _rotateOffset(focalCanvas * nextScale, nextRotation);
    setState(() {
      _scale = nextScale;
      _canvasRotation = nextRotation;
      _canvasOffset = nextOffset;
    });
  }

  void _onScaleEnd(ScaleEndDetails _) {
    _isZooming = false;
    // Sync image transform to Firestore after pinch ends
    if (_activeTool == DrawTool.image && _imgDragBase != null) {
      final img = _findImageById(_selectedImageId ?? '');
      if (img != null) unawaited(_syncImageToFirestore(img));
      _imgDragBase = null;
    }
    if (_activePointers.isEmpty) {
      _drawingPointerId = null;
      if (_isDrawing) _cancelCurrentGesture();
    }

    if (_hasSharedCanvas) {
      unawaited(
        _canvas.setRotation(
            _groupId, _canvasId, (_canvasRotation * 1000).round()),
      );
    }
  }

  void _resetZoom() {
    setState(() {
      _scale = 1.0;
      _canvasOffset = Offset.zero;
      _canvasRotation = 0.0;
    });
  }

  // ── Image helpers ──────────────────────────────────────────────────────────

  DrawStroke? _findImageAt(Offset screenPos) {
    if (_canvasSize.isEmpty) return null;
    final cp = _screenToCanvas(screenPos);
    final nx = cp.dx / _canvasSize.width;
    final ny = cp.dy / _canvasSize.height;
    for (final s in _visibleStrokes.reversed) {
      if (!s.isImageStroke) continue;
      final cx = s.imageX ?? 0.5;
      final cy = s.imageY ?? 0.5;
      final hw = (s.imageWidth ?? 0.5) / 2;
      final hh = (s.imageHeight ?? 0.5) / 2;
      if (nx >= cx - hw && nx <= cx + hw && ny >= cy - hh && ny <= cy + hh) {
        return s;
      }
    }
    return null;
  }

  DrawStroke? _findImageById(String id) =>
      _visibleStrokes.where((s) => s.id == id).firstOrNull;

  DrawStroke _copyImageStroke(
    DrawStroke s, {
    double? x,
    double? y,
    double? w,
    double? h,
    double? rot,
    String? url,
  }) => DrawStroke(
    id: s.id,
    userId: s.userId,
    colorValue: s.colorValue,
    strokeWidth: s.strokeWidth,
    points: s.points,
    orderIndex: s.orderIndex,
    imageUrl: url ?? s.imageUrl,
    imageX: x ?? s.imageX,
    imageY: y ?? s.imageY,
    imageWidth: w ?? s.imageWidth,
    imageHeight: h ?? s.imageHeight,
    imageRotation: rot ?? s.imageRotation,
  );

  void _applyImageUpdate(DrawStroke updated) {
    final id = updated.id;
    if (_pendingLocalStrokes.containsKey(id)) {
      _pendingLocalStrokes[id] = updated;
      setState(() => _visibleStrokes = _composeVisibleStrokes());
      return;
    }
    final ri = _remoteStrokes.indexWhere((s) => s.id == id);
    if (ri >= 0) {
      _remoteStrokes[ri] = updated;
      setState(() => _visibleStrokes = _composeVisibleStrokes());
      return;
    }
    // Solo canvas
    setState(() {
      final vi = _visibleStrokes.indexWhere((s) => s.id == id);
      if (vi >= 0) _visibleStrokes[vi] = updated;
    });
  }

  Future<void> _syncImageToFirestore(DrawStroke stroke) async {
    if (!_hasSharedCanvas) return;
    if (!_remoteStrokes.any((s) => s.id == stroke.id)) return;
    try {
      await _canvas.patchStroke(stroke.id, {
        'imageX': stroke.imageX,
        'imageY': stroke.imageY,
        'imageWidth': stroke.imageWidth,
        'imageHeight': stroke.imageHeight,
        'imageRotation': stroke.imageRotation,
      });
    } catch (e) {
      debugPrint('[Draw] image sync error: $e');
    }
  }

  Future<void> _pickAndAddImage() async {
    final picker = ImagePicker();
    final xFile = await safePick(
      () => picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      ),
    );
    if (xFile == null || !mounted) return;

    final id = 'img_${DateTime.now().millisecondsSinceEpoch}_$_orderCounter';
    final stroke = DrawStroke(
      id: id,
      userId: _myUid,
      colorValue: 0xFF000000,
      strokeWidth: 0,
      points: const [],
      orderIndex: _orderCounter,
      imageUrl: 'file://${xFile.path}',
      imageX: 0.5,
      imageY: 0.5,
      imageWidth: 0.5,
      imageHeight: 0.5,
      imageRotation: 0.0,
    );
    _orderCounter++;
    setState(() {
      _selectedImageId = id;
      _activeTool = DrawTool.image;
    });

    if (!_hasSharedCanvas) {
      // Соло-холст: локальный file:// путь рисует только это устройство — ок.
      _submitStroke(stroke);
      return;
    }

    // Общий холст: показываем картинку себе сразу (file://), но в Firestore
    // локальный путь НЕ пишем — партнёр его не откроет. Сначала грузим файл в
    // Storage и только с готовым сетевым URL коммитим штрих, чтобы партнёр тоже
    // увидел картинку, а не «битый файл».
    setState(() {
      _pendingLocalStrokes[id] = stroke;
      _visibleStrokes = _composeVisibleStrokes();
    });
    _myStrokeIds.add(id);
    unawaited(_uploadImageAsync(id, xFile.path));
  }

  Future<void> _uploadImageAsync(String localStrokeId, String localPath) async {
    final ext = localPath.split('.').last.toLowerCase();
    final dest = 'canvas/$_groupId/$_canvasId/$localStrokeId.$ext';
    final url = await _fb.uploadFile(localPath, dest);
    if (!mounted) return;

    // Штрих могли отменить/удалить, пока шла загрузка — тогда ничего не коммитим.
    final pending = _pendingLocalStrokes[localStrokeId];
    if (pending == null) return;

    if (url == null) {
      // Загрузка не удалась — убираем оптимистичный штрих и историю undo.
      debugPrint('[Draw] image upload failed, dropping stroke $localStrokeId');
      _cancelledPendingStrokeIds.remove(localStrokeId);
      _myStrokeIds.remove(localStrokeId);
      setState(() {
        _pendingLocalStrokes.remove(localStrokeId);
        if (_selectedImageId == localStrokeId) _selectedImageId = null;
        _visibleStrokes = _composeVisibleStrokes();
      });
      return;
    }

    // Подменяем file:// на сетевой URL (берём актуальный pending — вдруг штрих
    // двигали во время загрузки) и коммитим штрих в Firestore уже с ним.
    final networked = _copyImageStroke(pending, url: url);
    setState(() {
      _pendingLocalStrokes[localStrokeId] = networked;
      _visibleStrokes = _composeVisibleStrokes();
    });
    _commitImageStroke(localStrokeId, networked);
  }

  /// Записать картинку-штрих в Firestore (с уже сетевым URL). Повторяет логику
  /// сверки optimistic-штриха из [_submitStroke]: при ошибке откатывает локально,
  /// при отмене во время записи — удаляет уже созданный документ.
  void _commitImageStroke(String localId, DrawStroke stroke) {
    _canvas
        .addStroke(_groupId, _canvasId, stroke.toFirestore())
        .then((remoteId) async {
          if (remoteId.isEmpty) throw Exception('Empty stroke id');
          if (_cancelledPendingStrokeIds.remove(localId)) {
            await _canvas.deleteStroke(remoteId);
          }
        })
        .catchError((e) {
          debugPrint('[Draw] image commit error: $e');
          if (!mounted) return;
          _myStrokeIds.remove(localId);
          setState(() {
            _pendingLocalStrokes.remove(localId);
            _visibleStrokes = _composeVisibleStrokes();
          });
        });
  }

  //  Commit stroke

  void _commitCurrentStroke() {
    final shapeType = _currentShapeType;

    if (shapeType != null) {
      if (_currentPoints.length < 2 ||
          (_currentPoints[0].x == _currentPoints[1].x &&
              _currentPoints[0].y == _currentPoints[1].y)) {
        _currentPoints.clear();
        _currentShapeType = null;
        _clearLiveStroke();
        _repaintNotifier.value++;
        return;
      }
    } else if (_currentPoints.length < 2) {
      if (_currentPoints.length == 1 && !_currentIsEraser) {
        _currentPoints.add(_currentPoints.first);
      } else {
        _currentPoints.clear();
        _currentShapeType = null;
        _clearLiveStroke();
        _repaintNotifier.value++;
        return;
      }
    }

    final stroke = DrawStroke(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}_$_orderCounter',
      userId: _myUid,
      colorValue: _currentColorValue,
      strokeWidth: _currentStrokeWidth,
      points: List<DrawPoint>.unmodifiable(_currentPoints),
      isEraser: _currentIsEraser,
      isFilledShape: _currentIsFilledShape,
      shapeType: shapeType,
      orderIndex: _orderCounter,
    );

    _currentPoints.clear();
    _currentShapeType = null;
    _clearLiveStroke();
    _repaintNotifier.value++;
    _orderCounter++;
    _submitStroke(stroke);
  }

  void _submitStroke(DrawStroke stroke) {
    if (!_hasSharedCanvas) {
      setState(() {
        _visibleStrokes = [..._visibleStrokes, stroke]..sort(_compareStrokes);
      });
      _myStrokeIds.add(stroke.id);
      _saveSoloStrokes();
      return;
    }

    setState(() {
      _pendingLocalStrokes[stroke.id] = stroke;
      _visibleStrokes = _composeVisibleStrokes();
    });
    _myStrokeIds.add(stroke.id);

    _canvas
        .addStroke(_groupId, _canvasId, stroke.toFirestore())
        .then((remoteId) async {
          if (remoteId.isEmpty) throw Exception('Empty stroke id');
          if (_cancelledPendingStrokeIds.remove(stroke.id)) {
            await _canvas.deleteStroke(remoteId);
          }
        })
        .catchError((e) {
          debugPrint('[Draw] commit error: $e');
          if (!mounted) return;
          setState(() {
            _pendingLocalStrokes.remove(stroke.id);
            _visibleStrokes = _composeVisibleStrokes();
          });
          _myStrokeIds.remove(stroke.id);
        });
  }

  //  Undo / Redo

  Future<void> _undo() async {
    if (_myStrokeIds.isEmpty) return;
    final undoKey = _myStrokeIds.removeLast();

    DrawStroke? removed;
    String? remoteIdForDelete;

    if (_pendingLocalStrokes.containsKey(undoKey)) {
      removed = _pendingLocalStrokes.remove(undoKey);
      _cancelledPendingStrokeIds.add(undoKey);
    } else {
      removed = _visibleStrokes.where((s) => s.id == undoKey).firstOrNull;
      if (removed != null && _hasSharedCanvas) {
        _remoteStrokes = _remoteStrokes.where((s) => s.id != undoKey).toList();
        remoteIdForDelete = undoKey;
      }
    }

    if (removed == null) return;
    _redoStack.add(removed);

    if (_hasSharedCanvas) {
      setState(() => _visibleStrokes = _composeVisibleStrokes());
    } else {
      // Solo: strokes live directly in _visibleStrokes, not in remote/pending
      setState(() {
        _visibleStrokes = _visibleStrokes
            .where((s) => s.id != undoKey)
            .toList();
      });
      _saveSoloStrokes();
    }

    if (!_hasSharedCanvas || remoteIdForDelete == null) return;

    try {
      await _canvas.deleteStroke(remoteIdForDelete);
    } catch (e) {
      debugPrint('[Draw] undo error: $e');
      if (!mounted) return;
      _myStrokeIds.add(undoKey);
      _redoStack.removeLast();
      setState(() {
        _remoteStrokes = [..._remoteStrokes, removed!]..sort(_compareStrokes);
        _visibleStrokes = _composeVisibleStrokes();
      });
    }
  }

  Future<void> _redo() async {
    if (_redoStack.isEmpty) return;
    final base = _redoStack.removeLast();
    final stroke = DrawStroke(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}_$_orderCounter',
      userId: _myUid,
      colorValue: base.colorValue,
      strokeWidth: base.strokeWidth,
      points: List<DrawPoint>.unmodifiable(base.points),
      isEraser: base.isEraser,
      isFilledShape: base.isFilledShape,
      shapeType: base.shapeType,
      orderIndex: _orderCounter,
      imageUrl: base.imageUrl,
      imageX: base.imageX,
      imageY: base.imageY,
      imageWidth: base.imageWidth,
      imageHeight: base.imageHeight,
      imageRotation: base.imageRotation,
    );
    _orderCounter++;
    _submitStroke(stroke);
  }

  Future<void> _deleteSelectedImage() async {
    if (_selectedImageId == null) return;
    final id = _selectedImageId!;

    // Pending stroke (Firebase not yet confirmed)
    if (_pendingLocalStrokes.containsKey(id)) {
      _pendingLocalStrokes.remove(id);
      _cancelledPendingStrokeIds.add(id);
      _myStrokeIds.remove(id);
      setState(() {
        _selectedImageId = null;
        _visibleStrokes = _composeVisibleStrokes();
      });
      return;
    }

    final removed = _visibleStrokes.where((s) => s.id == id).firstOrNull;
    if (removed == null) {
      setState(() => _selectedImageId = null);
      return;
    }

    _myStrokeIds.remove(id);

    if (!_hasSharedCanvas) {
      setState(() {
        _selectedImageId = null;
        _visibleStrokes = _visibleStrokes.where((s) => s.id != id).toList();
      });
      _saveSoloStrokes();
      return;
    }

    _remoteStrokes = _remoteStrokes.where((s) => s.id != id).toList();
    setState(() {
      _selectedImageId = null;
      _visibleStrokes = _composeVisibleStrokes();
    });

    try {
      await _canvas.deleteStroke(id);
    } catch (e) {
      debugPrint('[Draw] deleteImage error: $e');
      if (!mounted) return;
      _remoteStrokes = [..._remoteStrokes, removed]..sort(_compareStrokes);
      _myStrokeIds.add(id);
      setState(() {
        _selectedImageId = id;
        _visibleStrokes = _composeVisibleStrokes();
      });
    }
  }

  //  Fill / Clear

  void _applyFill(Offset localPoint) {
    _cancelCurrentGesture();

    // 1. Convert local point to canvas coordinates (0..1)
    final canvasPt = DrawPoint.fromOffset(
      _screenToCanvas(localPoint),
      _canvasSize,
    );

    // 2. Search for a shape that contains this point (from top to bottom)
    DrawStroke? hitShape;
    for (final s in _visibleStrokes.reversed) {
      if (s.shapeType == null || s.points.length < 2) continue;

      final first = s.points.first;
      final last = s.points.last;

      if (s.shapeType == DrawShapeType.rect) {
        final minX = math.min(first.x, last.x);
        final maxX = math.max(first.x, last.x);
        final minY = math.min(first.y, last.y);
        final maxY = math.max(first.y, last.y);
        if (canvasPt.x >= minX &&
            canvasPt.x <= maxX &&
            canvasPt.y >= minY &&
            canvasPt.y <= maxY) {
          hitShape = s;
          break;
        }
      } else if (s.shapeType == DrawShapeType.circle) {
        final minX = math.min(first.x, last.x);
        final maxX = math.max(first.x, last.x);
        final minY = math.min(first.y, last.y);
        final maxY = math.max(first.y, last.y);
        final rx = (maxX - minX) / 2;
        final ry = (maxY - minY) / 2;
        if (rx <= 0 || ry <= 0) continue;

        final cx = (minX + maxX) / 2;
        final cy = (minY + maxY) / 2;
        final nx = (canvasPt.x - cx) / rx;
        final ny = (canvasPt.y - cy) / ry;
        if (nx * nx + ny * ny <= 1) {
          hitShape = s;
          break;
        }
      } else if (s.shapeType == DrawShapeType.triangle) {
        final v1 = DrawPoint((first.x + last.x) / 2, first.y);
        final v2 = DrawPoint(first.x, last.y);
        final v3 = DrawPoint(last.x, last.y);

        bool sameSide(DrawPoint p1, DrawPoint p2, DrawPoint a, DrawPoint b) {
          final cp1 = (b.x - a.x) * (p1.y - a.y) - (b.y - a.y) * (p1.x - a.x);
          final cp2 = (b.x - a.x) * (p2.y - a.y) - (b.y - a.y) * (p2.x - a.x);
          return (cp1 * cp2) >= 0;
        }

        if (sameSide(canvasPt, v1, v2, v3) &&
            sameSide(canvasPt, v2, v1, v3) &&
            sameSide(canvasPt, v3, v1, v2)) {
          hitShape = s;
          break;
        }
      }
    }

    final nextColor = _activeColor;

    if (hitShape != null) {
      // Create a filled duplicate of the hit shape
      final newStroke = DrawStroke(
        id: 'local_${DateTime.now().millisecondsSinceEpoch}_$_orderCounter',
        userId: _myUid,
        colorValue: nextColor.toARGB32(),
        strokeWidth: hitShape.strokeWidth,
        points: List<DrawPoint>.from(hitShape.points),
        isEraser: false,
        isFilledShape: true,
        shapeType: hitShape.shapeType,
        orderIndex: _orderCounter,
      );
      _orderCounter++;
      _submitStroke(newStroke);
      return;
    }

    // Fallback: fill the entire background
    setState(() => _bgColor = nextColor);
    if (_hasSharedCanvas) {
      _canvas
          .setBgColor(_groupId, _canvasId, nextColor.toARGB32())
          .catchError((e) => debugPrint('[Draw] fill error: $e'));
    }
  }

  Future<void> _confirmClear() async {
    final s = LocaleService.current;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(s.clearCanvas),
        content: Text(s.clearCanvasConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
            child: Text(s.clearCanvas),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final prevVisible = List<DrawStroke>.from(_visibleStrokes);
    final prevRemote = List<DrawStroke>.from(_remoteStrokes);
    final prevPending = Map<String, DrawStroke>.from(_pendingLocalStrokes);
    final prevBg = _bgColor;

    _myStrokeIds.clear();
    _redoStack.clear();
    _pendingLocalStrokes.clear();
    _remoteStrokes = [];
    setState(() {
      _visibleStrokes = [];
      _bgColor = Colors.white;
    });

    if (!_hasSharedCanvas) {
      _saveSoloStrokes();
      return;
    }

    try {
      // clearCanvas разом чистит штрихи + live-курсоры и пишет clear_version +
      // bg в canvas_meta (паритет с прежними двумя вызовами).
      await _canvas.clear(
        _groupId,
        _canvasId,
        clearVersion: DateTime.now().millisecondsSinceEpoch,
        bgColor: Colors.white.toARGB32(),
      );
    } catch (e) {
      debugPrint('[Draw] clear error: $e');
      if (!mounted) return;
      _remoteStrokes = prevRemote;
      _pendingLocalStrokes
        ..clear()
        ..addAll(prevPending);
      setState(() {
        _visibleStrokes = prevVisible;
        _bgColor = prevBg;
      });
    }
  }

  //  Save / Share

  Future<Directory> _resolveSaveDirectory() async {
    if (Platform.isAndroid) {
      final d = Directory('/storage/emulated/0/Download');
      if (await d.exists()) return d;
    }
    return getApplicationDocumentsDirectory();
  }

  Future<void> _saveOrShare({required bool share}) async {
    if (_saving) return;
    final s = LocaleService.current;
    // iPad-поповер: origin считаем до async-gap, пока context жив.
    final shareOrigin = shareOriginFromContext(context);
    setState(() => _saving = true);
    try {
      final boundary =
          _canvasKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;

      final image = await boundary.toImage(pixelRatio: 2.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final bytes = byteData.buffer.asUint8List();
      final name = 'drawing_${DateTime.now().millisecondsSinceEpoch}.png';

      if (share) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/$name');
        await file.writeAsBytes(bytes, flush: true);
        await Share.shareXFiles(
          [XFile(file.path)],
          text: ' ${s.drawTogether}',
          sharePositionOrigin: shareOrigin,
        );
      } else {
        final dir = await _resolveSaveDirectory();
        if (!await dir.exists()) await dir.create(recursive: true);
        final file = File('${dir.path}/$name');
        await file.writeAsBytes(bytes, flush: true);
        _showMessage(s.drawingSavedTo(file.path));
      }
    } catch (e) {
      debugPrint('[Draw] save/share error: $e');
      _showMessage(
        share ? s.failedToShareDrawing : s.failedToSaveDrawing,
        backgroundColor: Colors.red.shade700,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  //  Bottom sheet pickers

  void _showThicknessPicker() {
    double temp = _strokeWidth;
    showModalBottomSheet(
      context: context,
      backgroundColor: widget.theme.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, ss) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: widget.theme.divider,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  LocaleService.current.strokeThickness,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(Icons.brush, size: 16, color: widget.theme.textMuted),
                    Expanded(
                      child: Slider(
                        value: temp,
                        min: 1,
                        max: 40,
                        divisions: 39,
                        activeColor: _activeColor,
                        onChanged: (v) {
                          ss(() => temp = v);
                          setState(() => _strokeWidth = v);
                        },
                      ),
                    ),
                    Icon(Icons.brush, size: 28, color: widget.theme.textMuted),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [2.0, 5.0, 10.0, 20.0, 35.0].map((w) {
                    final sel = (temp - w).abs() < 0.1;
                    return GestureDetector(
                      onTap: () {
                        ss(() => temp = w);
                        setState(() => _strokeWidth = w);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: sel
                              ? _activeColor.withValues(alpha: 0.1)
                              : widget.theme.surfaceMuted,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: sel ? _activeColor : widget.theme.divider,
                            width: sel ? 2 : 1,
                          ),
                        ),
                        child: Center(
                          child: Container(
                            width: w.clamp(2.0, 30.0),
                            height: w.clamp(2.0, 30.0),
                            decoration: BoxDecoration(
                              color: _activeColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showColorPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: widget.theme.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: widget.theme.divider,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                LocaleService.current.brush,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 10,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: _kPalette.length,
                itemBuilder: (_, i) {
                  final c = _kPalette[i];
                  final sel = c.toARGB32() == _activeColor.toARGB32();
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _activeColor = c;
                        _currentColorValue = c.toARGB32();
                      });
                      Navigator.pop(ctx);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: sel
                              ? widget.theme.primary
                              : (c == Colors.white
                                    ? Colors.grey.shade300
                                    : Colors.transparent),
                          width: sel ? 3 : 1.5,
                        ),
                        boxShadow: sel
                            ? [
                                BoxShadow(
                                  color: c.withValues(alpha: 0.5),
                                  blurRadius: 8,
                                ),
                              ]
                            : null,
                      ),
                      child: sel
                          ? Icon(
                              Icons.check_rounded,
                              color: c == Colors.white
                                  ? Colors.black
                                  : Colors.white,
                              size: 16,
                            )
                          : null,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  //  BUILD

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final t = widget.theme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _captureThumbnailAndExit();
      },
      child: Scaffold(
        backgroundColor: t.surfaceMuted,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(s, t),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _buildCanvasArea()),
                    // Floating partner badges - top right
                    Positioned(
                      top: 10,
                      right: 10,
                      child: _buildPartnerBadges(),
                    ),
                    // Scale / rotation indicator - top left
                    if (_scale != 1.0 || _canvasRotation != 0.0)
                      Positioned(
                        top: 10,
                        left: 10,
                        child: _buildScaleIndicator(),
                      ),
                    // Onboarding hint
                    if (_showHint)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 88,
                        child: Center(child: _buildHintBubble(s)),
                      ),
                  ],
                ),
              ),
              _buildBottomToolbar(s, t),
            ],
          ),
        ),
      ),
    );
  }

  //  Top bar

  Widget _buildTopBar(AppStrings s, AppTheme t) {
    final drawingPartners = _partnerLiveMap.entries
        .where((e) => e.value.points.length > 1)
        .map(
          (e) =>
              widget.pairData.partners
                  .where((p) => p.uid == e.key)
                  .map((p) => p.name)
                  .firstOrNull ??
              '?',
        )
        .toList();

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: t.cardSurface,
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          _topIconBtn(
            Icons.arrow_back_ios_new_rounded,
            _captureThumbnailAndExit,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.canvasName ?? s.drawTogether,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (drawingPartners.isNotEmpty)
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      s.partnerIsDrawing(drawingPartners.join(', ')),
                      key: ValueKey(drawingPartners.join()),
                      style: TextStyle(
                        fontSize: 11,
                        color: t.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _topIconBtn(
            Icons.undo_rounded,
            _canUndo ? _undo : null,
            tooltip: s.undoAction,
          ),
          _topIconBtn(
            Icons.redo_rounded,
            _canRedo ? _redo : null,
            tooltip: s.redoAction,
          ),
          _saving
              ? SizedBox(
                  width: 40,
                  height: 40,
                  child: Padding(
                    padding: const EdgeInsets.all(11),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: widget.theme.primary,
                    ),
                  ),
                )
              : _topIconBtn(
                  Icons.save_alt_rounded,
                  () => _saveOrShare(share: false),
                  tooltip: s.saveDrawing,
                ),
          _topIconBtn(
            Icons.share_rounded,
            () => _saveOrShare(share: true),
            tooltip: s.shareDrawing,
          ),
        ],
      ),
    );
  }

  Widget _topIconBtn(IconData icon, VoidCallback? onTap, {String? tooltip}) {
    final btn = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 20,
            color: onTap == null
                ? widget.theme.textMuted
                : widget.theme.textSecondary,
          ),
        ),
      ),
    );
    if (tooltip != null) return Tooltip(message: tooltip, child: btn);
    return btn;
  }

  //  Canvas area

  Widget _buildCanvasArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.biggest;
        final nextSize = Size(
          (available.width - _kCanvasPad * 2).clamp(1.0, double.infinity),
          (available.height - _kCanvasPad * 2).clamp(1.0, double.infinity),
        );
        // ��������� ������ ������ �������� �� ����� build-����.
        // addPostFrameCallback ����� ������ � �������� ������ �����������.
        if (!nextSize.isEmpty && nextSize != _canvasSize) {
          _canvasSize = nextSize;
        }

        return Stack(
          children: [
            // Subtle grid background
            Positioned.fill(child: _GridBackground(lineColor: widget.theme.divider)),
            // White canvas with shadow
            Positioned(
              left: _kCanvasPad,
              top: _kCanvasPad,
              right: _kCanvasPad,
              bottom: _kCanvasPad,
              child: Container(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 24,
                      spreadRadius: 2,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRect(
                  child: Transform(
                    transform: Matrix4.identity()
                      ..setTranslationRaw(
                        _canvasOffset.dx,
                        _canvasOffset.dy,
                        0.0,
                      )
                      ..scale(_scale, _scale, 1.0)
                      ..rotateZ(_canvasRotation),
                    child: RepaintBoundary(
                      key: _canvasKey,
                      child: _CanvasScene(
                        bgColor: _bgColor,
                        strokes: _visibleStrokes,
                        currentPoints: _currentPoints,
                        currentColorValue: _currentColorValue,
                        currentStrokeWidth: _currentStrokeWidth,
                        currentIsEraser: _currentIsEraser,
                        currentIsFilledShape: _currentIsFilledShape,
                        currentShapeType: _currentShapeType,
                        partnerNotifier: _partnerNotifier,
                        canvasSize: _canvasSize,
                        repaintNotifier: _repaintNotifier,
                        selectedImageId: _selectedImageId,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Input layer
            Positioned(
              left: _kCanvasPad,
              top: _kCanvasPad,
              right: _kCanvasPad,
              bottom: _kCanvasPad,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerUp,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _onScaleUpdate,
                  onScaleEnd: _onScaleEnd,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            // Partner cursor overlays
            ValueListenableBuilder<List<DrawStroke>>(
              valueListenable: _partnerNotifier,
              builder: (_, strokes, _) {
                if (_canvasSize.isEmpty) return const SizedBox.shrink();
                return Stack(
                  children: strokes
                      .where((s) => s.points.isNotEmpty)
                      .map((stroke) => _buildPartnerCursor(stroke))
                      .toList(),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildPartnerCursor(DrawStroke stroke) {
    final last = stroke.points.last;
    final sx =
        last.x * _canvasSize.width * _scale + _canvasOffset.dx + _kCanvasPad;
    final sy =
        last.y * _canvasSize.height * _scale + _canvasOffset.dy + _kCanvasPad;
    final name =
        widget.pairData.partners
            .where((p) => p.uid == stroke.userId)
            .map((p) => p.name)
            .firstOrNull ??
        '?';
    final color = _colorForUser(stroke.userId);

    return Positioned(
      left: sx - 12,
      top: sy - 12,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, child) {
            final pulse = 0.7 + 0.3 * _pulseAnim.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.scale(scale: pulse, child: child),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.4),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                  child: Text(
                    name.truncateGraphemes(8),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            );
          },
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.85),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 10),
              ],
            ),
            child: const Icon(
              Icons.brush_rounded,
              size: 12,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScaleIndicator() {
    final pct = (_scale * 100).round();
    final deg = (_canvasRotation * 180 / math.pi).round();
    final label = deg != 0 ? '$pct%  ${deg > 0 ? '+' : ''}$deg�' : '$pct%';
    return GestureDetector(
      onTap: _resetZoom,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  //  Partner badges

  Widget _buildPartnerBadges() {
    final partners = widget.pairData.partners;
    if (partners.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: partners.map((p) {
        final isDrawing = (_partnerLiveMap[p.uid]?.points.length ?? 0) > 1;
        final color = _colorForUser(p.uid);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(left: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: isDrawing ? 0.9 : 0.4),
            borderRadius: BorderRadius.circular(14),
            boxShadow: isDrawing
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 10,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isDrawing) ...[const _PulsingDot(), const SizedBox(width: 4)],
              Text(
                p.name.firstGraphemeUpper('?'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  //  Hint bubble

  Widget _buildHintBubble(AppStrings s) {
    final hints = [s.drawHint, s.brush, s.strokeThickness];
    final icons = [
      Icons.gesture_rounded,
      Icons.expand_rounded,
      Icons.pinch_rounded,
    ];

    return GestureDetector(
      onTap: () => setState(() => _showHint = false),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: Container(
          key: ValueKey(_hintStep),
          margin: const EdgeInsets.symmetric(horizontal: 40),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 12,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icons[_hintStep.clamp(0, 2)],
                color: Colors.white70,
                size: 20,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  hints[_hintStep.clamp(0, 2)],
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Icon(Icons.close_rounded, color: Colors.white38, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  //  Bottom toolbar

  Widget _buildBottomToolbar(AppStrings s, AppTheme t) {
    return Container(
      decoration: BoxDecoration(
        color: t.cardSurface,
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 10,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Expanded tools row (shown when toolbar is expanded)
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            child: _toolbarExpanded
                ? _buildExpandedTools(s, t)
                : const SizedBox.shrink(),
          ),
          // Main toolbar row
          _buildMainToolbarRow(s, t),
        ],
      ),
    );
  }

  Widget _buildExpandedTools(AppStrings s, AppTheme t) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: t.surfaceMuted,
      child: Row(
        children: [
          _toolBtn(
            Icons.remove_rounded,
            DrawTool.line,
            s.drawLine,
            t,
            compact: true,
          ),
          _toolBtn(
            Icons.crop_square_rounded,
            DrawTool.rect,
            s.drawRect,
            t,
            compact: true,
          ),
          _toolBtn(
            Icons.circle_outlined,
            DrawTool.circle,
            s.drawCircle,
            t,
            compact: true,
          ),
          _toolBtn(
            Icons.change_history_rounded,
            DrawTool.triangle,
            s.drawTriangle,
            t,
            compact: true,
          ),
          const SizedBox(width: 4),
          Container(width: 1, height: 24, color: t.divider),
          const SizedBox(width: 4),
          _actionBtn(
            _fillShapes
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded,
            () => setState(() => _fillShapes = !_fillShapes),
            tooltip: s.fillShapes,
            color: _fillShapes ? t.primary : t.textMuted,
          ),
          _toolBtn(
            Icons.format_color_fill_rounded,
            DrawTool.fill,
            s.fillBg,
            t,
            compact: true,
          ),
          const Spacer(),
          _actionBtn(
            Icons.delete_outline_rounded,
            _selectedImageId != null ? _deleteSelectedImage : _confirmClear,
            tooltip: _selectedImageId != null ? s.deletePhoto : s.clearCanvas,
            color: Colors.red.shade400,
          ),
        ],
      ),
    );
  }

  Widget _buildMainToolbarRow(AppStrings s, AppTheme t) {
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            const SizedBox(width: 8),
            // Color dot - opens color picker
            GestureDetector(
              onTap: _showColorPicker,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _activeColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: _activeColor.withValues(alpha: 0.4),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Color scroll bar
            Expanded(
              child: SizedBox(
                height: 64,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  dragStartBehavior: DragStartBehavior.down,
                  itemCount: _kPalette.length,
                  itemBuilder: (_, i) {
                    final c = _kPalette[i];
                    final sel = c.toARGB32() == _activeColor.toARGB32();
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() {
                        _activeColor = c;
                        _currentColorValue = c.toARGB32();
                      }),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 130),
                        margin: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 10,
                        ),
                        width: sel ? 40 : 34,
                        height: sel ? 40 : 34,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: sel
                                ? t.primary
                                : (c == Colors.white
                                      ? Colors.grey.shade400
                                      : Colors.transparent),
                            width: sel ? 2.5 : 1,
                          ),
                          boxShadow: sel
                              ? [
                                  BoxShadow(
                                    color: c.withValues(alpha: 0.5),
                                    blurRadius: 8,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Palm (hand) tool
            _toolBtn(Icons.pan_tool_rounded, DrawTool.palm, s.palmTool, t),
            // Image tool
            _toolBtn(Icons.image_rounded, DrawTool.image, s.photo, t),
            // Add photo button
            _actionBtn(
              Icons.add_photo_alternate_rounded,
              _pickAndAddImage,
              tooltip: s.addPhoto,
            ),
            // Brush tool
            _toolBtn(Icons.brush_rounded, DrawTool.brush, s.brush, t),
            // Eraser
            _toolBtn(
              Icons.auto_fix_normal_rounded,
              DrawTool.eraser,
              s.eraser,
              t,
            ),
            // Thickness
            _actionBtn(
              Icons.line_weight_rounded,
              _showThicknessPicker,
              tooltip: s.strokeThickness,
              badge: _strokeWidth.round().toString(),
            ),
            // Expand/collapse more tools
            _expandBtn(t),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _toolBtn(
    IconData icon,
    DrawTool tool,
    String tooltip,
    AppTheme t, {
    bool compact = false,
  }) {
    final active = _activeTool == tool;
    final size = compact ? 36.0 : 42.0;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () => _selectTool(tool),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: EdgeInsets.symmetric(
            horizontal: compact ? 2 : 3,
            vertical: compact ? 8 : 6,
          ),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: active
                ? t.primary.withValues(alpha: 0.13)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: active
                ? Border.all(
                    color: t.primary.withValues(alpha: 0.45),
                    width: 1.5,
                  )
                : null,
          ),
          child: Icon(
            icon,
            size: compact ? 20 : 22,
            color: active ? t.primary : t.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _actionBtn(
    IconData icon,
    VoidCallback? onTap, {
    required String tooltip,
    Color? color,
    String? badge,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: widget.theme.surfaceMuted,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Stack(
            children: [
              Center(
                child: Icon(
                  icon,
                  size: 22,
                  color: color ?? widget.theme.textMuted,
                ),
              ),
              if (badge != null)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade600,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _expandBtn(AppTheme t) {
    return GestureDetector(
      onTap: () {
        setState(() => _toolbarExpanded = !_toolbarExpanded);
        if (_toolbarExpanded) {
          _toolbarAnim.forward();
        } else {
          _toolbarAnim.reverse();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: _toolbarExpanded
              ? t.primary.withValues(alpha: 0.13)
              : t.surfaceMuted,
          borderRadius: BorderRadius.circular(12),
          border: _toolbarExpanded
              ? Border.all(color: t.primary.withValues(alpha: 0.4), width: 1.5)
              : null,
        ),
        child: AnimatedRotation(
          duration: const Duration(milliseconds: 260),
          turns: _toolbarExpanded ? 0.5 : 0.0,
          child: Icon(
            Icons.expand_less_rounded,
            size: 22,
            color: _toolbarExpanded ? t.primary : t.textMuted,
          ),
        ),
      ),
    );
  }
}

//  Grid background

class _GridBackground extends StatelessWidget {
  final Color lineColor;
  const _GridBackground({required this.lineColor});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _GridPainter(lineColor));
  }
}

class _GridPainter extends CustomPainter {
  final Color lineColor;
  _GridPainter(this.lineColor);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 0.5;
    const step = 24.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.lineColor != lineColor;
}

//  Pulsing dot widget

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.5 + 0.5 * _anim.value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

//  _CanvasScene

class _CanvasScene extends StatefulWidget {
  final Color bgColor;
  final List<DrawStroke> strokes;
  final List<DrawPoint> currentPoints;
  final int currentColorValue;
  final double currentStrokeWidth;
  final bool currentIsEraser;
  final bool currentIsFilledShape;
  final DrawShapeType? currentShapeType;
  final ValueNotifier<List<DrawStroke>> partnerNotifier;
  final Size canvasSize;
  final ValueNotifier<int> repaintNotifier;
  final String? selectedImageId;

  const _CanvasScene({
    required this.bgColor,
    required this.strokes,
    required this.currentPoints,
    required this.currentColorValue,
    required this.currentStrokeWidth,
    required this.currentIsEraser,
    required this.currentIsFilledShape,
    required this.currentShapeType,
    required this.partnerNotifier,
    required this.canvasSize,
    required this.repaintNotifier,
    this.selectedImageId,
  });

  @override
  State<_CanvasScene> createState() => _CanvasSceneState();
}

class _CanvasSceneState extends State<_CanvasScene> {
  late Listenable _repaint;

  @override
  void initState() {
    super.initState();
    _repaint = Listenable.merge([
      widget.repaintNotifier,
      widget.partnerNotifier,
    ]);
  }

  @override
  void didUpdateWidget(covariant _CanvasScene old) {
    super.didUpdateWidget(old);
    if (old.repaintNotifier != widget.repaintNotifier ||
        old.partnerNotifier != widget.partnerNotifier) {
      _repaint = Listenable.merge([
        widget.repaintNotifier,
        widget.partnerNotifier,
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imageStrokes = widget.strokes.where((s) => s.isImageStroke).toList();
    final drawStrokes = widget.strokes.where((s) => !s.isImageStroke).toList();

    return Container(
      color: widget.bgColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          SizedBox.expand(
            child: CustomPaint(
              painter: _DrawingPainter(
                strokes: drawStrokes,
                currentPoints: widget.currentPoints,
                currentColorValue: widget.currentColorValue,
                currentStrokeWidth: widget.currentStrokeWidth,
                currentIsEraser: widget.currentIsEraser,
                currentIsFilledShape: widget.currentIsFilledShape,
                currentShapeType: widget.currentShapeType,
                partnerNotifier: widget.partnerNotifier,
                canvasSize: widget.canvasSize,
                repaint: _repaint,
              ),
            ),
          ),
          ...imageStrokes.map((s) => _buildImageWidget(s, widget.canvasSize)),
        ],
      ),
    );
  }

  Widget _buildImageWidget(DrawStroke s, Size canvasSize) {
    if (canvasSize.isEmpty) return const SizedBox.shrink();
    final cx = (s.imageX ?? 0.5) * canvasSize.width;
    final cy = (s.imageY ?? 0.5) * canvasSize.height;
    final w = (s.imageWidth ?? 0.5) * canvasSize.width;
    final h = (s.imageHeight ?? 0.5) * canvasSize.height;
    final rot = s.imageRotation ?? 0.0;
    // file:// — локальный файл; остальное (pb:// protected / http / gs / sb) —
    // через StorageImage: он добавит PocketBase file-токен и разрешит схему async.
    final raw = s.imageUrl ?? '';
    final isSelected = widget.selectedImageId == s.id;

    Widget img;
    if (raw.startsWith('file://')) {
      img = Image.file(
        File(raw.substring(7)),
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _imgPlaceholder(w, h),
      );
    } else if (raw.isNotEmpty) {
      img = StorageImage(
        imageUrl: raw,
        width: w,
        height: h,
        fit: BoxFit.cover,
        placeholder: (_, __) => _imgPlaceholder(w, h, loading: true),
        errorWidget: (_, __, ___) => _imgPlaceholder(w, h),
      );
    } else {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: cx - w / 2,
      top: cy - h / 2,
      child: Transform.rotate(
        angle: rot,
        alignment: Alignment.center,
        child: Stack(
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(4), child: img),
            if (isSelected)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.blue.shade400, width: 2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _imgPlaceholder(double w, double h, {bool loading = false}) =>
      Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.broken_image_rounded, color: Colors.grey.shade400),
        ),
      );
}

//  _DrawingPainter

class _DrawingPainter extends CustomPainter {
  final List<DrawStroke> strokes;
  final List<DrawPoint> currentPoints;
  final int currentColorValue;
  final double currentStrokeWidth;
  final bool currentIsEraser;
  final bool currentIsFilledShape;
  final DrawShapeType? currentShapeType;
  final ValueNotifier<List<DrawStroke>> partnerNotifier;
  final Size canvasSize;

  _DrawingPainter({
    required this.strokes,
    required this.currentPoints,
    required this.currentColorValue,
    required this.currentStrokeWidth,
    required this.currentIsEraser,
    required this.currentIsFilledShape,
    required this.currentShapeType,
    required this.partnerNotifier,
    required this.canvasSize,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Removed saveLayer for performance. Simplified Eraser uses bgColor ink.

    for (final s in strokes) {
      if (s.shapeType != null) {
        _drawShape(
          canvas,
          s.points,
          s.colorValue,
          s.strokeWidth,
          s.shapeType!,
          size,
          isFilledShape: s.isFilledShape,
        );
      } else {
        _drawStroke(
          canvas,
          s.points,
          s.colorValue,
          s.strokeWidth,
          s.isEraser,
          size,
        );
      }
    }

    if (currentPoints.isNotEmpty) {
      if (currentShapeType != null && currentPoints.length >= 2) {
        _drawShape(
          canvas,
          currentPoints,
          currentColorValue,
          currentStrokeWidth,
          currentShapeType!,
          size,
          isFilledShape: currentIsFilledShape,
        );
      } else {
        _drawStroke(
          canvas,
          currentPoints,
          currentColorValue,
          currentStrokeWidth,
          currentIsEraser,
          size,
        );
      }
    }

    for (final s in partnerNotifier.value) {
      if (s.shapeType != null && s.points.length >= 2) {
        _drawShape(
          canvas,
          s.points,
          s.colorValue,
          s.strokeWidth,
          s.shapeType!,
          size,
          alpha: 0.85,
          isFilledShape: s.isFilledShape,
        );
      } else if (s.shapeType == null) {
        _drawStroke(
          canvas,
          s.points,
          s.colorValue,
          s.strokeWidth,
          s.isEraser,
          size,
          alpha: 0.85,
        );
      }
    }
  }

  void _drawShape(
    Canvas canvas,
    List<DrawPoint> points,
    int colorValue,
    double strokeWidth,
    DrawShapeType shapeType,
    Size size, {
    double alpha = 1.0,
    required bool isFilledShape,
  }) {
    if (points.length < 2) return;
    final c = Color(colorValue);
    final paint = Paint()
      ..color = alpha < 1.0 ? c.withValues(alpha: c.a * alpha) : c
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = isFilledShape ? PaintingStyle.fill : PaintingStyle.stroke;

    final s = points.first.toOffset(size);
    final e = points.last.toOffset(size);

    switch (shapeType) {
      case DrawShapeType.line:
        canvas.drawLine(s, e, paint);
      case DrawShapeType.rect:
        canvas.drawRect(Rect.fromPoints(s, e), paint);
      case DrawShapeType.circle:
        canvas.drawOval(Rect.fromPoints(s, e), paint);
      case DrawShapeType.triangle:
        final path = Path();
        path.moveTo((s.dx + e.dx) / 2, s.dy); // Top center
        path.lineTo(s.dx, e.dy); // Bottom left
        path.lineTo(e.dx, e.dy); // Bottom right
        path.close();
        canvas.drawPath(path, paint);
    }
  }

  void _drawStroke(
    Canvas canvas,
    List<DrawPoint> points,
    int colorValue,
    double strokeWidth,
    bool isEraser,
    Size size, {
    double alpha = 1.0,
  }) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    if (isEraser) {
      // Drawing with bgColor is faster and more collaborative-friendly than BlendMode.dstOut
      paint.color = Color(colorValue);
    } else {
      final c = Color(colorValue);
      paint.color = alpha < 1.0 ? c.withValues(alpha: c.a * alpha) : c;
    }

    if (points.length == 1) {
      if (!isEraser) {
        canvas.drawCircle(
          points.first.toOffset(size),
          strokeWidth / 2,
          paint..style = PaintingStyle.fill,
        );
      }
      return;
    }

    final path = Path();
    final first = points.first.toOffset(size);
    path.moveTo(first.dx, first.dy);

    for (int i = 1; i < points.length - 1; i++) {
      final p0 = points[i].toOffset(size);
      final p1 = points[i + 1].toOffset(size);
      final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
    }

    final last = points.last.toOffset(size);
    path.lineTo(last.dx, last.dy);
    canvas.drawPath(path, paint..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant _DrawingPainter old) =>
      old.strokes != strokes ||
      old.currentPoints != currentPoints ||
      old.currentColorValue != currentColorValue ||
      old.currentStrokeWidth != currentStrokeWidth ||
      old.currentIsEraser != currentIsEraser ||
      old.currentShapeType != currentShapeType ||
      old.canvasSize != canvasSize;
}
