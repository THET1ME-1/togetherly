import 'package:flutter/material.dart';

import '../../services/locale_service.dart';
import '../../services/pb_data_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/profile_theme.dart';
import '../profile/profile_hero.dart';
import 'gift_profile_body.dart';

/// Свой профиль-«Открытка»: та же шапка [ProfileHero] и тело [GiftProfileBody],
/// что и у партнёра ([PartnerProfileScreen]), только со своими данными и
/// `isSelf: true` — полка полученных подарков и столбики «Я скучаю» по дням.
class SelfProfileScreen extends StatefulWidget {
  const SelfProfileScreen({
    super.key,
    required this.theme,
    required this.groupId,
    required this.selfUid,
    required this.selfName,
    this.selfAvatarUrl,
    this.bannerUrl = '',
    this.daysTogether,
  });

  final AppTheme theme;
  final String groupId;
  final String selfUid;
  final String selfName;
  final String? selfAvatarUrl;
  final String bannerUrl;
  final int? daysTogether;

  @override
  State<SelfProfileScreen> createState() => _SelfProfileScreenState();
}

class _SelfProfileScreenState extends State<SelfProfileScreen> {
  // Ключ в поле, а не в build(): pull-to-refresh иначе пересоздавал бы тело и
  // сбрасывал загруженные данные (как в [PartnerProfileScreen]).
  final _bodyKey = GlobalKey<GiftProfileBodyState>();
  late String _bannerUrl = widget.bannerUrl;

  @override
  void initState() {
    super.initState();
    if (_bannerUrl.isEmpty) _loadBanner();
  }

  Future<void> _loadBanner() async {
    final m = await PbDataService().loadUserProfileMap(widget.selfUid);
    if (!mounted || m == null) return;
    final b = (m['bannerUrl'] as String?) ?? '';
    if (b != _bannerUrl) setState(() => _bannerUrl = b);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final cs = ProfileTheme.themeFor(t).colorScheme;
    final days = widget.daysTogether;
    final subtitle =
        days != null ? LocaleService.current.partnerDaysTogether(days) : '';
    return Scaffold(
      backgroundColor: cs.surface,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: cs.onSurface),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadBanner();
          await (_bodyKey.currentState?.reload() ?? Future.value());
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            ProfileHero(
              cs: cs,
              uid: widget.selfUid,
              avatarUrl: widget.selfAvatarUrl ?? '',
              name: widget.selfName,
              bannerUrl: _bannerUrl,
              subtitle: subtitle,
            ),
            const SizedBox(height: 52),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GiftProfileBody(
                key: _bodyKey,
                theme: t,
                groupId: widget.groupId,
                uid: widget.selfUid,
                name: widget.selfName,
                avatarUrl: widget.selfAvatarUrl,
                daysTogether: widget.daysTogether,
                isSelf: true,
                showHeader: false, // шапку даёт ProfileHero выше
              ),
            ),
          ],
        ),
      ),
    );
  }
}
