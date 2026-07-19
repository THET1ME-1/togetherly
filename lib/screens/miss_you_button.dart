import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/miss_you_repository.dart';
import '../services/pocketbase_service.dart';
import '../services/locale_service.dart';
import '../services/rate_limiter_service.dart';
import '../theme/app_theme.dart';

// ─── Layout ────────────────────────────────────────────────────────────────────
//
//  [ 💕  Я скучаю  3 · 5 ]  [ ⌄ ]
//         main pill           round expand button
//
//  Tap main pill  → send miss_you directly (original behaviour).
//  Tap round btn  → open/close vibe panel below.
//  Panel options  : 💕 Я скучаю · 💭 Думаю о тебе · 🤗 Хочу обнять · ✏️ Своё…
//  Custom option  → text-input dialog → sends as type 'custom'.

class MissYouButton extends StatefulWidget {
  final AppTheme theme;
  final String groupId;
  final String senderName;
  final bool enabled;

  const MissYouButton({
    super.key,
    required this.theme,
    required this.groupId,
    required this.senderName,
    this.enabled = true,
  });

  @override
  State<MissYouButton> createState() => _MissYouButtonState();
}

class _MissYouButtonState extends State<MissYouButton>
    with TickerProviderStateMixin {
  final MissYouRepository _missYou = MissYouRepository();

  // Key on the round expand button — used to position the overlay panel.
  final _expandKey = GlobalKey();

  // ── Miss-you counter ─────────────────────────────────────────────────────────
  int _myCount = 0;
  int _partnerCount = 0;
  int _inFlightTaps = 0;
  StreamSubscription? _countSub;
  Timer? _listenRetryTimer;
  int _listenRetryAttempt = 0;

  // ── Animations ───────────────────────────────────────────────────────────────
  late AnimationController _fillController;
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  // ── Floating hearts ──────────────────────────────────────────────────────────
  final List<_FloatingHeart> _hearts = [];
  final _random = Random();

  // ── Panel overlay ─────────────────────────────────────────────────────────────
  OverlayEntry? _overlayEntry;
  bool _isExpanded = false;

  // ── Vibe sent feedback ────────────────────────────────────────────────────────
  String? _sentEmoji;
  Timer? _feedbackTimer;

  // ── Saved custom wishes ───────────────────────────────────────────────────────
  // Свои пожелания запоминаются и показываются в панели как быстрый выбор, чтобы
  // не набирать заново. Хранятся локально (личные, общие для всех групп).
  static const String _kCustomWishesKey = 'miss_you_custom_wishes';
  static const int _maxCustomWishes = 3;
  List<String> _customWishes = [];

  // ─────────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadCustomWishes();

    _fillController = AnimationController(
      vsync: this,
      value: 0.5,
      lowerBound: 0.0,
      upperBound: 1.0,
    );

    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.92)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 18,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.92, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 82,
      ),
    ]).animate(_scaleController);

    _startListening();
  }

  @override
  void didUpdateWidget(covariant MissYouButton old) {
    super.didUpdateWidget(old);
    if (old.groupId != widget.groupId) {
      _countSub?.cancel();
      _inFlightTaps = 0;
      _startListening();
    }
  }

  void _startListening() {
    _countSub?.cancel();
    _listenRetryTimer?.cancel();
    if (widget.groupId.isEmpty) return;
    _countSub = _missYou.watchCounts(widget.groupId).listen(
      (counts) {
        if (!mounted) return;
        _listenRetryAttempt = 0;
        final myUid = PocketBaseService().userId ?? '';
        final newMyCount = counts[myUid] ?? 0;
        final newPartnerCount = counts.entries
            .where((e) => e.key != myUid)
            .fold(0, (sum, e) => sum + e.value);

        final confirmed = newMyCount - _myCount;
        if (confirmed > 0) _inFlightTaps = max(0, _inFlightTaps - confirmed);

        _myCount = newMyCount;
        _partnerCount = newPartnerCount;
        _animateToCurrentRatio();
        if (mounted) setState(() {});
      },
      onError: (_) {
        // SSE-подписка PB может отвалиться (сеть/перезапуск процесса) —
        // переподнимаем с бэкоффом, иначе счётчик висит на нулях до рестарта.
        if (!mounted) return;
        final delay = Duration(seconds: min(30, 2 << min(_listenRetryAttempt, 4)));
        _listenRetryAttempt++;
        _listenRetryTimer?.cancel();
        _listenRetryTimer = Timer(delay, () {
          if (mounted) _startListening();
        });
      },
    );
  }

  void _animateToCurrentRatio() {
    final displayMy = _myCount + _inFlightTaps;
    final total = displayMy + _partnerCount;
    final ratio = total == 0 ? 0.5 : (displayMy / total).clamp(0.0, 1.0);
    _fillController.animateTo(
      ratio,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  // ── Saved custom wishes ───────────────────────────────────────────────────────

  Future<void> _loadCustomWishes() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_kCustomWishesKey) ?? [];
    if (mounted) setState(() => _customWishes = saved);
  }

  /// Добавляет/поднимает пожелание в начало списка (most-recently-used),
  /// дедуп без учёта регистра, обрезает до [_maxCustomWishes].
  Future<void> _saveCustomWish(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final list = List<String>.from(_customWishes)
      ..removeWhere((w) => w.toLowerCase() == trimmed.toLowerCase());
    list.insert(0, trimmed);
    while (list.length > _maxCustomWishes) {
      list.removeLast();
    }
    if (mounted) setState(() => _customWishes = list);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kCustomWishesKey, list);
  }

  Future<void> _removeCustomWish(String text) async {
    final list = List<String>.from(_customWishes)..remove(text);
    if (mounted) setState(() => _customWishes = list);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kCustomWishesKey, list);
  }

  // ── Panel ─────────────────────────────────────────────────────────────────────

  void _togglePanel() {
    if (!widget.enabled || widget.groupId.isEmpty) return;
    _isExpanded ? _closePanel() : _openPanel();
  }

  void _openPanel() {
    final box =
        _expandKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screenWidth = MediaQuery.of(context).size.width;
    final anchorRight = screenWidth - pos.dx - size.width;

    setState(() => _isExpanded = true);

    _overlayEntry = OverlayEntry(
      builder: (_) => _VibePanelOverlay(
        theme: widget.theme,
        anchorTop: pos.dy + size.height + 6,
        anchorRight: anchorRight,
        myCount: _myCount + _inFlightTaps,
        partnerCount: _partnerCount,
        customWishes: _customWishes,
        onMissYou: _onMissYouFromPanel,
        onVibe: _onVibeFromPanel,
        onCustom: _onCustomFromPanel,
        onSavedWish: _onSavedWishFromPanel,
        onDeleteWish: _removeCustomWish,
        onDismiss: _closePanel,
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _closePanel() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() => _isExpanded = false);
  }

  // ── Actions ───────────────────────────────────────────────────────────────────

  Future<void> _sendMissYou() async {
    if (!widget.enabled || widget.groupId.isEmpty) return;
    HapticFeedback.mediumImpact();
    _scaleController.forward(from: 0);
    _spawnHearts();

    _inFlightTaps++;
    _animateToCurrentRatio();
    if (mounted) setState(() {});

    try {
      await _missYou.sendMissYou(widget.groupId);
    } on RateLimitException catch (e) {
      if (mounted) {
        setState(() => _inFlightTaps = max(0, _inFlightTaps - 1));
        _animateToCurrentRatio();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _inFlightTaps = max(0, _inFlightTaps - 1));
        _animateToCurrentRatio();
      }
    }
  }

  void _onMissYouFromPanel() {
    _closePanel();
    _sendMissYou();
  }

  Future<void> _onVibeFromPanel(String vibeType, String emoji) async {
    _closePanel();
    HapticFeedback.mediumImpact();
    try {
      await _missYou.sendVibe(
        groupId: widget.groupId,
        vibeType: vibeType,
      );
      if (mounted) _showSentFeedback(emoji);
    } on RateLimitException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      debugPrint('sendVibe error: $e');
    }
  }

  void _onCustomFromPanel() {
    _closePanel();
    // Wait one frame so the overlay is fully removed before the dialog opens,
    // otherwise the keyboard causes a RenderFlex overflow in the dangling overlay.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showCustomVibeDialog();
    });
  }

  /// Повторно отправить сохранённое пожелание прямо из панели — без диалога.
  Future<void> _onSavedWishFromPanel(String text) async {
    _closePanel();
    HapticFeedback.mediumImpact();
    try {
      await _missYou.sendVibe(
        groupId: widget.groupId,
        vibeType: 'custom',
        customText: text,
      );
      if (mounted) _showSentFeedback('✏️');
      // Поднимаем в начало списка (most-recently-used).
      await _saveCustomWish(text);
    } on RateLimitException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      debugPrint('sendSavedWish error: $e');
    }
  }

  Future<void> _showCustomVibeDialog() async {
    final s = LocaleService.current;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => _CustomVibeDialog(
        theme: widget.theme,
        title: s.customVibeTitle,
        hint: s.customVibeHint,
        sendLabel: s.post,
        cancelLabel: s.cancel,
      ),
    );
    if (text == null || text.trim().isEmpty) return;

    HapticFeedback.mediumImpact();
    try {
      await _missYou.sendVibe(
        groupId: widget.groupId,
        vibeType: 'custom',
        customText: text.trim(),
      );
      // Запоминаем пожелание для быстрого выбора в следующий раз.
      await _saveCustomWish(text.trim());
      if (mounted) _showSentFeedback('✏️');
    } on RateLimitException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      debugPrint('sendCustomVibe error: $e');
    }
  }

  void _showSentFeedback(String emoji) {
    setState(() => _sentEmoji = emoji);
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _sentEmoji = null);
    });
  }

  void _spawnHearts() {
    final emojis = ['💕', '💗', '💖', '💘', '💝', '✨'];
    for (int i = 0; i < 3; i++) {
      final heart = _FloatingHeart(
        emoji: emojis[_random.nextInt(emojis.length)],
        controller: AnimationController(
          vsync: this,
          duration: Duration(milliseconds: 650 + _random.nextInt(450)),
        ),
        dx: (_random.nextDouble() - 0.5) * 70,
        endDy: -48 - _random.nextDouble() * 32,
        size: 11 + _random.nextDouble() * 8,
      );
      heart.controller.forward().then((_) {
        heart.controller.dispose();
        if (mounted) setState(() => _hearts.remove(heart));
      });
      setState(() => _hearts.add(heart));
    }
  }

  @override
  void dispose() {
    // НЕ вызываем _closePanel(): он дёргает setState(), а во время dispose
    // элемент уже defunct → ассерт «_lifecycleState != defunct». Убираем
    // оверлей напрямую, без обновления состояния.
    _overlayEntry?.remove();
    _overlayEntry = null;
    _fillController.dispose();
    _scaleController.dispose();
    _countSub?.cancel();
    _listenRetryTimer?.cancel();
    _feedbackTimer?.cancel();
    for (final h in _hearts) {
      h.controller.dispose();
    }
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final btnColor = widget.theme.promptButtonColor;
    final displayMy = _myCount + _inFlightTaps;
    final total = displayMy + _partnerCount;
    final hasData = total > 0;

    return Opacity(
      opacity: widget.enabled ? 1.0 : 0.4,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Main pill button (sends miss_you directly) ──────────────────────
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // Floating hearts
              ..._hearts.map(
                (h) => AnimatedBuilder(
                  animation: h.controller,
                  builder: (context, _) {
                    final t = h.controller.value;
                    final ct = Curves.easeOut.transform(t);
                    return Positioned(
                      left: 20 + h.dx * ct,
                      bottom: 22 + (-h.endDy * ct),
                      child: Opacity(
                        opacity: (1 - t).clamp(0.0, 1.0),
                        child:
                            Text(h.emoji, style: TextStyle(fontSize: h.size)),
                      ),
                    );
                  },
                ),
              ),
              // Pill
              AnimatedBuilder(
                animation: _scaleAnimation,
                builder: (_, child) => Transform.scale(
                  scale: _scaleAnimation.value,
                  child: child,
                ),
                child: GestureDetector(
                  onTap: _sendMissYou,
                  child: AnimatedBuilder(
                    animation: _fillController,
                    builder: (context, _) {
                      final ratio = _fillController.value;

                      // Sent-vibe feedback
                      if (_sentEmoji != null) {
                        return _SentFeedbackPill(
                          emoji: _sentEmoji!,
                          label: s.vibeSent,
                          color: btnColor,
                        );
                      }

                      return ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            gradient: hasData
                                ? LinearGradient(
                                    stops: [ratio, ratio],
                                    colors: [
                                      btnColor.withValues(alpha: 0.78),
                                      btnColor.withValues(alpha: 0.28),
                                    ],
                                  )
                                : null,
                            color: hasData
                                ? null
                                : btnColor.withValues(alpha: 0.11),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: btnColor.withValues(
                                alpha: hasData ? 0.0 : 0.22,
                              ),
                            ),
                            boxShadow: hasData
                                ? [
                                    BoxShadow(
                                      color: btnColor.withValues(alpha: 0.18),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _CountBadge(
                                count: displayMy,
                                color: btnColor,
                                hasData: hasData,
                                isOnDarkSide: hasData && ratio > 0.15,
                              ),
                              const SizedBox(width: 7),
                              Text(
                                s.iMissYou,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: hasData ? Colors.white : btnColor,
                                ),
                              ),
                              const SizedBox(width: 7),
                              _CountBadge(
                                count: _partnerCount,
                                color: btnColor,
                                hasData: hasData,
                                isOnDarkSide: hasData && ratio > 0.85,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(width: 6),

          // ── Round expand button ─────────────────────────────────────────────
          GestureDetector(
            key: _expandKey,
            onTap: _togglePanel,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isExpanded
                    ? btnColor.withValues(alpha: 0.20)
                    : btnColor.withValues(alpha: 0.10),
                border: Border.all(
                  color: btnColor.withValues(
                    alpha: _isExpanded ? 0.40 : 0.22,
                  ),
                  width: 1.0,
                ),
                boxShadow: _isExpanded
                    ? [
                        BoxShadow(
                          color: btnColor.withValues(alpha: 0.18),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Center(
                child: AnimatedRotation(
                  turns: _isExpanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 16,
                    color: btnColor.withValues(
                      alpha: _isExpanded ? 0.9 : 0.65,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Sent-vibe feedback pill ───────────────────────────────────────────────────

class _SentFeedbackPill extends StatelessWidget {
  final String emoji;
  final String label;
  final Color color;

  const _SentFeedbackPill({
    required this.emoji,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Overlay panel ─────────────────────────────────────────────────────────────

class _VibePanelOverlay extends StatefulWidget {
  final AppTheme theme;
  final double anchorTop;
  final double anchorRight;
  final int myCount;
  final int partnerCount;
  final List<String> customWishes;
  final VoidCallback onMissYou;
  final void Function(String type, String emoji) onVibe;
  final VoidCallback onCustom;
  final void Function(String text) onSavedWish;
  final void Function(String text) onDeleteWish;
  final VoidCallback onDismiss;

  const _VibePanelOverlay({
    required this.theme,
    required this.anchorTop,
    required this.anchorRight,
    required this.myCount,
    required this.partnerCount,
    required this.customWishes,
    required this.onMissYou,
    required this.onVibe,
    required this.onCustom,
    required this.onSavedWish,
    required this.onDeleteWish,
    required this.onDismiss,
  });

  @override
  State<_VibePanelOverlay> createState() => _VibePanelOverlayState();
}

class _VibePanelOverlayState extends State<_VibePanelOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  // Локальная копия — чтобы удаление пожелания обновляло панель без её
  // пересоздания (родитель тем временем сохраняет изменения в prefs).
  late List<String> _wishes;

  @override
  void initState() {
    super.initState();
    _wishes = List<String>.from(widget.customWishes);
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 190),
    );
    _fadeAnim =
        CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -0.12),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic),
    );
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final color = widget.theme.promptButtonColor;
    final hasData = (widget.myCount + widget.partnerCount) > 0;

    return Stack(
      children: [
        // Full-screen backdrop — tap outside to close
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
        // Panel card
        Positioned(
          top: widget.anchorTop,
          right: widget.anchorRight.clamp(8.0, double.infinity),
          child: FadeTransition(
            opacity: _fadeAnim,
            child: SlideTransition(
              position: _slideAnim,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: 218,
                  decoration: BoxDecoration(
                    color: widget.theme.cardSurface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: widget.theme.cardBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.09),
                        blurRadius: 22,
                        offset: const Offset(0, 6),
                      ),
                      BoxShadow(
                        color: color.withValues(alpha: 0.07),
                        blurRadius: 14,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _VibeRow(
                          emoji: '💕',
                          label: s.iMissYou,
                          color: color,
                          trailing: hasData
                              ? _CounterTrailing(
                                  myCount: widget.myCount,
                                  partnerCount: widget.partnerCount,
                                  color: color,
                                )
                              : null,
                          onTap: widget.onMissYou,
                          showDivider: true,
                        ),
                        _VibeRow(
                          emoji: '💭',
                          label: s.thinkingOfYou,
                          color: color,
                          onTap: () =>
                              widget.onVibe('thinking_of_you', '💭'),
                          showDivider: true,
                        ),
                        _VibeRow(
                          emoji: '🤗',
                          label: s.wantHug,
                          color: color,
                          onTap: () => widget.onVibe('want_hug', '🤗'),
                          showDivider: true,
                        ),
                        // Сохранённые свои пожелания — быстрый повтор без диалога.
                        // Крестик справа убирает пожелание из списка.
                        ..._wishes.map(
                          (w) => _VibeRow(
                            emoji: '✏️',
                            label: w,
                            color: color,
                            onTap: () => widget.onSavedWish(w),
                            showDivider: true,
                            trailing: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                setState(() => _wishes.remove(w));
                                widget.onDeleteWish(w);
                              },
                              child: Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 15,
                                  color: color.withValues(alpha: 0.4),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Custom vibe row
                        _VibeRow(
                          emoji: '✏️',
                          label: s.customVibe,
                          color: color.withValues(alpha: 0.75),
                          onTap: widget.onCustom,
                          showDivider: false,
                          italic: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Counter trailing widget (miss you row) ────────────────────────────────────

class _CounterTrailing extends StatelessWidget {
  final int myCount;
  final int partnerCount;
  final Color color;

  const _CounterTrailing({
    required this.myCount,
    required this.partnerCount,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SmallBadge(count: myCount, color: color),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Text(
            '·',
            style: TextStyle(
              color: color.withValues(alpha: 0.4),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _SmallBadge(count: partnerCount, color: color),
      ],
    );
  }
}

// ─── Single row in the panel ───────────────────────────────────────────────────

class _VibeRow extends StatefulWidget {
  final String emoji;
  final String label;
  final Color color;
  final Widget? trailing;
  final VoidCallback onTap;
  final bool showDivider;
  final bool italic;

  const _VibeRow({
    required this.emoji,
    required this.label,
    required this.color,
    this.trailing,
    required this.onTap,
    required this.showDivider,
    this.italic = false,
  });

  @override
  State<_VibeRow> createState() => _VibeRowState();
}

class _VibeRowState extends State<_VibeRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            color: _pressed
                ? widget.color.withValues(alpha: 0.09)
                : Colors.transparent,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Text(widget.emoji, style: const TextStyle(fontSize: 17)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          widget.italic ? FontWeight.w500 : FontWeight.w600,
                      fontStyle: widget.italic
                          ? FontStyle.italic
                          : FontStyle.normal,
                      color: widget.color,
                    ),
                  ),
                ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        ),
        if (widget.showDivider)
          Divider(
            height: 1,
            thickness: 0.5,
            color: widget.color.withValues(alpha: 0.10),
            indent: 16,
            endIndent: 16,
          ),
      ],
    );
  }
}

// ─── Small badge in panel ─────────────────────────────────────────────────────

class _SmallBadge extends StatelessWidget {
  final int count;
  final Color color;

  const _SmallBadge({required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

// ─── Custom vibe dialog ────────────────────────────────────────────────────────

class _CustomVibeDialog extends StatefulWidget {
  final AppTheme theme;
  final String title;
  final String hint;
  final String sendLabel;
  final String cancelLabel;

  const _CustomVibeDialog({
    required this.theme,
    required this.title,
    required this.hint,
    required this.sendLabel,
    required this.cancelLabel,
  });

  @override
  State<_CustomVibeDialog> createState() => _CustomVibeDialogState();
}

class _CustomVibeDialogState extends State<_CustomVibeDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.theme.promptButtonColor;

    return Dialog(
      backgroundColor: widget.theme.cardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('✏️', style: TextStyle(fontSize: 20)),
                const SizedBox(width: 10),
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: TextStyle(color: color.withValues(alpha: 0.4)),
                filled: true,
                fillColor: color.withValues(alpha: 0.06),
                counterStyle: TextStyle(
                  color: color.withValues(alpha: 0.4),
                  fontSize: 11,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: color.withValues(alpha: 0.4),
                    width: 1.5,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    widget.cancelLabel,
                    style: TextStyle(
                      color: color.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: color,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    widget.sendLabel,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Count badge (main pill button) ───────────────────────────────────────────

class _CountBadge extends StatelessWidget {
  final int count;
  final Color color;
  final bool hasData;
  final bool isOnDarkSide;

  const _CountBadge({
    required this.count,
    required this.color,
    required this.hasData,
    required this.isOnDarkSide,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isOnDarkSide ? Colors.white : color;
    final bgColor = isOnDarkSide
        ? Colors.white.withValues(alpha: 0.20)
        : color.withValues(alpha: 0.12);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: textColor,
        ),
      ),
    );
  }
}

// ─── Floating heart particle ──────────────────────────────────────────────────

class _FloatingHeart {
  final String emoji;
  final AnimationController controller;
  final double dx;
  final double endDy;
  final double size;

  _FloatingHeart({
    required this.emoji,
    required this.controller,
    required this.dx,
    required this.endDy,
    required this.size,
  });
}
