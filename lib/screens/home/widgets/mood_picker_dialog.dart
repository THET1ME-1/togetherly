import 'package:flutter/material.dart';
import '../../../theme/theme_scope.dart';
import '../../../widgets/mood_image.dart';
import 'package:flutter/services.dart';
import '../../../models/ailment.dart';
import '../../../models/mood_entry.dart';
import '../../../models/pair_data.dart';
import '../../../services/locale_service.dart';
import '../../../services/mood_pack_service.dart';
import '../../../services/mood_service.dart';
import '../../../services/widget_service.dart';
import '../../../widgets/mood_pack_selector.dart';

/// Shows mood picker bottom sheet for today's mood.
///
/// Все апдейты идут через [MoodService.setMoodForToday] — единая точка входа,
/// которая атомарно обновляет календарь + group memberMoods + widgetData.
/// Параметры pairData/widgetService оставлены ради обратной совместимости;
/// MoodService уже связан с ними через bindServices в home_screen.initState.
void showMoodPicker({
  required BuildContext context,
  required PairData pairData,
  required MoodService moodService,
  required WidgetService widgetService,
  required Color primary,
  required Color navActiveIcon,
}) {
  final mood = moodService.myMoodToday;
  final currentEmoji = mood?.imagePath ?? '';

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (ctx, scrollController) => _MoodPickerSheet(
        scrollController: scrollController,
        currentEmoji: currentEmoji,
        primary: primary,
        title: LocaleService.current.howAreYouFeeling,
        subtitle: LocaleService.current.partnerWillSeeMood,
        onSelect: (mood) {
          Navigator.pop(ctx);
          moodService.setMoodForToday(
            moodId: mood.id,
            imagePath: mood.imagePath,
            label: mood.localizedLabel,
          );
        },
        onClear: currentEmoji.isNotEmpty
            ? () async {
                Navigator.pop(ctx);
                await moodService.clearMoodForToday();
              }
            : null,
        // ── Вкладка «Самочувствие» (болячки) ──
        showAilmentTab: true,
        currentAilmentId: pairData.myAilment.id,
        onSelectAilment: (a) {
          Navigator.pop(ctx);
          pairData.setAilment(a.id, a.localizedLabel, a.emoji);
        },
        onClearAilment: pairData.myAilment.isNotEmpty
            ? () async {
                Navigator.pop(ctx);
                await pairData.clearAilment();
              }
            : null,
      ),
    ),
  );
}

/// Shows mood picker for a specific date.
/// Для сегодняшней даты использует [MoodService.setMoodForToday]
/// (атомарный апдейт всех трёх источников). Для прошлых — только календарь.
void showMoodPickerForDate({
  required BuildContext context,
  required DateTime date,
  required PairData pairData,
  required MoodService moodService,
  required WidgetService widgetService,
  required Color primary,
  required Color navActiveIcon,
}) {
  final today = DateTime.now();
  final todayNorm = DateTime(today.year, today.month, today.day);
  if (date.isAfter(todayNorm)) return;

  final isToday = date.year == today.year &&
      date.month == today.month &&
      date.day == today.day;

  final existingEntries = moodService.myEntriesForDay(date);
  final existingPath =
      existingEntries.isNotEmpty ? existingEntries.first.imagePath : '';

  final s = LocaleService.current;
  final months = s.shortMonths;
  final weekdays = s.shortWeekdays;
  final dateLabel = isToday
      ? s.todayDate
      : '${weekdays[date.weekday - 1]}, ${date.day} ${months[date.month - 1]}';

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (ctx, scrollController) => _MoodPickerSheet(
        scrollController: scrollController,
        currentEmoji: existingPath,
        primary: primary,
        title: s.moodDateLabel(dateLabel),
        subtitle: isToday ? s.partnerWillSeeMood : s.indicateMoodForDay,
        onSelect: (mood) {
          Navigator.pop(ctx);
          moodService.setMoodForDate(
            date: date,
            moodId: mood.id,
            imagePath: mood.imagePath,
            label: mood.localizedLabel,
          );
        },
        onClear: existingPath.isNotEmpty
            ? () async {
                Navigator.pop(ctx);
                await moodService.clearMoodForDate(date);
              }
            : null,
        // Самочувствие — текущий статус, не история: вкладка только для сегодня.
        showAilmentTab: isToday,
        currentAilmentId: isToday ? pairData.myAilment.id : '',
        onSelectAilment: isToday
            ? (a) {
                Navigator.pop(ctx);
                pairData.setAilment(a.id, a.localizedLabel, a.emoji);
              }
            : null,
        onClearAilment: (isToday && pairData.myAilment.isNotEmpty)
            ? () async {
                Navigator.pop(ctx);
                await pairData.clearAilment();
              }
            : null,
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  Shared bottom-sheet widget
// ─────────────────────────────────────────────────────────────────────────────

class _MoodPickerSheet extends StatefulWidget {
  final ScrollController scrollController;
  final String currentEmoji;
  final Color primary;
  final String title;
  final String subtitle;
  final void Function(MoodOption) onSelect;
  final Future<void> Function()? onClear;

  // ── Вкладка «Самочувствие» (опционально) ──
  final bool showAilmentTab;
  final String currentAilmentId;
  final void Function(Ailment)? onSelectAilment;
  final Future<void> Function()? onClearAilment;

  const _MoodPickerSheet({
    required this.scrollController,
    required this.currentEmoji,
    required this.primary,
    required this.title,
    required this.subtitle,
    required this.onSelect,
    required this.onClear,
    this.showAilmentTab = false,
    this.currentAilmentId = '',
    this.onSelectAilment,
    this.onClearAilment,
  });

  @override
  State<_MoodPickerSheet> createState() => _MoodPickerSheetState();
}

class _MoodPickerSheetState extends State<_MoodPickerSheet> {
  int _tab = 0; // 0 — настроение, 1 — самочувствие

  @override
  void initState() {
    super.initState();
    // Загрузить сохранённый выбор пака (идемпотентно); AnimatedBuilder ниже
    // перестроит сетку, когда значение подгрузится/изменится.
    MoodPackService.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final t = context.appTheme;
    final onAilment = widget.showAilmentTab && _tab == 1;
    return Container(
      decoration: BoxDecoration(
        color: t.cardSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: t.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          if (widget.showAilmentTab) ...[
            _segmented(s),
            const SizedBox(height: 10),
            Text(
              onAilment ? s.ailmentPickerSubtitle : widget.subtitle,
              style: TextStyle(fontSize: 13, color: t.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              widget.title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: t.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.subtitle,
              style: TextStyle(fontSize: 13, color: t.textMuted),
            ),
            const SizedBox(height: 14),
          ],
          // Body
          Expanded(child: onAilment ? _ailmentGrid() : _moodBody()),
          // Clear button (зависит от вкладки)
          _clearButton(s, onAilment),
        ],
      ),
    );
  }

  Widget _segmented(AppStrings s) {
    final t = context.appTheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _segBtn(s.moodTabLabel, 0),
          _segBtn(s.ailmentTabLabel, 1),
        ],
      ),
    );
  }

  Widget _segBtn(String label, int idx) {
    final active = _tab == idx;
    final t = context.appTheme;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = idx),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: active ? t.cardSurface : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: active ? widget.primary : t.textMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _moodBody() {
    return Column(
      children: [
        MoodPackSelector(
          primary: widget.primary,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: AnimatedBuilder(
            animation: MoodPackService.instance,
            builder: (context, _) {
              final pack = MoodPackService.instance.selectedPack;
              return GridView.builder(
                controller: widget.scrollController,
                padding: const EdgeInsets.only(bottom: 16),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.68,
                ),
                itemCount: pack.moods.length,
                itemBuilder: (_, i) {
                  final mood = pack.moods[i];
                  final isSelected = widget.currentEmoji == mood.imagePath;
                  return _MoodTile(
                    mood: mood,
                    isSelected: isSelected,
                    primary: widget.primary,
                    tileGradient: pack.tileGradient,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      widget.onSelect(mood);
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _ailmentGrid() {
    return GridView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.82,
      ),
      itemCount: kAilments.length,
      itemBuilder: (_, i) {
        final a = kAilments[i];
        final isSelected = widget.currentAilmentId == a.id;
        return _AilmentTile(
          ailment: a,
          isSelected: isSelected,
          primary: widget.primary,
          onTap: () {
            HapticFeedback.lightImpact();
            widget.onSelectAilment?.call(a);
          },
        );
      },
    );
  }

  Widget _clearButton(AppStrings s, bool onAilment) {
    final onClear = onAilment ? widget.onClearAilment : widget.onClear;
    if (onClear == null) return const SizedBox(height: 16);
    final t = context.appTheme;
    final label = onAilment ? s.clearAilment : s.clearMood;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextButton(
          onPressed: onClear,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: t.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Single emoji tile
// ─────────────────────────────────────────────────────────────────────────────

class _MoodTile extends StatelessWidget {
  final MoodOption mood;
  final bool isSelected;
  final Color primary;

  /// Подложка для паков с прозрачными стикерами (напр. розовый). null —
  /// картинка непрозрачная и заполняет плитку сама (классический пак).
  final List<Color>? tileGradient;
  final VoidCallback onTap;

  static const double _radius = 16;

  const _MoodTile({
    required this.mood,
    required this.isSelected,
    required this.primary,
    required this.onTap,
    this.tileGradient,
  });

  @override
  Widget build(BuildContext context) {
    final gradient = tileGradient;
    final t = context.appTheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1.0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_radius),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: mood.color.withValues(alpha: 0.55),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_radius),
                child: Container(
                  // Мягкий фон под прозрачными стикерами; для классики gradient
                  // == null и непрозрачная картинка перекрывает белый фон.
                  decoration: BoxDecoration(
                    color: gradient == null ? null : Colors.white,
                    gradient: gradient != null
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: gradient,
                          )
                        : null,
                  ),
                  child: mood.imagePath.isNotEmpty
                      ? MoodImage(
                          mood.imagePath,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                        )
                      : Container(color: mood.color),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            mood.localizedLabel,
            style: TextStyle(
              fontSize: 10,
              fontWeight:
                  isSelected ? FontWeight.w700 : FontWeight.w500,
              color: isSelected ? primary : t.textSecondary,
              height: 1.2,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.visible,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Single ailment tile (emoji-based, no asset pipeline)
// ─────────────────────────────────────────────────────────────────────────────

class _AilmentTile extends StatelessWidget {
  final Ailment ailment;
  final bool isSelected;
  final Color primary;
  final VoidCallback onTap;

  const _AilmentTile({
    required this.ailment,
    required this.isSelected,
    required this.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1.0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                color: isSelected
                    ? primary.withValues(alpha: 0.14)
                    : t.surfaceMuted,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? primary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Center(
                child: Text(
                  ailment.emoji,
                  style: const TextStyle(fontSize: 28),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            ailment.localizedLabel,
            style: TextStyle(
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              color: isSelected ? primary : t.textSecondary,
              height: 1.2,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.visible,
          ),
        ],
      ),
    );
  }
}
