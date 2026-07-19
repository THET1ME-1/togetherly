import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';

/// Tools available in the drawing canvas.
enum DrawTool { brush, eraser, fill, image, line, rect, circle, triangle, palm }

/// Geometric shape types for shape-drawing tools.
enum DrawShapeType { line, rect, circle, triangle }

/// A single 2-D point on the canvas (normalised 0..1 relative to canvas size
/// so strokes look correct on any screen size).
class DrawPoint {
  final double x;
  final double y;

  const DrawPoint(this.x, this.y);

  Offset toOffset(Size canvasSize) =>
      Offset(x * canvasSize.width, y * canvasSize.height);

  Map<String, dynamic> toMap() => {'x': x, 'y': y};

  factory DrawPoint.fromMap(Map<String, dynamic> map) =>
      DrawPoint((map['x'] as num).toDouble(), (map['y'] as num).toDouble());

  /// Create from an absolute Offset and canvas size.
  factory DrawPoint.fromOffset(Offset offset, Size canvasSize) => DrawPoint(
    canvasSize.width > 0 ? offset.dx / canvasSize.width : 0,
    canvasSize.height > 0 ? offset.dy / canvasSize.height : 0,
  );
}

/// One complete or in-progress drawing stroke (brush, eraser, or image).
class DrawStroke {
  final String id;
  final String userId;
  final int colorValue; // Color as ARGB integer
  final double strokeWidth;
  final List<DrawPoint> points;
  final bool isEraser;
  final bool isFilledShape;

  /// Non-null when this stroke was drawn with a shape tool (line/rect/circle/triangle).
  final DrawShapeType? shapeType;

  /// Global ordering counter so strokes are drawn in the correct order.
  final int orderIndex;

  // ── Image-type stroke fields ──────────────────────────────────────────────
  /// Non-null when this "stroke" is a photo inserted on the canvas.
  final String? imageUrl;

  /// Position and size of the image in normalised coordinates (0..1).
  final double? imageX;
  final double? imageY;
  final double? imageWidth;
  final double? imageHeight;

  /// Rotation of the image in radians.
  final double? imageRotation;

  const DrawStroke({
    required this.id,
    required this.userId,
    required this.colorValue,
    required this.strokeWidth,
    required this.points,
    this.isEraser = false,
    this.isFilledShape = false,
    this.shapeType,
    required this.orderIndex,
    this.imageUrl,
    this.imageX,
    this.imageY,
    this.imageWidth,
    this.imageHeight,
    this.imageRotation,
  });

  bool get isImageStroke => imageUrl != null;
  bool get isShapeStroke => shapeType != null;

  Color get color => Color(colorValue);

  // ── Firestore serialisation ───────────────────────────────────────────────

  Map<String, dynamic> toFirestore() => {
    'userId': userId,
    'colorValue': colorValue,
    'strokeWidth': strokeWidth,
    'points': points.map((p) => p.toMap()).toList(),
    'isEraser': isEraser,
    'isFilledShape': isFilledShape,
    'orderIndex': orderIndex,
    'createdAt': DateTime.now().millisecondsSinceEpoch,
    if (shapeType != null) 'shapeType': shapeType!.name,
    if (imageUrl != null) 'imageUrl': imageUrl,
    if (imageX != null) 'imageX': imageX,
    if (imageY != null) 'imageY': imageY,
    if (imageWidth != null) 'imageWidth': imageWidth,
    if (imageHeight != null) 'imageHeight': imageHeight,
    if (imageRotation != null) 'imageRotation': imageRotation,
  };

  factory DrawStroke.fromFirestore(Map<String, dynamic> data, String id) {
    final rawPoints = (data['points'] as List?) ?? [];
    return DrawStroke(
      id: id,
      userId: (data['userId'] as String?) ?? '',
      colorValue: (data['colorValue'] as num?)?.toInt() ?? 0xFF000000,
      strokeWidth: (data['strokeWidth'] as num?)?.toDouble() ?? 4.0,
      points: rawPoints
          .map((p) => DrawPoint.fromMap(Map<String, dynamic>.from(p as Map)))
          .toList(),
      isEraser: (data['isEraser'] as bool?) ?? false,
      isFilledShape: (data['isFilledShape'] as bool?) ?? false,
      shapeType: _parseShapeType(data['shapeType'] as String?),
      orderIndex: (data['orderIndex'] as num?)?.toInt() ?? 0,
      imageUrl: data['imageUrl'] as String?,
      imageX: (data['imageX'] as num?)?.toDouble(),
      imageY: (data['imageY'] as num?)?.toDouble(),
      imageWidth: (data['imageWidth'] as num?)?.toDouble(),
      imageHeight: (data['imageHeight'] as num?)?.toDouble(),
      imageRotation: (data['imageRotation'] as num?)?.toDouble(),
    );
  }

  /// PocketBase committed-штрих (`canvas_strokes`): вся карта лежит в json-колонке
  /// `data` (как [toFirestore]), id = id записи. order_index дублируется отдельной
  /// колонкой для сортировки, но читаем orderIndex из самой карты.
  factory DrawStroke.fromPb(RecordModel rec) {
    final raw = rec.data['data'];
    final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    return DrawStroke.fromFirestore(map, rec.id);
  }

  /// Lightweight serialisation used for the live-stroke document.
  Map<String, dynamic> toLiveMap() => {
    'userId': userId,
    'colorValue': colorValue,
    'strokeWidth': strokeWidth,
    'isEraser': isEraser,
    'isFilledShape': isFilledShape,
    'points': points.map((p) => p.toMap()).toList(),
    if (shapeType != null) 'shapeType': shapeType!.name,
    'ts': DateTime.now().millisecondsSinceEpoch,
  };

  factory DrawStroke.fromLiveMap(Map<String, dynamic> data, String userId) {
    final rawPoints = (data['points'] as List?) ?? [];
    return DrawStroke(
      id: 'live_$userId',
      userId: userId,
      colorValue: (data['colorValue'] as num?)?.toInt() ?? 0xFF000000,
      strokeWidth: (data['strokeWidth'] as num?)?.toDouble() ?? 4.0,
      points: rawPoints
          .map((p) => DrawPoint.fromMap(Map<String, dynamic>.from(p as Map)))
          .toList(),
      isEraser: (data['isEraser'] as bool?) ?? false,
      isFilledShape: (data['isFilledShape'] as bool?) ?? false,
      shapeType: _parseShapeType(data['shapeType'] as String?),
      orderIndex: -1,
    );
  }
}

DrawShapeType? _parseShapeType(String? value) {
  if (value == null) return null;
  switch (value) {
    case 'line':
      return DrawShapeType.line;
    case 'rect':
      return DrawShapeType.rect;
    case 'circle':
      return DrawShapeType.circle;
    case 'triangle':
      return DrawShapeType.triangle;
    default:
      return null;
  }
}
