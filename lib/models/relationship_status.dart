/// Represents a relationship status that can be assigned to a group/pair
class RelationshipStatus {
  final String id; // Unique identifier for custom statuses
  final String label; // Display text (e.g., "Married", "Dating")
  final String emoji; // Optional emoji
  final bool isPredefined; // True for built-in statuses, false for custom

  const RelationshipStatus({
    required this.id,
    required this.label,
    this.emoji = '',
    this.isPredefined = false,
  });

  // Predefined statuses
  static const married = RelationshipStatus(
    id: 'married',
    label: 'Married',
    emoji: '💍',
    isPredefined: true,
  );

  static const dating = RelationshipStatus(
    id: 'dating',
    label: 'Dating',
    emoji: '💕',
    isPredefined: true,
  );

  static const engaged = RelationshipStatus(
    id: 'engaged',
    label: 'Engaged',
    emoji: '💎',
    isPredefined: true,
  );

  static const inRelationship = RelationshipStatus(
    id: 'in_relationship',
    label: 'In a Relationship',
    emoji: '❤️',
    isPredefined: true,
  );

  static const complicated = RelationshipStatus(
    id: 'complicated',
    label: 'It\'s Complicated',
    emoji: '🤷',
    isPredefined: true,
  );

  static const List<RelationshipStatus> predefinedStatuses = [
    married,
    engaged,
    inRelationship,
    dating,
    complicated,
  ];

  // Serialization
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'emoji': emoji,
    'isPredefined': isPredefined,
  };

  factory RelationshipStatus.fromJson(Map<String, dynamic> json) {
    return RelationshipStatus(
      id: json['id'] ?? '',
      label: json['label'] ?? '',
      emoji: json['emoji'] ?? '',
      isPredefined: json['isPredefined'] ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelationshipStatus &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => '$emoji $label';

  String get displayText => emoji.isNotEmpty ? '$emoji $label' : label;
}
