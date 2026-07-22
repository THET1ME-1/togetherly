import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/gift.dart';
import '../../services/gifts_service.dart';
import '../../services/locale_service.dart';
import '../../theme/app_theme.dart';

/// Получение подарка: у каждого свой способ «сработать».
///
/// Свечу на торте задувают, коробку открывают, печенье ломают, зайчика ловят,
/// букет поливают. Пока действие не сделано, подарок висит неотвеченным — в
/// этом вся разница между подарком и картинкой.
class GiftReceiveSheet extends StatefulWidget {
  const GiftReceiveSheet({
    super.key,
    required this.theme,
    required this.giftId,
    required this.gift,
    required this.senderName,
    this.note,
  });

  final AppTheme theme;
  final String giftId;
  final Gift gift;
  final String senderName;
  final String? note;

  /// Возвращает true, если подарок приняли.
  static Future<bool?> show(
    BuildContext context, {
    required AppTheme theme,
    required String giftId,
    required Gift gift,
    required String senderName,
    String? note,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GiftReceiveSheet(
        theme: theme,
        giftId: giftId,
        gift: gift,
        senderName: senderName,
        note: note,
      ),
    );
  }

  @override
  State<GiftReceiveSheet> createState() => _GiftReceiveSheetState();
}

class _GiftReceiveSheetState extends State<GiftReceiveSheet>
    with TickerProviderStateMixin {
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  /// Куда убегает зайчик: смещение внутри игровой площадки.
  Alignment _runaway = Alignment.center;
  int _misses = 0;

  bool _done = false;
  bool _busy = false;
  String? _error;

  final _rnd = math.Random();

  @override
  void dispose() {
    _idle.dispose();
    _replyCtrl.dispose();
    super.dispose();
  }

  final _replyCtrl = TextEditingController();

  Future<void> _accept() async {
    if (_busy || _done) return;
    // Звезда: сначала желание, потом отклик — пустое желание не отправляем.
    if (widget.gift.wantsReply && _replyCtrl.text.trim().isEmpty) {
      setState(() => _error = LocaleService.current.giftWishEmpty);
      return;
    }
    setState(() => _busy = true);
    HapticFeedback.mediumImpact();
    // Обнимашка: вибрация в такт, а не один щелчок.
    if (widget.gift.action == GiftAction.hugBack) {
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 140));
        HapticFeedback.heavyImpact();
      }
    }
    final res = await GiftsService.instance
        .react(widget.giftId, reply: _replyCtrl.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = res.ok;
      _error = res.ok ? null : LocaleService.current.giftFailed;
    });
    if (res.ok) {
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  /// «Не сейчас»: приглашение гаснет, дарителю возвращается вся цена.
  Future<void> _decline() async {
    if (_busy || _done) return;
    setState(() => _busy = true);
    final res = await GiftsService.instance.decline(widget.giftId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.ok) Navigator.of(context).pop(false);
  }

  /// Пицца: монетка решает, кто заказывает.
  void _flip() {
    setState(() => _flipResult = _rnd.nextBool());
    HapticFeedback.mediumImpact();
    _accept();
  }

  bool? _flipResult;

  /// Зайчик убегает от промаха и даётся с третьей попытки.
  void _dodge() {
    HapticFeedback.selectionClick();
    setState(() {
      _misses++;
      _runaway = Alignment(
        (_rnd.nextDouble() * 1.6) - 0.8,
        (_rnd.nextDouble() * 1.2) - 0.6,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final s = LocaleService.current;
    final hint = LocaleService.instance.isRussian
        ? actionHintRu(widget.gift.action)
        : actionHintEn(widget.gift.action);

    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      decoration: BoxDecoration(
        color: t.cardSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: t.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            s.giftFromPartner(widget.senderName),
            style: TextStyle(fontSize: 14, color: t.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            widget.gift.title,
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w800, color: t.textPrimary),
          ),
          const SizedBox(height: 20),
          SizedBox(height: 220, child: _stage()),
          const SizedBox(height: 16),
          if (_done) ...[
            Text(s.giftAccepted,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: t.textPrimary)),
            if (_flipResult != null) ...[
              const SizedBox(height: 8),
              Text(
                _flipResult! ? s.giftFlipYou : s.giftFlipPartner,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: t.textPrimary),
              ),
            ],
            if (widget.note?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 12),
              _NoteCard(theme: t, text: widget.note!.trim()),
            ],
          ] else ...[
            Text(
              _error ?? hint,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _error != null ? t.textPrimary : t.textSecondary,
              ),
            ),
            if (widget.gift.wantsReply) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _replyCtrl,
                maxLength: 200,
                minLines: 1,
                maxLines: 3,
                style: TextStyle(color: t.textPrimary),
                decoration: InputDecoration(
                  hintText: s.giftWishHint,
                  hintStyle: TextStyle(color: t.textMuted),
                  filled: true,
                  fillColor: t.surfaceMuted,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              FilledButton(
                onPressed: _busy ? null : _accept,
                child: Text(s.giftWishSend),
              ),
            ],
            if (widget.gift.action == GiftAction.invite) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _busy ? null : _decline,
                      child: Text(s.giftDecline,
                          style: TextStyle(color: t.textSecondary)),
                    ),
                  ),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _accept,
                      child: Text(s.giftAccept),
                    ),
                  ),
                ],
              ),
            ],
            if (widget.gift.action == GiftAction.coinFlip) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _flip,
                child: Text(s.giftFlipCoin),
              ),
            ],
            if (widget.gift.action == GiftAction.catchIt && _misses > 0) ...[
              const SizedBox(height: 4),
              Text(s.giftBunnyMisses(_misses),
                  style: TextStyle(fontSize: 12.5, color: t.textMuted)),
            ],
          ],
          const SizedBox(height: 8),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
    );
  }

  /// Игровая площадка: у каждого действия свой сценарий.
  Widget _stage() {
    switch (widget.gift.action) {
      case GiftAction.blow:
        return _CandleStage(
          theme: widget.theme,
          gift: widget.gift,
          idle: _idle,
          blown: _done,
          onBlow: _accept,
        );
      case GiftAction.open:
        return _OpenStage(
          theme: widget.theme,
          gift: widget.gift,
          opened: _done,
          onOpen: _accept,
        );
      case GiftAction.crack:
        return _CrackStage(
          theme: widget.theme,
          gift: widget.gift,
          cracked: _done,
          onCrack: _accept,
        );
      case GiftAction.catchIt:
        return _CatchStage(
          theme: widget.theme,
          gift: widget.gift,
          caught: _done,
          at: _runaway,
          misses: _misses,
          onHit: _accept,
          onMiss: _dodge,
        );
      case GiftAction.water:
        return _WaterStage(
          theme: widget.theme,
          gift: widget.gift,
          watered: _done,
          idle: _idle,
          onWater: _accept,
        );
      case GiftAction.doubleTap:
        return _DoubleTapStage(
          theme: widget.theme,
          gift: widget.gift,
          idle: _idle,
          done: _done,
          onAccept: _accept,
        );
      case GiftAction.invite:
      case GiftAction.coinFlip:
      case GiftAction.clink:
      case GiftAction.unlock:
      case GiftAction.alarm:
      case GiftAction.hugBack:
      case GiftAction.wish:
      case GiftAction.blast:
      case GiftAction.urgent:
      case GiftAction.transfer:
      case GiftAction.tap:
        return _TapStage(
          theme: widget.theme,
          gift: widget.gift,
          idle: _idle,
          done: _done,
          onTap: _accept,
        );
    }
  }
}

/// Торт со свечой: пламя дрожит, тап по нему задувает.
class _CandleStage extends StatelessWidget {
  const _CandleStage({
    required this.theme,
    required this.gift,
    required this.idle,
    required this.blown,
    required this.onBlow,
  });

  final AppTheme theme;
  final Gift gift;
  final AnimationController idle;
  final bool blown;
  final VoidCallback onBlow;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: blown ? null : onBlow,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Image.asset(gift.asset, width: 170, height: 170),
          Positioned(
            top: 6,
            child: AnimatedOpacity(
              opacity: blown ? 0 : 1,
              duration: const Duration(milliseconds: 500),
              child: AnimatedBuilder(
                animation: idle,
                builder: (context, child) => Transform.scale(
                  scale: 0.86 + idle.value * 0.22,
                  child: Transform.rotate(
                    angle: (idle.value - 0.5) * 0.18,
                    child: child,
                  ),
                ),
                child: Container(
                  width: 26,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(14),
                      bottom: Radius.circular(10),
                    ),
                    gradient: const LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xFFF2A03C), Color(0xFFFFE08A)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFF2A03C).withValues(alpha: 0.55),
                        blurRadius: 22,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (blown)
            Positioned(
              top: 2,
              child: _Smoke(theme: theme),
            ),
        ],
      ),
    );
  }
}

/// Дымок после задутой свечи.
class _Smoke extends StatefulWidget {
  const _Smoke({required this.theme});

  final AppTheme theme;

  @override
  State<_Smoke> createState() => _SmokeState();
}

class _SmokeState extends State<_Smoke> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Opacity(
        opacity: (1 - _c.value).clamp(0, 1),
        child: Transform.translate(
          offset: Offset(math.sin(_c.value * 6) * 8, -_c.value * 60),
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.theme.textMuted.withValues(alpha: 0.35),
            ),
          ),
        ),
      ),
    );
  }
}

/// Коробка: крышка отлетает вверх, содержимое проявляется.
class _OpenStage extends StatelessWidget {
  const _OpenStage({
    required this.theme,
    required this.gift,
    required this.opened,
    required this.onOpen,
  });

  final AppTheme theme;
  final Gift gift;
  final bool opened;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: opened ? null : onOpen,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedScale(
            scale: opened ? 1.08 : 1,
            duration: const Duration(milliseconds: 400),
            child: Image.asset(gift.asset, width: 170, height: 170),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 520),
            curve: Curves.easeOutBack,
            top: opened ? -20 : 46,
            child: AnimatedOpacity(
              opacity: opened ? 0 : 1,
              duration: const Duration(milliseconds: 500),
              child: Container(
                width: 96,
                height: 26,
                decoration: BoxDecoration(
                  color: theme.primary.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Печенье: раскалывается на две половинки.
class _CrackStage extends StatelessWidget {
  const _CrackStage({
    required this.theme,
    required this.gift,
    required this.cracked,
    required this.onCrack,
  });

  final AppTheme theme;
  final Gift gift;
  final bool cracked;
  final VoidCallback onCrack;

  @override
  Widget build(BuildContext context) {
    const dur = Duration(milliseconds: 520);
    return GestureDetector(
      onTap: cracked ? null : onCrack,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedSlide(
            offset: cracked ? const Offset(-0.45, 0.08) : Offset.zero,
            duration: dur,
            curve: Curves.easeOut,
            child: AnimatedRotation(
              turns: cracked ? -0.06 : 0,
              duration: dur,
              child: ClipRect(
                clipper: _HalfClipper(left: true),
                child: Image.asset(gift.asset, width: 160, height: 160),
              ),
            ),
          ),
          AnimatedSlide(
            offset: cracked ? const Offset(0.45, 0.08) : Offset.zero,
            duration: dur,
            curve: Curves.easeOut,
            child: AnimatedRotation(
              turns: cracked ? 0.06 : 0,
              duration: dur,
              child: ClipRect(
                clipper: _HalfClipper(left: false),
                child: Image.asset(gift.asset, width: 160, height: 160),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HalfClipper extends CustomClipper<Rect> {
  const _HalfClipper({required this.left});

  final bool left;

  @override
  Rect getClip(Size size) => left
      ? Rect.fromLTWH(0, 0, size.width / 2, size.height)
      : Rect.fromLTWH(size.width / 2, 0, size.width / 2, size.height);

  @override
  bool shouldReclip(covariant CustomClipper<Rect> oldClipper) => false;
}

/// Зайчик: убегает от промахов, ловится с третьего раза.
class _CatchStage extends StatelessWidget {
  const _CatchStage({
    required this.theme,
    required this.gift,
    required this.caught,
    required this.at,
    required this.misses,
    required this.onHit,
    required this.onMiss,
  });

  final AppTheme theme;
  final Gift gift;
  final bool caught;
  final Alignment at;
  final int misses;
  final VoidCallback onHit;
  final VoidCallback onMiss;

  @override
  Widget build(BuildContext context) {
    // Первые два касания зайчик уворачивается, третье ловит: без промахов
    // ловля не чувствуется, с бесконечными — раздражает.
    final catchable = caught || misses >= 2;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: caught ? null : onMiss,
          ),
        ),
        AnimatedAlign(
          alignment: caught ? Alignment.center : at,
          duration: const Duration(milliseconds: 340),
          curve: Curves.easeOutBack,
          child: GestureDetector(
            onTap: caught
                ? null
                : catchable
                    ? onHit
                    : onMiss,
            child: AnimatedScale(
              scale: caught ? 1.15 : 1,
              duration: const Duration(milliseconds: 300),
              child: Image.asset(gift.asset, width: 120, height: 120),
            ),
          ),
        ),
      ],
    );
  }
}

/// Букет: до полива поник, после — распрямляется.
class _WaterStage extends StatelessWidget {
  const _WaterStage({
    required this.theme,
    required this.gift,
    required this.watered,
    required this.idle,
    required this.onWater,
  });

  final AppTheme theme;
  final Gift gift;
  final bool watered;
  final AnimationController idle;
  final VoidCallback onWater;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: watered ? null : onWater,
      child: AnimatedBuilder(
        animation: idle,
        builder: (context, child) {
          final droop = watered ? 0.0 : 0.06 + idle.value * 0.02;
          return Transform.rotate(angle: droop, child: child);
        },
        child: AnimatedScale(
          scale: watered ? 1.12 : 0.96,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutBack,
          child: Image.asset(gift.asset, width: 170, height: 170),
        ),
      ),
    );
  }
}

/// Обычный подарок: значок дышит, тап принимает.
class _TapStage extends StatelessWidget {
  const _TapStage({
    required this.theme,
    required this.gift,
    required this.idle,
    required this.done,
    required this.onTap,
  });

  final AppTheme theme;
  final Gift gift;
  final AnimationController idle;
  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: done ? null : onTap,
      child: AnimatedBuilder(
        animation: idle,
        builder: (context, child) => Transform.scale(
          scale: done ? 1.2 : 0.97 + idle.value * 0.06,
          child: child,
        ),
        child: Image.asset(gift.asset, width: 170, height: 170),
      ),
    );
  }
}

/// Сердце: принимается двойным касанием, одиночное только подсказывает.
class _DoubleTapStage extends StatefulWidget {
  const _DoubleTapStage({
    required this.theme,
    required this.gift,
    required this.idle,
    required this.done,
    required this.onAccept,
  });

  final AppTheme theme;
  final Gift gift;
  final AnimationController idle;
  final bool done;
  final VoidCallback onAccept;

  @override
  State<_DoubleTapStage> createState() => _DoubleTapStageState();
}

class _DoubleTapStageState extends State<_DoubleTapStage> {
  bool _nudge = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: widget.done ? null : widget.onAccept,
      onTap: widget.done
          ? null
          : () {
              HapticFeedback.selectionClick();
              setState(() => _nudge = true);
              Future<void>.delayed(const Duration(milliseconds: 260), () {
                if (mounted) setState(() => _nudge = false);
              });
            },
      child: AnimatedBuilder(
        animation: widget.idle,
        builder: (context, child) => Transform.scale(
          scale: widget.done
              ? 1.24
              : (_nudge ? 1.08 : 0.97 + widget.idle.value * 0.06),
          child: child,
        ),
        child: Image.asset(widget.gift.asset, width: 170, height: 170),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.theme, required this.text});

  final AppTheme theme;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.surfaceMuted,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 15, height: 1.45, color: theme.textPrimary),
      ),
    );
  }
}
