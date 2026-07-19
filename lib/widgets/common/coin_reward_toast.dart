import 'package:flutter/material.dart';
import '../../services/locale_service.dart';

/// Показывает всплывающее уведомление о начислении монет.
/// Анимация: появляется снизу, задерживается, исчезает вверх.
///
/// Использование:
///   CoinRewardToast.show(context, amount: 5);
class CoinRewardToast {
  static OverlayEntry? _current;

  static void show(
    BuildContext context, {
    required int amount,
    String? label,
  }) {
    if (amount <= 0) return;
    _safeRemove(_current);
    _current = null;

    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _CoinToastWidget(
        amount: amount,
        label: label,
        onDone: () {
          if (_current == entry) _current = null;
          _safeRemove(entry);
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }

  /// Снимает оверлей безопасно — даже если его уже снял следующий тост.
  ///
  /// При двух начислениях подряд первый оверлей убирался в show(), а его
  /// анимация потом доигрывала и звала remove() второй раз. Внутри OverlayEntry
  /// это дёргает `_overlay!` по null → «Null check operator used on a null
  /// value» в микротаске, и приложение молча вылетает. try/catch это гасит.
  static void _safeRemove(OverlayEntry? entry) {
    if (entry == null) return;
    try {
      entry.remove();
    } catch (_) {
      // Оверлей уже снят — штатная гонка, игнорируем.
    }
  }
}

class _CoinToastWidget extends StatefulWidget {
  final int amount;
  final String? label;
  final VoidCallback onDone;

  const _CoinToastWidget({
    required this.amount,
    required this.onDone,
    this.label,
  });

  @override
  State<_CoinToastWidget> createState() => _CoinToastWidgetState();
}

class _CoinToastWidgetState extends State<_CoinToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );

    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 15),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 25),
    ]).animate(_ctrl);

    _slide = TweenSequence<Offset>([
      TweenSequenceItem(
        tween: Tween(begin: const Offset(0, 0.4), end: Offset.zero)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 15,
      ),
      TweenSequenceItem(tween: ConstantTween(Offset.zero), weight: 60),
      TweenSequenceItem(
        tween: Tween(begin: Offset.zero, end: const Offset(0, -0.6))
            .chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 25,
      ),
    ]).animate(_ctrl);

    _ctrl.forward().then((_) => widget.onDone());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 100,
      left: 0,
      right: 0,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, child) => FadeTransition(
          opacity: _opacity,
          child: SlideTransition(
            position: _slide,
            child: child,
          ),
        ),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E).withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(40),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AnimatedCoin(size: 26),
                const SizedBox(width: 10),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      LocaleService.current.coinsPlus(widget.amount),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                    ),
                    if (widget.label != null)
                      Text(
                        widget.label!,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
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
}

class _AnimatedCoin extends StatefulWidget {
  final double size;
  const _AnimatedCoin({required this.size});

  @override
  State<_AnimatedCoin> createState() => _AnimatedCoinState();
}

class _AnimatedCoinState extends State<_AnimatedCoin>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scale = Tween(begin: 0.5, end: 1.0)
        .chain(CurveTween(curve: Curves.elasticOut))
        .animate(_ctrl);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: Image.asset(
        'assets/images/icons/coin.webp',
        width: widget.size,
        height: widget.size,
      ),
    );
  }
}
