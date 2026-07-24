import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../models/gift.dart';
import '../../services/gift_result.dart';
import '../../services/gifts_service.dart';
import '../../services/locale_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/profile_theme.dart';

/// Витрина подарков: выбрал — списались монеты, партнёру улетел значок.
///
/// Экран собран по M3 Expressive: тональные полки по уровням цены, обычные
/// подарки на круге, «событийные» — на живой скалопированной форме, которая
/// морфит и светится. Движение — не каскад, а материаловское: пружина на
/// нажатии (перелёт), морфинг-вспышка круг→скалоп на тапе, emphasized-кривые.
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

// ── M3-кривые движения ───────────────────────────────────────────────────────
const Cubic _emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
const Cubic _emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);

/// Уровень витрины по цене: 1 — каждый день (10–15), 2 — по поводу (20–30),
/// 3 — событие (40–60). Уровень задаёт тональный цвет и «крутость» формы.
int _tierOf(int price) => price <= 15 ? 1 : (price <= 30 ? 2 : 3);

/// Событийные подарки (3-й уровень) — самые крутые: живая форма + свечение.
bool _isSpecial(Gift g) => _tierOf(g.price) == 3;

String _tierName(int tier) {
  final ru = LocaleService.instance.isRussian;
  return switch (tier) {
    1 => ru ? 'Каждый день' : 'Everyday',
    2 => ru ? 'По поводу' : 'Occasions',
    _ => ru ? 'Событие' : 'Milestones',
  };
}

/// Бейдж характера подарка выводится из самой модели [Gift], а не хардкодится:
/// добавится новый подарок — подпись подтянется по его свойствам.
String? _badgeOf(Gift g) {
  final ru = LocaleService.instance.isRussian;
  if (g.keepsForever) return ru ? 'навсегда' : 'forever';
  if (g.opens != GiftOpens.none) return ru ? 'вместе' : 'together';
  if (g.transfersCoins) return ru ? 'монеты' : 'coins';
  if (g.mutualBonus > 0) return ru ? '+бонус' : '+bonus';
  if (g.wantsReply) return ru ? 'желание' : 'wish';
  if (g.piercesQuietHours) return ru ? 'срочно' : 'urgent';
  if (g.carriesNote) return ru ? 'записка' : 'note';
  if (g.writesToFeed) return ru ? 'в ленту' : 'to feed';
  if (g.deliversAtMorning) return ru ? 'утром' : 'morning';
  if (g.carriesDate) return ru ? 'дата' : 'date';
  if (g.carriesPlace) return ru ? 'место' : 'place';
  return null;
}

/// (фон, текст) тонального контейнера уровня.
(Color, Color) _tierColors(ColorScheme cs, int tier) => switch (tier) {
      1 => (cs.primaryContainer, cs.onPrimaryContainer),
      2 => (cs.tertiaryContainer, cs.onTertiaryContainer),
      _ => (cs.secondaryContainer, cs.onSecondaryContainer),
    };

/// Число лепестков формы — стабильно по позиции, чтобы формы не «прыгали» между
/// перерисовками, но соседи отличались.
const List<int> _petalCycle = [8, 6, 12, 7, 5, 10];

class _GiftShopScreenState extends State<GiftShopScreen> {
  /// Тестовая сборка (`--dart-define=GIFTS_FORCE=true`) показывает код отказа.
  static const bool _diagnostics = bool.fromEnvironment('GIFTS_FORCE');

  late int _coins = widget.coins;
  String? _sending;

  /// Активный фильтр уровня; null — показываем все полки.
  int? _filter;

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
    final cs = ProfileTheme.schemeFor(widget.theme);
    final s = LocaleService.current;
    final ctrl = TextEditingController();
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      transitionAnimationController: null,
      builder: (ctx) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 360),
        curve: _emphasizedDecelerate,
        builder: (ctx, v, child) => Opacity(
          opacity: v.clamp(0, 1),
          child: Transform.translate(offset: Offset(0, (1 - v) * 40), child: child),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom +
                MediaQuery.of(ctx).padding.bottom +
                20,
          ),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Image.asset(gift.asset),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(gift.title,
                          style: TextStyle(
                              fontFamily: 'Unbounded',
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              color: cs.onSurface)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: ctrl,
                  maxLength: 500,
                  maxLines: 4,
                  minLines: 2,
                  autofocus: true,
                  style: TextStyle(color: cs.onSurface, fontFamily: 'Onest'),
                  decoration: InputDecoration(
                    hintText: s.giftNoteHint,
                    hintStyle: TextStyle(color: cs.onSurfaceVariant),
                    filled: true,
                    fillColor: cs.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(ctx).pop(''),
                        child: Text(s.giftNoteSkip),
                      ),
                    ),
                    const SizedBox(width: 10),
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
      ),
    );
  }

  void _pickFilter(int? tier) {
    if (_filter == tier) return;
    setState(() => _filter = tier);
  }

  @override
  Widget build(BuildContext context) {
    final cs = ProfileTheme.schemeFor(widget.theme);
    return Theme(
      data: ProfileTheme.data(cs),
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: _appBar(cs),
        body: _body(cs),
      ),
    );
  }

  PreferredSizeWidget _appBar(ColorScheme cs) {
    final s = LocaleService.current;
    return AppBar(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      iconTheme: IconThemeData(color: cs.onSurface),
      title: Text(
        s.giftShopTitle,
        style: TextStyle(
          fontFamily: 'Unbounded',
          color: cs.onSurface,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
          fontSize: 22,
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: cs.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/images/icons/coin.webp',
                      width: 18, height: 18),
                  const SizedBox(width: 6),
                  Text(
                    '$_coins',
                    style: TextStyle(
                      color: cs.onSecondaryContainer,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _body(ColorScheme cs) {
    final reduce = MediaQuery.of(context).disableAnimations;
    final tiers = _filter == null ? const [1, 2, 3] : [_filter!];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FilterBar(selected: _filter, onPick: _pickFilter),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: _emphasizedDecelerate,
            switchOutCurve: _emphasized,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: child,
            ),
            child: ListView(
              key: ValueKey(_filter),
              padding: EdgeInsets.only(
                bottom: 28 + MediaQuery.of(context).padding.bottom,
              ),
              children: [
                for (final tier in tiers) ...[
                  _ShelfHeader(
                    title: _tierName(tier),
                    count: GiftCatalog.all
                        .where((g) => _tierOf(g.price) == tier)
                        .length,
                  ),
                  _ShelfGrid(
                    gifts: GiftCatalog.all
                        .where((g) => _tierOf(g.price) == tier)
                        .toList(),
                    coins: _coins,
                    sending: _sending,
                    reduce: reduce,
                    onSend: (g) =>
                        (_coins >= g.price && _sending == null) ? _send(g) : null,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Фильтр-чипы уровней ──────────────────────────────────────────────────────
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onPick});
  final int? selected;
  final ValueChanged<int?> onPick;

  @override
  Widget build(BuildContext context) {
    final ru = LocaleService.instance.isRussian;
    final items = <(int?, String)>[
      (null, ru ? 'Все' : 'All'),
      (1, _tierName(1)),
      (2, _tierName(2)),
      (3, _tierName(3)),
    ];
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (tier, label) = items[i];
          return _FilterChip(
            label: label,
            selected: selected == tier,
            onTap: () => onPick(tier),
          );
        },
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: _emphasized,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? cs.secondaryContainer : cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Onest',
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
              color:
                  selected ? cs.onSecondaryContainer : cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Заголовок полки ──────────────────────────────────────────────────────────
class _ShelfHeader extends StatelessWidget {
  const _ShelfHeader({required this.title, required this.count});
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: 'Unbounded',
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: -0.2,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: cs.outlineVariant)),
          const SizedBox(width: 10),
          Text(
            '$count',
            style: TextStyle(
              fontFamily: 'Onest',
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Сетка полки ──────────────────────────────────────────────────────────────
class _ShelfGrid extends StatelessWidget {
  const _ShelfGrid({
    required this.gifts,
    required this.coins,
    required this.sending,
    required this.reduce,
    required this.onSend,
  });

  final List<Gift> gifts;
  final int coins;
  final String? sending;
  final bool reduce;
  final ValueChanged<Gift> onSend;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: gifts.length,
      itemBuilder: (context, i) {
        final gift = gifts[i];
        return _GiftCard(
          gift: gift,
          petals: _petalCycle[i % _petalCycle.length],
          affordable: coins >= gift.price,
          busy: sending == gift.key,
          reduce: reduce,
          onSend: () => onSend(gift),
        );
      },
    );
  }
}

// ── Карточка подарка ─────────────────────────────────────────────────────────
class _GiftCard extends StatefulWidget {
  const _GiftCard({
    required this.gift,
    required this.petals,
    required this.affordable,
    required this.busy,
    required this.reduce,
    required this.onSend,
  });

  final Gift gift;
  final int petals;
  final bool affordable;
  final bool busy;
  final bool reduce;
  final VoidCallback onSend;

  @override
  State<_GiftCard> createState() => _GiftCardState();
}

class _GiftCardState extends State<_GiftCard> with TickerProviderStateMixin {
  /// Пружина масштаба на нажатии: 0 — покой, 1 — вжато; отпускание —
  /// SpringSimulation с перелётом (карточка «пружинит» назад).
  late final AnimationController _press = AnimationController(
    vsync: this,
    value: 0,
    lowerBound: -0.4, // перелёт: масштаб чуть больше 1
    upperBound: 1,
  );

  /// Вспышка-морфинг круг→скалоп на тапе (0→1→0).
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );

  /// Живой морфинг событийных подарков (петля).
  AnimationController? _breathe;

  @override
  void initState() {
    super.initState();
    if (_isSpecial(widget.gift) && !widget.reduce) {
      _breathe = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 3400),
      )..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _press.dispose();
    _pulse.dispose();
    _breathe?.dispose();
    super.dispose();
  }

  void _down(_) {
    if (widget.reduce) return;
    _press.animateTo(1, duration: const Duration(milliseconds: 110), curve: _emphasized);
  }

  void _release() {
    if (widget.reduce) {
      _press.value = 0;
      return;
    }
    _press.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 480, damping: 17),
      _press.value,
      0,
      _press.velocity,
    ));
  }

  void _tap() {
    if (!widget.affordable || widget.busy) return;
    if (!widget.reduce) _pulse.forward(from: 0);
    widget.onSend();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gift = widget.gift;
    final tier = _tierOf(gift.price);
    final (discBg, _) = _tierColors(cs, tier);
    final badge = _badgeOf(gift);
    final affordable = widget.affordable;

    final card = AnimatedBuilder(
      animation: _press,
      builder: (context, child) {
        final scale = 1 - 0.06 * _press.value; // перелёт даёт scale > 1
        return Transform.scale(scale: scale, child: child);
      },
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(26),
        ),
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _GiftMark(
                    asset: gift.asset,
                    discColor: discBg,
                    petals: widget.petals,
                    special: _isSpecial(gift),
                    affordable: affordable,
                    pulse: _pulse,
                    breathe: _breathe,
                  ),
                  if (badge != null)
                    Positioned(
                      top: 0,
                      left: 0,
                      child: _Badge(text: badge),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              gift.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Unbounded',
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
                letterSpacing: -0.2,
                color: affordable ? cs.onSurface : cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 5),
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
                    fontFamily: 'Onest',
                    color: affordable ? cs.primary : cs.onSurfaceVariant,
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            SizedBox(
              height: 2,
              child: widget.busy
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        minHeight: 2,
                        backgroundColor: cs.surfaceContainerHighest,
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );

    return GestureDetector(
      onTapDown: affordable ? _down : null,
      onTapUp: affordable
          ? (_) {
              _release();
              _tap();
            }
          : null,
      onTapCancel: affordable ? _release : null,
      child: Opacity(opacity: affordable ? 1 : 0.55, child: card),
    );
  }
}

// ── Значок подарка на форме (круг/скалоп с морфингом и свечением) ────────────
class _GiftMark extends StatelessWidget {
  const _GiftMark({
    required this.asset,
    required this.discColor,
    required this.petals,
    required this.special,
    required this.affordable,
    required this.pulse,
    required this.breathe,
  });

  final String asset;
  final Color discColor;
  final int petals;
  final bool special;
  final bool affordable;
  final Animation<double> pulse;
  final Animation<double>? breathe;

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[pulse];
    if (breathe != null) listenables.add(breathe!);

    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
      builder: (context, _) {
        // Вспышка тапа: 0→1→0, добавляет амплитуду и лёгкий «поп» масштаба.
        final p = math.sin(pulse.value * math.pi);

        double amp; // 0 = круг, >0 = скалоп
        double rot; // разворот формы
        if (special) {
          final b = breathe == null
              ? 0.5
              : Curves.easeInOut.transform(breathe!.value);
          amp = 0.10 + 0.09 * b + 0.10 * p;
          rot = (b - 0.5) * 0.6 + p * 0.5;
        } else {
          amp = 0.20 * p; // обычный подарок морфит в скалоп только на тапе
          rot = p * 0.6;
        }

        final scale = 1 + 0.10 * p;

        return Transform.scale(
          scale: scale,
          child: SizedBox(
            width: 92,
            height: 92,
            child: CustomPaint(
              painter: _ScallopPainter(
                fill: discColor,
                petals: petals,
                amp: amp.clamp(0, 0.5),
                rotation: rot,
              ),
              child: Center(
                child: Opacity(
                  opacity: affordable ? 1 : 0.45,
                  child: Image.asset(asset, width: 56, height: 56),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Форма-подложка: круг при [amp]≈0, скалопированная «ромашка» при amp>0.
/// Контур сглажен замкнутым Catmull-Rom — те же кривые, что у блоба проекта.
class _ScallopPainter extends CustomPainter {
  _ScallopPainter({
    required this.fill,
    required this.petals,
    required this.amp,
    required this.rotation,
  });

  final Color fill;
  final int petals;
  final double amp;
  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _shape(size);
    canvas.drawPath(path, Paint()..color = fill..isAntiAlias = true);
  }

  Path _shape(Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = math.min(cx, cy);
    if (petals <= 0 || amp <= 0.004) {
      return Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    }
    final steps = petals * 2;
    final pts = <Offset>[];
    for (int i = 0; i < steps; i++) {
      final a = (i / steps) * 2 * math.pi - math.pi / 2 + rotation;
      final rad = i.isEven ? r : r * (1 - amp);
      pts.add(Offset(cx + rad * math.cos(a), cy + rad * math.sin(a)));
    }
    return _catmullRom(pts);
  }

  static Path _catmullRom(List<Offset> pts) {
    final n = pts.length;
    final path = Path();
    for (int i = 0; i < n; i++) {
      final p0 = pts[(i - 1 + n) % n];
      final p1 = pts[i];
      final p2 = pts[(i + 1) % n];
      final p3 = pts[(i + 2) % n];
      final cp1 = Offset(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6);
      final cp2 = Offset(p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6);
      if (i == 0) path.moveTo(p1.dx, p1.dy);
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(_ScallopPainter old) =>
      old.amp != amp ||
      old.rotation != rotation ||
      old.fill != fill ||
      old.petals != petals;
}

// ── Бейдж характера ──────────────────────────────────────────────────────────
class _Badge extends StatelessWidget {
  const _Badge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'Onest',
          fontWeight: FontWeight.w700,
          fontSize: 10.5,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
