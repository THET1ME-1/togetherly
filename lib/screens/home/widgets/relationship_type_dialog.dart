import 'package:flutter/material.dart';
import '../../../models/connection.dart';
import '../../../models/pair_data.dart';
import '../../../services/locale_service.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/profile_theme.dart';
import '../../../theme/theme_scope.dart';
import '../../../widgets/connect_expressive.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Иконки типов связи (пара иконка↔эмодзи). Иконку показываем в интерфейсе
//  (цвет от темы), эмодзи храним под кастомом — его рисует нативный домашний
//  виджет. Порядок пар менять нельзя. const → переживают tree-shake.
// ─────────────────────────────────────────────────────────────────────────────
const List<IconData> kRelIcons = [
  Icons.favorite_rounded,
  Icons.diamond_rounded,
  Icons.handshake_rounded,
  Icons.groups_rounded,
  Icons.star_rounded,
  Icons.local_fire_department_rounded,
  Icons.pets_rounded,
  Icons.music_note_rounded,
  Icons.sports_esports_rounded,
  Icons.coffee_rounded,
  Icons.cake_rounded,
  Icons.flight_takeoff_rounded,
  Icons.brush_rounded,
  Icons.emoji_events_rounded,
  Icons.spa_rounded,
  Icons.auto_awesome_rounded,
];
const List<String> kRelEmojis = [
  '❤️', '💍', '🤝', '👯', '⭐', '🔥', '🐾', '🎵', '🎮', '☕', '🎂', '✈️',
  '🎨', '🏆', '🌿', '✨',
];

IconData relIconForEmoji(String emoji) {
  final i = kRelEmojis.indexOf(emoji);
  return i >= 0 ? kRelIcons[i] : Icons.auto_awesome_rounded;
}

IconData relIconForType(RelationshipType type, {String customEmoji = ''}) {
  switch (type) {
    case RelationshipType.couple:
      return Icons.favorite_rounded;
    case RelationshipType.married:
      return Icons.diamond_rounded;
    case RelationshipType.friends:
      return Icons.handshake_rounded;
    case RelationshipType.buddies:
      return Icons.groups_rounded;
    case RelationshipType.custom:
      return relIconForEmoji(customEmoji);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Общие куски M3-листа снизу (хват, заголовок, строка-опция)
// ─────────────────────────────────────────────────────────────────────────────
Widget sheetHandle(ColorScheme cs) => Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 22),
        decoration: BoxDecoration(
            color: cs.onSurfaceVariant.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(2)),
      ),
    );

Widget sheetHeader(ColorScheme cs, String title, [String subtitle = '']) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontFamily: 'Unbounded',
                fontWeight: FontWeight.w700,
                fontSize: 22,
                color: cs.onSurface)),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Onest',
                  fontSize: 14,
                  color: cs.onSurfaceVariant)),
        ],
        const SizedBox(height: 22),
      ],
    );

Widget typeSheetOption({
  required ColorScheme cs,
  required IconData icon,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
  bool selected = false,
  Widget? trailing,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: PressableScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? cs.secondaryContainer : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(16)),
              child: Icon(icon, color: cs.primary, size: 25),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'Onest',
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: selected
                              ? cs.onSecondaryContainer
                              : cs.onSurface)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'Onest',
                          fontSize: 12.5,
                          color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing ??
                (selected
                    ? Icon(Icons.check_circle_rounded, color: cs.primary, size: 24)
                    : Icon(Icons.chevron_right_rounded,
                        color: cs.onSurfaceVariant, size: 22)),
          ],
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  Лист выбора типа связи (M3, снизу) — общий для шапки и экрана «Подключение»
// ─────────────────────────────────────────────────────────────────────────────
void showRelationshipTypeSheet(
  BuildContext context, {
  required PairData pair,
  required AppTheme theme,
  required VoidCallback onChanged,
}) {
  final cs = ProfileTheme.themeFor(theme).colorScheme;
  final s = LocaleService.current;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: cs.surfaceContainerLow,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
    ),
    builder: (sheetCtx) => StatefulBuilder(builder: (ctx, setSheet) {
      final customTypes = pair.customRelationshipTypes;
      void pick(RelationshipType type, {String label = '', String emoji = ''}) {
        pair.setRelationshipType(type, label: label, emoji: emoji);
        Navigator.of(sheetCtx).pop();
        onChanged();
      }

      Widget builtin(RelationshipType type, IconData icon, String title,
              String subtitle) =>
          typeSheetOption(
              cs: cs,
              icon: icon,
              title: title,
              subtitle: subtitle,
              selected: pair.relationshipType == type,
              onTap: () => pick(type));

      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sheetHandle(cs),
                sheetHeader(cs, s.relationshipStatus, s.chooseHowToConnect),
                builtin(RelationshipType.couple, Icons.favorite_rounded,
                    s.inLoveStatus, s.perfectForCouples),
                builtin(RelationshipType.married, Icons.diamond_rounded,
                    s.married, s.forMarriedPartners),
                builtin(RelationshipType.friends, Icons.handshake_rounded,
                    s.friends, s.connectWithBestFriend),
                builtin(RelationshipType.buddies, Icons.groups_rounded,
                    s.bestBuddies, s.forInseparableCompanions),
                ...customTypes.map((entry) {
                  final selected =
                      pair.relationshipType == RelationshipType.custom &&
                          pair.relationshipLabel == entry['label'];
                  return typeSheetOption(
                    cs: cs,
                    icon: relIconForEmoji(entry['emoji'] ?? ''),
                    title: entry['label'] ?? s.custom,
                    subtitle: s.yourCustomType,
                    selected: selected,
                    onTap: () => pick(RelationshipType.custom,
                        label: entry['label'] ?? '',
                        emoji: entry['emoji'] ?? ''),
                    trailing: GestureDetector(
                      onTap: () async {
                        await pair
                            .deleteCustomRelationshipType(entry['id'] ?? '');
                        if (ctx.mounted) setSheet(() {});
                        onChanged();
                      },
                      child: Icon(Icons.delete_outline_rounded,
                          size: 22, color: cs.error),
                    ),
                  );
                }),
                const SizedBox(height: 4),
                PressableScale(
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    showAddCustomRelTypeSheet(context,
                        pair: pair, theme: theme, onChanged: onChanged);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_rounded,
                            size: 20, color: cs.onPrimaryContainer),
                        const SizedBox(width: 8),
                        Text(s.addCustomStatus,
                            style: TextStyle(
                                fontFamily: 'Onest',
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: cs.onPrimaryContainer)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }),
  );
}

void showAddCustomRelTypeSheet(
  BuildContext context, {
  required PairData pair,
  required AppTheme theme,
  required VoidCallback onChanged,
}) {
  final cs = ProfileTheme.themeFor(theme).colorScheme;
  final s = LocaleService.current;
  final labelCtrl = TextEditingController();
  int selectedIcon = 0;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: cs.surfaceContainerLow,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
    ),
    builder: (sheetCtx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 14, 20, 20 + MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sheetHandle(cs),
                sheetHeader(cs, s.addCustomStatus),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 6,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  children: List.generate(kRelIcons.length, (i) {
                    final sel = i == selectedIcon;
                    return GestureDetector(
                      onTap: () => setSheet(() => selectedIcon = i),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: sel ? cs.primary : cs.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(kRelIcons[i],
                            size: 24,
                            color: sel ? cs.onPrimary : cs.onSurfaceVariant),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: labelCtrl,
                  maxLength: 30,
                  textCapitalization: TextCapitalization.words,
                  style: const TextStyle(fontFamily: 'Onest'),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: cs.surfaceContainerHigh,
                    counterText: '',
                    hintText: s.egSoulmates,
                    labelText: s.label,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 54,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(
                          fontFamily: 'Onest',
                          fontWeight: FontWeight.w700,
                          fontSize: 16),
                    ),
                    onPressed: () async {
                      final label = labelCtrl.text.trim();
                      if (label.isEmpty) return;
                      await pair.addCustomRelationshipType(
                          label, kRelEmojis[selectedIcon]);
                      if (!context.mounted) return;
                      Navigator.of(sheetCtx).pop();
                      onChanged();
                      showRelationshipTypeSheet(context,
                          pair: pair, theme: theme, onChanged: onChanged);
                    },
                    child: Text(s.add),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Совместимость со старым вызовом из home_screen: тот же M3-лист.
void showRelationshipTypeDialog({
  required BuildContext context,
  required PairData pairData,
  required Color primary,
  required VoidCallback onStateChanged,
}) {
  showRelationshipTypeSheet(
    context,
    pair: pairData,
    theme: context.appTheme,
    onChanged: onStateChanged,
  );
}
