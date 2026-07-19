import 'package:flutter/material.dart';
import '../../../models/pair_data.dart';
import '../../../services/locale_service.dart';
import '../../../theme/theme_scope.dart';

/// Shows relationship type selection dialog
void showRelationshipTypeDialog({
  required BuildContext context,
  required PairData pairData,
  required Color primary,
  required VoidCallback onStateChanged,
}) {
  showDialog(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final customTypes = pairData.customRelationshipTypes;
        final t = ctx.appTheme;
        return Dialog(
          backgroundColor: t.cardSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.75,
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      LocaleService.current.relationshipStatus,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: t.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      LocaleService.current.chooseHowToConnect,
                      style: TextStyle(
                        fontSize: 13,
                        color: t.textMuted,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _RelationshipOption(
                      type: RelationshipType.couple,
                      icon: '💕',
                      title: LocaleService.current.inLoveStatus,
                      subtitle: LocaleService.current.perfectForCouples,
                      isSelected:
                          pairData.relationshipType == RelationshipType.couple,
                      primary: primary,
                      onTap: () {
                        pairData.setRelationshipType(RelationshipType.couple);
                        Navigator.of(ctx).pop();
                        onStateChanged();
                      },
                    ),
                    const SizedBox(height: 12),
                    _RelationshipOption(
                      type: RelationshipType.married,
                      icon: '💍',
                      title: LocaleService.current.married,
                      subtitle: LocaleService.current.forMarriedPartners,
                      isSelected:
                          pairData.relationshipType == RelationshipType.married,
                      primary: primary,
                      onTap: () {
                        pairData.setRelationshipType(RelationshipType.married);
                        Navigator.of(ctx).pop();
                        onStateChanged();
                      },
                    ),
                    const SizedBox(height: 12),
                    _RelationshipOption(
                      type: RelationshipType.friends,
                      icon: '🤝',
                      title: LocaleService.current.friends,
                      subtitle: LocaleService.current.connectWithBestFriend,
                      isSelected:
                          pairData.relationshipType == RelationshipType.friends,
                      primary: primary,
                      onTap: () {
                        pairData.setRelationshipType(RelationshipType.friends);
                        Navigator.of(ctx).pop();
                        onStateChanged();
                      },
                    ),
                    const SizedBox(height: 12),
                    _RelationshipOption(
                      type: RelationshipType.buddies,
                      icon: '👯',
                      title: LocaleService.current.bestBuddies,
                      subtitle: LocaleService.current.forInseparableCompanions,
                      isSelected:
                          pairData.relationshipType == RelationshipType.buddies,
                      primary: primary,
                      onTap: () {
                        pairData.setRelationshipType(RelationshipType.buddies);
                        Navigator.of(ctx).pop();
                        onStateChanged();
                      },
                    ),
                    // Custom relationship types
                    ...customTypes.map((entry) {
                      final isSelected =
                          pairData.relationshipType ==
                              RelationshipType.custom &&
                          pairData.relationshipLabel == entry['label'];
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _CustomRelTypeOption(
                          entry: entry,
                          isSelected: isSelected,
                          primary: primary,
                          onSelect: () {
                            pairData.setRelationshipType(
                              RelationshipType.custom,
                              label: entry['label'] ?? '',
                              emoji: entry['emoji'] ?? '?',
                            );
                            Navigator.of(ctx).pop();
                            onStateChanged();
                          },
                          onEdit: () {
                            Navigator.of(ctx).pop();
                            _showEditCustomRelTypeDialog(
                              context: context,
                              entry: entry,
                              pairData: pairData,
                              primary: primary,
                              onStateChanged: onStateChanged,
                            );
                          },
                          onDelete: () async {
                            await pairData.deleteCustomRelationshipType(
                              entry['id'] ?? '',
                            );
                            // Диалог мог закрыться за время await.
                            if (ctx.mounted) setDialogState(() {});
                            onStateChanged();
                          },
                        ),
                      );
                    }),
                    const SizedBox(height: 16),
                    // Add custom type button
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _showAddCustomRelTypeDialog(
                          context: context,
                          pairData: pairData,
                          primary: primary,
                          onStateChanged: onStateChanged,
                        );
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(LocaleService.current.addCustomStatus),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          vertical: 14,
                          horizontal: 20,
                        ),
                        side: BorderSide(
                          color: t.divider,
                          width: 1.5,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
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
    ),
  );
}

class _RelationshipOption extends StatelessWidget {
  final RelationshipType type;
  final String icon;
  final String title;
  final String subtitle;
  final bool isSelected;
  final Color primary;
  final VoidCallback onTap;

  const _RelationshipOption({
    required this.type,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isSelected,
    required this.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? primary.withOpacity(0.08) : t.surfaceMuted,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? primary : t.divider,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isSelected ? primary : t.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: t.textMuted),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle_rounded, color: primary, size: 24),
          ],
        ),
      ),
    );
  }
}

class _CustomRelTypeOption extends StatelessWidget {
  final Map<String, String> entry;
  final bool isSelected;
  final Color primary;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CustomRelTypeOption({
    required this.entry,
    required this.isSelected,
    required this.primary,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    return GestureDetector(
      onTap: onSelect,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? primary.withOpacity(0.08) : t.surfaceMuted,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? primary : t.divider,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Text(entry['emoji'] ?? '?', style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                entry['label'] ?? 'Custom',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: isSelected ? primary : Colors.grey.shade800,
                ),
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle_rounded, color: primary, size: 24),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onEdit,
              child: Icon(Icons.edit, size: 18, color: Colors.blue.shade400),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onDelete,
              child: Icon(
                Icons.delete_outline,
                size: 18,
                color: Colors.red.shade400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showAddCustomRelTypeDialog({
  required BuildContext context,
  required PairData pairData,
  required Color primary,
  required VoidCallback onStateChanged,
}) {
  final labelCtrl = TextEditingController();
  final emojiCtrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(LocaleService.current.addCustomStatus),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: emojiCtrl,
            decoration: InputDecoration(
              labelText: LocaleService.current.emoji,
              hintText: '💕',
            ),
            maxLength: 2,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: labelCtrl,
            decoration: InputDecoration(
              labelText: LocaleService.current.label,
              hintText: LocaleService.current.egSoulmates,
            ),
            maxLength: 30,
            textCapitalization: TextCapitalization.words,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(LocaleService.current.cancel),
        ),
        ElevatedButton(
          onPressed: () async {
            final label = labelCtrl.text.trim();
            final emoji = emojiCtrl.text.trim();
            if (label.isNotEmpty) {
              await pairData.addCustomRelationshipType(
                label,
                emoji.isNotEmpty ? emoji : '?',
              );
              if (context.mounted) {
                Navigator.pop(ctx);
                onStateChanged();
                showRelationshipTypeDialog(
                  context: context,
                  pairData: pairData,
                  primary: primary,
                  onStateChanged: onStateChanged,
                );
              }
            }
          },
          child: Text(LocaleService.current.add),
        ),
      ],
    ),
  );
}

void _showEditCustomRelTypeDialog({
  required BuildContext context,
  required Map<String, String> entry,
  required PairData pairData,
  required Color primary,
  required VoidCallback onStateChanged,
}) {
  final labelCtrl = TextEditingController(text: entry['label'] ?? '');
  final emojiCtrl = TextEditingController(text: entry['emoji'] ?? '');
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(LocaleService.current.editCustomStatus),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: emojiCtrl,
            decoration: InputDecoration(
              labelText: LocaleService.current.emoji,
              hintText: '💕',
            ),
            maxLength: 2,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: labelCtrl,
            decoration: InputDecoration(
              labelText: LocaleService.current.label,
              hintText: LocaleService.current.egSoulmates,
            ),
            maxLength: 30,
            textCapitalization: TextCapitalization.words,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(LocaleService.current.cancel),
        ),
        ElevatedButton(
          onPressed: () async {
            final label = labelCtrl.text.trim();
            final emoji = emojiCtrl.text.trim();
            if (label.isNotEmpty) {
              await pairData.updateCustomRelationshipType(
                entry['id'] ?? '',
                label,
                emoji.isNotEmpty ? emoji : '?',
              );
              if (context.mounted) {
                Navigator.pop(ctx);
                onStateChanged();
                showRelationshipTypeDialog(
                  context: context,
                  pairData: pairData,
                  primary: primary,
                  onStateChanged: onStateChanged,
                );
              }
            }
          },
          child: Text(LocaleService.current.save),
        ),
      ],
    ),
  );
}
