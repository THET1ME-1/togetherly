import 'package:flutter/material.dart';

import '../../models/partner_profile.dart';
import '../../widgets/avatar_widget.dart';
import '../../services/locale_service.dart';
import '../../services/pb_data_service.dart';
import '../../theme/app_theme.dart';

/// Профиль партнёра: что ему дарили и по каким дням он скучает.
///
/// Оформление — «Открытка»: тёплая шапка, полка подарков со счётчиками,
/// столбики по дням недели с подсветкой пика.
class PartnerProfileScreen extends StatefulWidget {
  const PartnerProfileScreen({
    super.key,
    required this.theme,
    required this.groupId,
    required this.partnerUid,
    required this.partnerName,
    this.partnerAvatarUrl,
    this.daysTogether,
  });

  final AppTheme theme;
  final String groupId;
  final String partnerUid;
  final String partnerName;
  final String? partnerAvatarUrl;
  final int? daysTogether;

  @override
  State<PartnerProfileScreen> createState() => _PartnerProfileScreenState();
}

class _PartnerProfileScreenState extends State<PartnerProfileScreen> {
  List<GiftTally> _shelf = const [];
  WeekStats _week = const WeekStats([0, 0, 0, 0, 0, 0, 0]);
  int _giftsTotal = 0;
  int _missTotal = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = PbDataService();
    final gifts = await data.fetchGiftsFor(
        groupId: widget.groupId, uid: widget.partnerUid);
    final miss = await data.fetchMissYouFor(
        groupId: widget.groupId, uid: widget.partnerUid);
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.partnerName,
            style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w800)),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: t.textPrimary),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  _Hero(
                    theme: t,
                    uid: widget.partnerUid,
                    name: widget.partnerName,
                    avatarUrl: widget.partnerAvatarUrl,
                    daysTogether: widget.daysTogether,
                    gifts: _giftsTotal,
                    miss: _missTotal,
                  ),
                  const SizedBox(height: 20),
                  _Block(
                    theme: t,
                    title: s.partnerGiftsTitle,
                    trailing: _giftsTotal > 0 ? '$_giftsTotal' : null,
                    child: _shelf.isEmpty
                        ? _Empty(theme: t, text: s.partnerGiftsEmpty)
                        : _Shelf(theme: t, shelf: _shelf),
                  ),
                  const SizedBox(height: 20),
                  _Block(
                    theme: t,
                    title: s.partnerMissTitle,
                    child: _week.isEmpty
                        ? _Empty(theme: t, text: s.partnerMissEmpty)
                        : _WeekChart(theme: t, week: _week),
                  ),
                ],
              ),
            ),
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
    required this.gifts,
    required this.miss,
  });

  final AppTheme theme;
  final String uid;
  final String name;
  final String? avatarUrl;
  final int? daysTogether;
  final int gifts;
  final int miss;

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
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
          // AvatarWidget сам разбирается с форматом ссылки и кэшем: свой
          // NetworkImage показывал пустой круг на аватарах из группы.
          Container(
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
          ),
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
              _Chip(theme: theme, text: s.partnerGiftsChip(gifts)),
              _Chip(theme: theme, text: s.partnerMissChip(miss)),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: theme.cardSurface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: theme.divider, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: theme.textPrimary)),
              ),
              if (trailing != null)
                Text(trailing!,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: theme.textMuted)),
            ],
          ),
          const SizedBox(height: 12),
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
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 96,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: shelf.length,
      itemBuilder: (context, i) {
        final t = shelf[i];
        return Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: theme.surfaceMuted,
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: Image.asset(t.gift.asset, width: 52, height: 52),
            ),
            if (t.count > 1)
              Positioned(
                right: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.primary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('${t.count}',
                      style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _WeekChart extends StatelessWidget {
  const _WeekChart({required this.theme, required this.week});

  final AppTheme theme;
  final WeekStats week;

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final max = week.byDay.reduce((a, b) => a > b ? a : b);
    final top = week.topDay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 122,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(7, (i) {
              final v = week.byDay[i];
              final isTop = top == i + 1;
              final ratio = max == 0 ? 0.0 : v / max;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(v == 0 ? '' : '$v',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isTop ? theme.primary : theme.textMuted)),
                      const SizedBox(height: 4),
                      Container(
                        height: 8 + ratio * 74,
                        decoration: BoxDecoration(
                          color: isTop
                              ? theme.primary
                              : theme.primary.withValues(alpha: 0.22),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(10),
                            bottom: Radius.circular(6),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(s.weekdayShort(i + 1),
                          style: TextStyle(
                              fontSize: 11.5, color: theme.textSecondary)),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
        if (top != null) ...[
          const SizedBox(height: 10),
          Text(s.partnerMissPeak(s.weekdayLong(top)),
              style: TextStyle(fontSize: 12.5, color: theme.textSecondary)),
        ],
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.theme, required this.text});

  final AppTheme theme;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(text,
          style: TextStyle(fontSize: 13.5, color: theme.textSecondary)),
    );
  }
}
