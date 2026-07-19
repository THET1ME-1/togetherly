import 'package:flutter/material.dart';

import '../services/locale_service.dart';
import '../theme/theme_scope.dart';

/// Интерактивный выбор оценки 1–10 (как на карточке отзыва Кинопоиска).
///
/// Стильная горизонтальная шкала из 10 «таблеток»: заполняются акцентным
/// цветом до выбранного значения, сверху — крупная цифра и словесная оценка
/// («Шедевр», «Отлично», …). Повторный тап по выбранному значению сбрасывает.
class RatingPicker extends StatelessWidget {
  final int? value; // 1..10 или null
  final ValueChanged<int?> onChanged;
  final Color accent;

  const RatingPicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final t = context.appTheme;
    final v = value;
    final color = v == null ? accent : _colorFor(v);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Заголовок + крупная цифра ──
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.star_rounded, size: 16, color: accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                s.yourRating,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: t.textPrimary,
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (c, a) =>
                  ScaleTransition(scale: a, child: c),
              child: v == null
                  ? Text(
                      s.ratingNotRated,
                      key: const ValueKey('none'),
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: t.textMuted,
                      ),
                    )
                  : Row(
                      key: ValueKey(v),
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          '$v',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: color,
                            height: 1,
                          ),
                        ),
                        Text(
                          ' / 10',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: t.textMuted,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // ── Шкала 1–10 ──
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 5.0;
            final segW = (constraints.maxWidth - gap * 9) / 10;
            return Row(
              children: [
                for (int i = 1; i <= 10; i++) ...[
                  if (i > 1) const SizedBox(width: gap),
                  _Segment(
                    index: i,
                    width: segW,
                    filled: v != null && i <= v,
                    fillColor: color,
                    onTap: () => onChanged(v == i ? null : i),
                  ),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        // ── Словесная оценка ──
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            v == null ? s.ratingHint : _labelFor(v, s),
            key: ValueKey(v ?? 0),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: v == null ? t.textMuted : color,
            ),
          ),
        ),
      ],
    );
  }

  static Color _colorFor(int v) {
    if (v <= 3) return const Color(0xFFEF4444); // красный
    if (v <= 5) return const Color(0xFFF59E0B); // оранжевый
    if (v <= 7) return const Color(0xFFEAB308); // жёлтый
    return const Color(0xFF22C55E); // зелёный
  }

  static String _labelFor(int v, AppStrings s) {
    switch (v) {
      case 10:
        return s.ratingMasterpiece;
      case 9:
      case 8:
        return s.ratingExcellent;
      case 7:
      case 6:
        return s.ratingGood;
      case 5:
      case 4:
        return s.ratingMixed;
      case 3:
      case 2:
        return s.ratingBad;
      default:
        return s.ratingAwful;
    }
  }
}

class _Segment extends StatelessWidget {
  final int index;
  final double width;
  final bool filled;
  final Color fillColor;
  final VoidCallback onTap;

  const _Segment({
    required this.index,
    required this.width,
    required this.filled,
    required this.fillColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: width,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? fillColor : t.surfaceMuted,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: filled ? fillColor : t.divider,
            width: 1,
          ),
        ),
        child: Text(
          '$index',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: filled ? Colors.white : t.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Компактный read-only бейдж оценки: «★ 8/10» в акцентной плашке.
class RatingBadge extends StatelessWidget {
  final int rating; // 1..10
  final double fontSize;

  const RatingBadge({super.key, required this.rating, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    final color = RatingPicker._colorFor(rating);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: fontSize * 0.62,
        vertical: fontSize * 0.25,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: fontSize + 2, color: color),
          SizedBox(width: fontSize * 0.3),
          Text(
            '$rating/10',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
