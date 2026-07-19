import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/mood_pack.dart';
import '../services/catalog_service.dart';
import '../services/mood_pack_service.dart';
import '../theme/theme_scope.dart';
import 'mood_image.dart';

/// Горизонтальный селектор паков настроений для пикера.
///
/// Слушает [MoodPackService] и переключает выбранный пак. Бесплатные паки
/// доступны сразу; платные (если появятся) показывают замочек и не выбираются.
class MoodPackSelector extends StatelessWidget {
  final Color primary;

  /// Вызывается после смены пака (родитель обновляет сетку настроений).
  final ValueChanged<MoodPack>? onChanged;

  const MoodPackSelector({
    super.key,
    required this.primary,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
        [MoodPackService.instance, CatalogService.instance],
      ),
      builder: (context, _) {
        final selectedId = MoodPackService.instance.selectedPackId;
        final packs = CatalogService.instance.allPacks;
        return SizedBox(
          height: 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: packs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final pack = packs[i];
              return _PackChip(
                pack: pack,
                selected: pack.id == selectedId,
                primary: primary,
                onTap: () {
                  if (pack.id == selectedId) return;
                  HapticFeedback.selectionClick();
                  MoodPackService.instance.setSelectedPack(pack.id);
                  onChanged?.call(pack);
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _PackChip extends StatelessWidget {
  final MoodPack pack;
  final bool selected;
  final Color primary;
  final VoidCallback onTap;

  const _PackChip({
    required this.pack,
    required this.selected,
    required this.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    final gradient = pack.tileGradient;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
        decoration: BoxDecoration(
          color: selected ? primary.withValues(alpha: 0.10) : t.surfaceMuted,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? primary : Colors.transparent,
            width: 1.6,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Превью пака.
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: gradient != null
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradient,
                      )
                    : null,
                color: gradient == null ? Colors.white : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: pack.previewImage.isNotEmpty
                  ? Padding(
                      padding: gradient != null
                          ? const EdgeInsets.all(2)
                          : EdgeInsets.zero,
                      child: MoodImage(
                        pack.previewImage,
                        fit: BoxFit.cover,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            Text(
              pack.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? primary : t.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
