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
  /// Тестовая сборка (`--dart-define=GIFTS_FORCE=true`) показывает код отказа.
  static const bool _diagnostics = bool.fromEnvironment('GIFTS_FORCE');

  late int _coins = widget.coins;
  String? _sending;

  Future<void> _send(Gift gift) async {
    if (_sending != null) return; // второй тап во время отправки

    String? note;
    if (gift.carriesNote) {
      note = await _askNote(gift);
      if (note == null) return; // передумал на вводе записки
    }

    setState(() => _sending = gift.key);
    final res = await GiftsService.instance
        .send(groupId: widget.groupId, giftKey: gift.key, note: note);
    if (!mounted) return;

    final s = LocaleService.current;
    var text = res.ok
        ? s.giftSent
        : switch (res.error) {
            GiftError.insufficient => s.giftNotEnoughCoins,
            GiftError.network => s.giftNoConnection,
            _ => s.giftFailed,
          };
    // В тестовой сборке показываем код причины: без него отказ выглядит как
    // «просто не работает», и чинить нечего.
    if (!res.ok && _diagnostics && res.error != null) {
      text = '$text (${res.error!.name})';
    }
    setState(() {
      _sending = null;
      if (res.coins != null) _coins = res.coins!;
    });
    if (res.coins != null) widget.onCoins?.call(res.coins!);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
    if (res.ok) Navigator.of(context).pop();
  }

  /// Записка внутрь коробки, печенья или письма. null = отменил отправку.
  Future<String?> _askNote(Gift gift) async {
    final t = widget.theme;
    final s = LocaleService.current;
    final ctrl = TextEditingController();
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: t.cardSurface,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Image.asset(gift.asset, width: 44, height: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(gift.title,
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: t.textPrimary)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                maxLength: 500,
                maxLines: 4,
                minLines: 2,
                autofocus: true,
                style: TextStyle(color: t.textPrimary),
                decoration: InputDecoration(
                  hintText: s.giftNoteHint,
                  hintStyle: TextStyle(color: t.textMuted),
                  filled: true,
                  fillColor: t.surfaceMuted,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(ctx).pop(''),
                      child: Text(s.giftNoteSkip,
                          style: TextStyle(color: t.textSecondary)),
                    ),
                  ),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(ctrl.text),
                      child: Text(s.giftNoteSend),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/images/icons/coin.webp',
                      width: 18, height: 18),
                  const SizedBox(width: 5),
                  Text(
                    '$_coins',
                    style: TextStyle(
                      color: t.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ],
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
              const SizedBox(height: 8),
              Text(
                gift.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: affordable ? theme.textPrimary : theme.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/images/icons/coin.webp',
                      width: 14, height: 14),
                  const SizedBox(width: 4),
                  Text(
                    '${gift.price}',
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                    ),
                  ),
                ],
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
