import 'package:flutter/material.dart';

import '../../models/gift.dart';
import '../../services/gift_result.dart';
import '../../services/gifts_service.dart';
import '../../services/locale_service.dart';
import '../../theme/app_theme.dart';

/// Витрина подарков: выбрал — списались монеты, партнёру улетел значок.
///
/// Баланс приходит снаружи и обновляется через [onCoins]: экран не ходит в
/// профиль сам, потому что источник истины по монетам — ответ серверного
/// роута, и он же возвращается из [GiftsService.send].
class GiftShopScreen extends StatefulWidget {
  const GiftShopScreen({
    super.key,
    required this.theme,
    required this.groupId,
    required this.coins,
    this.onCoins,
  });

  final AppTheme theme;
  final String groupId;
  final int coins;

  /// Новый баланс после отправки — чтобы главный экран не показывал старый.
  final ValueChanged<int>? onCoins;

  @override
  State<GiftShopScreen> createState() => _GiftShopScreenState();
}

class _GiftShopScreenState extends State<GiftShopScreen> {
  late int _coins = widget.coins;
  String? _sending;

  Future<void> _send(Gift gift) async {
    if (_sending != null) return; // второй тап во время отправки
    setState(() => _sending = gift.key);
    final res = await GiftsService.instance
        .send(groupId: widget.groupId, giftKey: gift.key);
    if (!mounted) return;

    final s = LocaleService.current;
    final text = res.ok
        ? s.giftSent
        : switch (res.error) {
            GiftError.insufficient => s.giftNotEnoughCoins,
            GiftError.network => s.giftNoConnection,
            _ => s.giftFailed,
          };
    setState(() {
      _sending = null;
      if (res.coins != null) _coins = res.coins!;
    });
    if (res.coins != null) widget.onCoins?.call(res.coins!);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
    if (res.ok) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final s = LocaleService.current;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          s.giftShopTitle,
          style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w800),
        ),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: t.textPrimary),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: Center(
              child: Text(
                '$_coins',
                style: TextStyle(
                  color: t.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
      ),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.86,
        ),
        itemCount: GiftCatalog.all.length,
        itemBuilder: (context, i) {
          final gift = GiftCatalog.all[i];
          final busy = _sending == gift.key;
          final affordable = _coins >= gift.price;
          return _GiftCard(
            theme: t,
            gift: gift,
            busy: busy,
            affordable: affordable,
            onTap: affordable && _sending == null ? () => _send(gift) : null,
          );
        },
      ),
    );
  }
}

class _GiftCard extends StatelessWidget {
  const _GiftCard({
    required this.theme,
    required this.gift,
    required this.busy,
    required this.affordable,
    this.onTap,
  });

  final AppTheme theme;
  final Gift gift;
  final bool busy;
  final bool affordable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: theme.cardSurface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Opacity(
                opacity: affordable ? 1 : 0.4,
                child: Image.asset(gift.asset, width: 84, height: 84),
              ),
              const SizedBox(height: 10),
              Text(
                '${gift.price}',
                style: TextStyle(
                  color: affordable ? theme.textPrimary : theme.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 2,
                child: busy
                    ? LinearProgressIndicator(
                        minHeight: 2,
                        backgroundColor: theme.cardSurface,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
