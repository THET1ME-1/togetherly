/// Metadata for a single drawing canvas.
/// The actual strokes are stored in Firebase (paired) or in memory (solo).
class CanvasMeta {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Base64-encoded PNG thumbnail, nullable when no preview has been saved yet.
  final String? previewBase64;

  const CanvasMeta({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.previewBase64,
  });

  CanvasMeta copyWith({
    String? name,
    DateTime? updatedAt,
    String? previewBase64,
    bool clearPreview = false,
  }) =>
      CanvasMeta(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        previewBase64:
            clearPreview ? null : (previewBase64 ?? this.previewBase64),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        if (previewBase64 != null) 'previewBase64': previewBase64,
      };

  factory CanvasMeta.fromJson(Map<String, dynamic> json) => CanvasMeta(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? 'Canvas',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (json['createdAt'] as num).toInt()),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (json['updatedAt'] as num).toInt()),
        previewBase64: json['previewBase64'] as String?,
      );
}
