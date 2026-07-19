import 'package:flutter/material.dart';

import '../models/pair_achievement.dart';
import '../services/achievement_service.dart';
import '../services/locale_service.dart';
import '../theme/app_theme.dart';

/// Экран «Достижения пары»: сетка всех достижений — открытые в цвете уровня,
/// закрытые приглушены с прогрессом. Живёт на снимке счётчиков
/// [AchievementService.stats] (обновляется в реальном времени).
class AchievementsScreen extends StatelessWidget {
  final AppTheme theme;

  const AchievementsScreen({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.achievementsTitle,
          style: TextStyle(
            color: theme.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: theme.textPrimary),
      ),
      body: ValueListenableBuilder<AchievementStats>(
        valueListenable: AchievementService.instance.stats,
        builder: (context, stats, _) {
          final unlocked =
              PairAchievement.all.where((a) => a.isUnlockedBy(stats)).length;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _header(unlocked)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                sliver: SliverGrid(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.82,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) =>
                        _AchievementCard(theme: theme, a: PairAchievement.all[i], stats: stats),
                    childCount: PairAchievement.all.length,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(int unlocked) {
    final total = PairAchievement.all.length;
    final ratio = total == 0 ? 0.0 : unlocked / total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            LocaleService.current.achievementsUnlockedOf(unlocked, total),
            style: TextStyle(
              color: theme.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: theme.surfaceMuted,
              valueColor: AlwaysStoppedAnimation<Color>(theme.primary),
            ),
          ),
        ],
      ),
    );
  }
}

class _AchievementCard extends StatelessWidget {
  final AppTheme theme;
  final PairAchievement a;
  final AchievementStats stats;

  const _AchievementCard({
    required this.theme,
    required this.a,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final unlocked = a.isUnlockedBy(stats);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.cardSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: unlocked
              ? a.tierColor.withValues(alpha: 0.5)
              : theme.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Медаль
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: unlocked
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: a.tierGradient,
                    )
                  : null,
              color: unlocked ? null : theme.surfaceMuted,
              boxShadow: unlocked
                  ? [
                      BoxShadow(
                        color: a.tierColor.withValues(alpha: 0.4),
                        blurRadius: 14,
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Opacity(
              opacity: unlocked ? 1 : 0.35,
              child: Text(a.emoji, style: const TextStyle(fontSize: 32)),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            a.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            a.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.textMuted,
              fontSize: 11.5,
              height: 1.25,
            ),
          ),
          const Spacer(),
          const SizedBox(height: 8),
          if (unlocked)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_rounded,
                    size: 15, color: a.tierColor),
                const SizedBox(width: 4),
                Text(
                  LocaleService.current.achievementDone,
                  style: TextStyle(
                    color: a.tierColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            )
          else
            _progress(),
        ],
      ),
    );
  }

  Widget _progress() {
    final cur = a.currentValue(stats);
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: a.progress(stats),
            minHeight: 6,
            backgroundColor: theme.surfaceMuted,
            valueColor: AlwaysStoppedAnimation<Color>(
              theme.primary.withValues(alpha: 0.7),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$cur / ${a.threshold}',
          style: TextStyle(
            color: theme.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
