import 'package:flutter/material.dart';
import '../profile/miss_you_week_chart.dart';
import '../../theme/profile_theme.dart';

import '../../models/partner_profile.dart';
import '../../widgets/avatar_widget.dart';
import '../../services/locale_service.dart';
import '../../services/pb_data_service.dart';
import '../../theme/app_theme.dart';

/// Тело профиля-«Открытки»: шапка с аватаром и чипами, полка подарков со
/// счётчиками, столбики «скучаю» по дням недели.
///
/// Один и тот же виджет обслуживает экран партнёра ([isSelf] = false) и личный
/// профиль на странице «Профиль» ([isSelf] = true) — меняются лишь заголовки и
/// возможность тапнуть по аватару, чтобы отредактировать свой профиль.
/// Данные грузятся по [uid]: подарки, полученные этим человеком, и его дни
/// «скучаю». Возвращает [Column] без собственной прокрутки — родитель сам
/// решает, обернуть ли в [ListView]/[RefreshIndicator] или встроить в скролл.
class GiftProfileBody extends StatefulWidget {
  const GiftProfileBody({
    super.key,
    required this.theme,
    required this.groupId,
    required this.uid,
    required this.name,
    this.avatarUrl,
    this.daysTogether,
    this.isSelf = false,
    this.onAvatarTap,
    this.showHeader = true,
  });

  final AppTheme theme;
  final String groupId;
  final String uid;
  final String name;
  final String? avatarUrl;
  final int? daysTogether;

  /// true — личный профиль (свои данные, тап по аватару правит профиль).
  final bool isSelf;

  /// Тап по аватару (для личного профиля — открыть редактирование).
  final VoidCallback? onAvatarTap;

  /// false — не рисовать внутреннюю шапку (её даёт ProfileHero сверху).
  final bool showHeader;

  @override
  State<GiftProfileBody> createState() => GiftProfileBodyState();
}

/// Публичен, чтобы родитель мог дёрнуть [reload] из [RefreshIndicator].
class GiftProfileBodyState extends State<GiftProfileBody> {
  List<GiftTally> _shelf = const [];
  WeekStats _week = const WeekStats([0, 0, 0, 0, 0, 0, 0]);
  int _giftsTotal = 0;
  int _missTotal = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final data = PbDataService();
    final gifts =
        await data.fetchGiftsFor(groupId: widget.groupId, uid: widget.uid);
    final miss =
        await data.fetchMissYouFor(groupId: widget.groupId, uid: widget.uid);
    if (!mounted) return;
    setState(() {
      _shelf = tallyGifts(gifts);
      _giftsTotal = gifts.length;
      _week = parseWeekdays(miss?['by_weekday'] as String?);
      _missTotal = (miss?['count'] as num?)?.toInt() ?? 0;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final s = LocaleService.current;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      children: [
        if (widget.showHeader) ...[
          _Hero(
            theme: t,
            uid: widget.uid,
            name: widget.name,
            avatarUrl: widget.avatarUrl,
            daysTogether: widget.daysTogether,
            giftsChip: s.partnerGiftsChip(_giftsTotal),
            missChip: s.partnerMissChip(_missTotal),
            onAvatarTap: widget.onAvatarTap,
          ),
          const SizedBox(height: 20),
        ],
        _Block(
          theme: t,
          title: widget.isSelf ? s.selfGiftsTitle : s.partnerGiftsTitle,
          trailing: _giftsTotal > 0 ? '$_giftsTotal' : null,
          child: _shelf.isEmpty
              ? _Empty(theme: t, text: s.partnerGiftsEmpty)
              : _Shelf(theme: t, shelf: _shelf),
        ),
        const SizedBox(height: 20),
        _Block(
          theme: t,
          title: widget.isSelf ? s.selfMissTitle : s.partnerMissTitle,
          child: _week.isEmpty
              ? _Empty(theme: t, text: s.partnerMissEmpty)
              : MissYouWeekChart(theme: t, week: _week),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.theme,
    required this.uid,
    required this.name,
    required this.avatarUrl,
    required this.daysTogether,
    required this.giftsChip,
    required this.missChip,
    this.onAvatarTap,
  });

  final AppTheme theme;
  final String uid;
  final String name;
  final String? avatarUrl;
  final int? daysTogether;
  final String giftsChip;
  final String missChip;
  final VoidCallback? onAvatarTap;

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    // AvatarWidget сам разбирается с форматом ссылки и кэшем: свой
    // NetworkImage показывал пустой круг на аватарах из группы.
    Widget avatar = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.cardSurface,
      ),
      child: AvatarWidget(
        uid: uid,
        liveUrl: avatarUrl,
        name: name,
        size: 82,
        primary: theme.primary,
      ),
    );
    if (onAvatarTap != null) {
      avatar = GestureDetector(onTap: onAvatarTap, child: avatar);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            theme.primary.withValues(alpha: 0.18),
            theme.primary.withValues(alpha: 0.06),
          ],
        ),
      ),
      child: Column(
        children: [
          avatar,
          const SizedBox(height: 10),
          Text(name,
              style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: theme.textPrimary)),
          if (daysTogether != null) ...[
            const SizedBox(height: 2),
            Text(s.partnerDaysTogether(daysTogether!),
                style: TextStyle(fontSize: 13.5, color: theme.textSecondary)),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _Chip(theme: theme, text: giftsChip),
              _Chip(theme: theme, text: missChip),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.theme, required this.text});

  final AppTheme theme;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.cardSurface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: theme.textPrimary)),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({
    required this.theme,
    required this.title,
    required this.child,
    this.trailing,
  });

  final AppTheme theme;
  final String title;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = ProfileTheme.themeFor(theme).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontFamily: ProfileTheme.bodyFont,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface)),
              ),
              if (trailing != null)
                Text(trailing!,
                    style: TextStyle(
                        fontFamily: ProfileTheme.displayFont,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: cs.primary)),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _Shelf extends StatelessWidget {
  const _Shelf({required this.theme, required this.shelf});

  final AppTheme theme;
  final List<GiftTally> shelf;

  @override
  Widget build(BuildContext context) {
    final cs = ProfileTheme.themeFor(theme).colorScheme;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: shelf.map((t) {
        return SizedBox(
          width: 76,
          height: 76,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(22),
                ),
                alignment: Alignment.center,
                child: Image.asset(t.gift.asset, width: 46, height: 46),
              ),
              if (t.count > 1)
                Positioned(
                  right: -3,
                  top: -3,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('${t.count}',
                        style: TextStyle(
                            fontFamily: ProfileTheme.displayFont,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: cs.onPrimary)),
                  ),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.theme, required this.text});

  final AppTheme theme;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = ProfileTheme.themeFor(theme).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(text,
          style: TextStyle(
              fontFamily: ProfileTheme.bodyFont,
              fontSize: 13.5,
              color: cs.onSurfaceVariant)),
    );
  }
}
