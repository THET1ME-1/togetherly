import '../../../services/locale_service.dart';

enum PostcardTemplateId { together, polaroid, bloom, nightSky }

class PostcardTextBlock {
  final String id;
  final String label;
  final String text;

  const PostcardTextBlock({
    required this.id,
    required this.label,
    required this.text,
  });

  PostcardTextBlock copyWith({String? text}) =>
      PostcardTextBlock(id: id, label: label, text: text ?? this.text);
}

class PostcardTemplate {
  final PostcardTemplateId id;
  final String name;
  final String emoji;

  const PostcardTemplate({
    required this.id,
    required this.name,
    required this.emoji,
  });

  static List<PostcardTextBlock> defaultBlocks({
    required PostcardTemplateId templateId,
    required int days,
    required String myName,
    required String partnerName,
  }) {
    final s = LocaleService.current;
    final names =
        myName.isNotEmpty && partnerName.isNotEmpty
            ? '$myName & $partnerName'
            : myName.isNotEmpty
            ? myName
            : s.pcNamesFallback;

    return switch (templateId) {
      PostcardTemplateId.together => [
        PostcardTextBlock(id: 'names', label: s.pcLabelNames, text: names),
        PostcardTextBlock(
          id: 'days_label',
          label: s.pcLabelDaysCaption,
          text: s.pcDaysTogether,
        ),
        PostcardTextBlock(
          id: 'message',
          label: s.pcLabelMessage,
          text: s.pcMsgTogether,
        ),
      ],
      PostcardTemplateId.polaroid => [
        PostcardTextBlock(id: 'names', label: s.pcLabelNames, text: names),
        PostcardTextBlock(
          id: 'days_label',
          label: s.pcLabelCaption,
          text: s.pcDaysOfLove,
        ),
        PostcardTextBlock(
          id: 'message',
          label: s.pcLabelPolaroidCaption,
          text: s.pcMsgPolaroid,
        ),
      ],
      PostcardTemplateId.bloom => [
        PostcardTextBlock(id: 'names', label: s.pcLabelNames, text: names),
        PostcardTextBlock(
          id: 'days_label',
          label: s.pcLabelDaysCaption,
          text: s.pcDaysNearby,
        ),
        PostcardTextBlock(
          id: 'message',
          label: s.pcLabelMessageAlt,
          text: s.pcMsgBloom,
        ),
      ],
      PostcardTemplateId.nightSky => [
        PostcardTextBlock(id: 'names', label: s.pcLabelNames, text: names),
        PostcardTextBlock(
          id: 'days_label',
          label: s.pcLabelDaysCaption,
          text: s.pcNightsUnderSky,
        ),
        PostcardTextBlock(
          id: 'message',
          label: s.pcLabelMessage,
          text: s.pcMsgNightSky,
        ),
      ],
    };
  }

  static const List<PostcardTemplate> all = [
    PostcardTemplate(
      id: PostcardTemplateId.together,
      name: 'Together',
      emoji: '💕',
    ),
    PostcardTemplate(
      id: PostcardTemplateId.polaroid,
      name: 'Polaroid',
      emoji: '📷',
    ),
    PostcardTemplate(
      id: PostcardTemplateId.bloom,
      name: 'Bloom',
      emoji: '🌸',
    ),
    PostcardTemplate(
      id: PostcardTemplateId.nightSky,
      name: 'Night Sky',
      emoji: '🌙',
    ),
  ];
}
