import 'package:flutter/material.dart';

import '../../services/locale_service.dart';
import '../../services/pb_data_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/profile_theme.dart';
import '../profile/profile_hero.dart';
import 'gift_profile_body.dart';

/// Профиль партнёра в том же виде, что и наш: общая шапка [ProfileHero]
/// (серверный баннер + аватар + имя/дни), только показ. Ниже — «Открытка»
/// [GiftProfileBody]: полка подарков и столбики по дням недели «Я скучаю».
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
  // Ключ живёт в поле, а не в build(): иначе pull-to-refresh пересоздавал бы
  // состояние тела на каждой перестройке и сбрасывал загруженные данные.
  final _bodyKey = GlobalKey<GiftProfileBodyState>();
  String _bannerUrl = '';

  @override
  void initState() {
    super.initState();
    _loadBanner();
  }

  Future<void> _loadBanner() async {
    final m = await PbDataService().loadUserProfileMap(widget.partnerUid);
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
              uid: widget.partnerUid,
              avatarUrl: widget.partnerAvatarUrl ?? '',
              name: widget.partnerName,
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
                uid: widget.partnerUid,
                name: widget.partnerName,
                avatarUrl: widget.partnerAvatarUrl,
                daysTogether: widget.daysTogether,
                showHeader: false, // шапку даёт ProfileHero выше
              ),
            ),
          ],
        ),
      ),
    );
  }
}
