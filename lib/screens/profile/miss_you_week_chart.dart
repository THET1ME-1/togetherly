import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import '../../models/partner_profile.dart';
import '../../services/locale_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/profile_theme.dart';
import '../../widgets/connect_expressive.dart';

/// Столбики «Я скучаю» по дням недели — капсулы (полностью круглые). Пиковый
/// день выделен полным цветом темы и бейджем-звёздочкой с галочкой; остальные —
/// тональный цвет темы. При появлении столбики по очереди растут снизу вверх.
/// Общий для своего профиля и профиля партнёра.
class MissYouWeekChart extends StatefulWidget {
  final WeekStats week;
  final AppTheme theme;
  const MissYouWeekChart({super.key, required this.week, required this.theme});

  @override
  State<MissYouWeekChart> createState() => _MissYouWeekChartState();
}

class _MissYouWeekChartState extends State<MissYouWeekChart>
    with SingleTickerProviderStateMixin {
  static const double _area = 152;
  static const double _barMax = 108;
  static const double _barMin = 16;

  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 950))
      ..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final cs = ProfileTheme.themeFor(widget.theme).colorScheme;
    final week = widget.week;
    final max = week.byDay.reduce((a, b) => a > b ? a : b);
    final top = week.topDay; // 1..7 или null

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _area,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(7, (i) {
              final v = week.byDay[i];
              final peak = max > 0 && v == max;
              final ratio = max == 0 ? 0.0 : v / max;
              final h = _barMin + ratio * _barMax;
              // Стаггер: каждый следующий столбик стартует позже.
              final anim = CurvedAnimation(
                parent: _ctrl,
                curve: Interval((i * 0.08).clamp(0.0, 1.0),
                    (i * 0.08 + 0.5).clamp(0.0, 1.0),
                    curve: Curves.easeOutCubic),
              );
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedBuilder(
                      animation: anim,
                      builder: (context, _) {
                        final t = anim.value;
                        return SizedBox(
                          height: h * t,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: peak
                                        ? cs.primary
                                        : cs.primary.withValues(alpha: 0.20),
                                    borderRadius: BorderRadius.circular(40),
                                  ),
                                ),
                              ),
                              if (peak)
                                Positioned(
                                  top: -18,
                                  left: 0,
                                  right: 0,
                                  child: Opacity(
                                    opacity: ((t - 0.75) / 0.25).clamp(0.0, 1.0),
                                    child: Center(
                                        child: _Badge(check: cs.primary)),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: List.generate(7, (i) {
            final peak = max > 0 && week.byDay[i] == max;
            return Expanded(
              child: Center(
                child: Text(
                  s.weekdayShort(i + 1),
                  style: TextStyle(
                    fontFamily: ProfileTheme.bodyFont,
                    fontSize: 12,
                    fontWeight: peak ? FontWeight.w700 : FontWeight.w500,
                    color: peak ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }),
        ),
        if (top != null && max > 0) ...[
          const SizedBox(height: 12),
          Text(
            s.partnerMissPeak(s.weekdayLong(top)),
            style: TextStyle(
              fontFamily: ProfileTheme.bodyFont,
              fontSize: 12.5,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// Бейдж пика: белая звёздочка M3 (sunny) с галочкой цвета темы.
class _Badge extends StatelessWidget {
  final Color check;
  const _Badge({required this.check});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipPath(
            clipper: M3ShapeClipper(MaterialShapes.sunny),
            child: const ColoredBox(color: Colors.white),
          ),
          Icon(Icons.check_rounded, size: 19, color: check),
        ],
      ),
    );
  }
}
