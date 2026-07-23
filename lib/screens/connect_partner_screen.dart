import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../utils/safe_text.dart';
import '../widgets/common/app_dialog.dart';
import '../widgets/storage_image.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:share_plus/share_plus.dart';
import '../utils/share_origin.dart';
import '../models/pair_data.dart';
import '../models/connection.dart';
import '../models/profile_icon.dart';
import '../models/user_data.dart';
import '../services/chat_service.dart';
import '../services/deep_link_service.dart';
import '../services/pb_data_service.dart';
import '../services/pb_auth_service.dart';
import '../services/presence_service.dart';
import '../services/locale_service.dart';
import '../services/nickname_service.dart';
import '../services/timer_service.dart';
import '../theme/app_theme.dart';
import '../theme/profile_theme.dart';
import '../widgets/connect_expressive.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';
import 'chat_screen.dart';
import 'home/widgets/relationship_type_dialog.dart';

class ConnectPartnerScreen extends StatefulWidget {
  final PairData pairData;
  final AppTheme theme;
  final UserData? userData;
  // Загруженный TimerService из home: «дней вместе» берём из его системного
  // таймера — тот же источник, что виджет и колесо (TimerService не синглтон,
  // свой new даёт пустой инстанс → 0/фолбэк).
  final TimerService? timerService;
  const ConnectPartnerScreen({
    super.key,
    required this.pairData,
    required this.theme,
    this.userData,
    this.timerService,
  });

  @override
  State<ConnectPartnerScreen> createState() => _ConnectPartnerScreenState();
}

class _ConnectPartnerScreenState extends State<ConnectPartnerScreen>
    with SingleTickerProviderStateMixin {
  Color get primary => widget.theme.primary;
  Color get primaryLight => widget.theme.primaryLight;
  final _codeController = TextEditingController();
  bool _showCodeInput = false;
  bool _codeError = false;
  // Re-entrancy guard: без него быстрый повторный тап по варианту в диалоге
  // «создать подключение» плодил по несколько пустых подключений (сетевой
  // await генерации кода держал диалог открытым).
  bool _creatingConnection = false;
  // Идёт генерация нового кода (крутим лоадер + цикл «дешифратора»).
  bool _generating = false;
  // Копировать → галочка на ~1.3с.
  bool _copied = false;
  // Направление свайпа карусели (для slide-перехода активной группы).
  int _carDir = 1;
  // Выбранная форма аватарки на партнёра (локально; тап меняет, морф анимирует).
  Map<String, int> _shapeIdx = {};
  late AnimationController _pulseController;
  StreamSubscription? _deepLinkSub;

  // Онлайн-статус партнёра — живой PB-презенс (heartbeat+TTL). Бейдж — разовая
  // загрузка из профиля (дедуп по _badgeLoadedUids).
  final Map<String, bool> _partnerOnlineStatus = {};
  final Map<String, String?> _partnerBadges = {};
  final Map<String, StreamSubscription<bool>> _presenceSubs = {};
  final Set<String> _badgeLoadedUids = {};

  @override
  void initState() {
    super.initState();
    _loadShapes();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _deepLinkSub = DeepLinkService().inviteCodeStream.listen((code) {
      if (mounted) {
        // acceptCode handles creating/joining group automatically
        _codeController.text = code;
        _showCodeInput = true;
        setState(() {});
        _submitCode();
      }
    });

    // Экран смонтировался on-demand — на холодном старте deep-link уже мог
    // отдать код в broadcast-стрим до нашей подписки. Забираем буфер.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final buffered = DeepLinkService().consumePendingInviteCode();
      if (buffered != null && buffered.isNotEmpty) {
        _codeController.text = buffered;
        _showCodeInput = true;
        setState(() {});
        _submitCode();
      }
    });

    // Подписываемся на присутствие партнёров
    _subscribeToPartnerPresence();
    // Переподписываемся при изменении состава группы
    widget.pairData.addListener(_onPairDataChanged);

    // Если код пустой (генерация не удалась при запуске без сети) — пробуем снова
    if (widget.pairData.inviteCode.isEmpty && !widget.pairData.isPaired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.pairData.regenerateCode();
      });
    }
  }

  void _onPairDataChanged() {
    _subscribeToPartnerPresence();
  }

  void _subscribeToPartnerPresence() {
    final partners = widget.pairData.partners;
    final newUids = partners.map((p) => p.uid).toSet();

    // Чистим состояние для вышедших участников.
    final removed = _presenceSubs.keys.toSet().difference(newUids);
    for (final uid in removed) {
      _presenceSubs.remove(uid)?.cancel();
      _badgeLoadedUids.remove(uid);
      _partnerOnlineStatus.remove(uid);
      _partnerBadges.remove(uid);
    }

    for (final member in partners) {
      if (member.uid.isEmpty) continue;
      // Онлайн-статус — живой PB-презенс (heartbeat+TTL).
      if (!_presenceSubs.containsKey(member.uid)) {
        _presenceSubs[member.uid] =
            PresenceService().watchOnline(member.uid).listen((online) {
          if (mounted) {
            setState(() => _partnerOnlineStatus[member.uid] = online);
          }
        });
      }
      // Бейдж — разово из профиля PB.
      if (!_badgeLoadedUids.contains(member.uid)) {
        _badgeLoadedUids.add(member.uid);
        PbDataService().loadUserProfileMap(member.uid).then((p) {
          if (!mounted || p == null) return;
          setState(() => _partnerBadges[member.uid] = p['badge'] as String?);
        });
      }
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _pulseController.dispose();
    _deepLinkSub?.cancel();
    widget.pairData.removeListener(_onPairDataChanged);
    for (final sub in _presenceSubs.values) {
      sub.cancel();
    }
    _presenceSubs.clear();
    _badgeLoadedUids.clear();
    super.dispose();
  }

  PairData get pair => widget.pairData;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ProfileTheme.themeFor(widget.theme),
      child: Column(
        children: [
          const SizedBox(height: 8),
          _buildGroupTabs(),
          Expanded(
            child: pair.isPaired
                ? _buildConnectedContent()
                : _buildInviteContent(),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  GROUP TABS — horizontal scrollable chips
  // ═══════════════════════════════════════════════════
  Widget _buildGroupTabs() {
    final cs = Theme.of(context).colorScheme;
    final mgr = pair.manager;
    final conns = mgr.connections.where((c) => !c.isSolo).toList();
    final isSolo = mgr.isSoloMode;
    final n = conns.length;

    int activeIdx = -1;
    if (!isSolo) {
      for (int i = 0; i < n; i++) {
        if (mgr.connections.indexOf(conns[i]) == mgr.activeConnectionIndex) {
          activeIdx = i;
          break;
        }
      }
    }
    if (activeIdx < 0 && n > 0) activeIdx = 0;

    final Connection? active = n > 0 ? conns[activeIdx] : null;
    // Кольцо: при 2+ группах слева и справа ВСЕГДА кто-то есть (по кругу),
    // крайний слева уходит в центр, последний становится левым соседом.
    final Connection? prev = n >= 2 ? conns[(activeIdx - 1 + n) % n] : null;
    final Connection? next = n >= 2 ? conns[(activeIdx + 1) % n] : null;

    Future<void> activate(int rawIdx, int dir) async {
      if (n == 0) return;
      final idx = ((rawIdx % n) + n) % n; // круговой индекс (бесконечная прокрутка)
      if (idx == activeIdx && !isSolo) return;
      if (mounted) setState(() => _carDir = dir);
      final mi = mgr.connections.indexOf(conns[idx]);
      await mgr.switchToConnection(mi);
      if (!mounted) return;
      _resetCodeInput();
      setState(() {});
    }

    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            _soloBtn(cs, isSolo),
            const SizedBox(width: 6),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v < -60) {
                    activate(activeIdx + 1, 1);
                  } else if (v > 60) {
                    activate(activeIdx - 1, -1);
                  }
                },
                child: Row(
                  children: [
                    _peekSlot(prev, cs, () => activate(activeIdx - 1, -1)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: GestureDetector(
                        onTap: isSolo ? () => activate(activeIdx, 1) : null,
                        onLongPress: () {
                          if (mgr.connections.length > 1 && active != null) {
                            _confirmDeleteConnection(active.id);
                          }
                        },
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 420),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: _carouselTransition,
                          child: KeyedSubtree(
                            key: ValueKey(
                                'center-$isSolo-${active?.id ?? 'none'}'),
                            child: _centerPill(active, cs, isSolo),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _peekSlot(next, cs, () => activate(activeIdx + 1, 1)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            _addBtn(cs),
          ],
        ),
      ),
    );
  }

  Widget _carouselTransition(Widget child, Animation<double> anim) {
    final slide = Tween<Offset>(
      begin: Offset(0.16 * _carDir, 0),
      end: Offset.zero,
    ).animate(anim);
    return FadeTransition(
      opacity: anim,
      child: SlideTransition(position: slide, child: child),
    );
  }

  Widget _soloBtn(ColorScheme cs, bool active) {
    return GestureDetector(
      onTap: () async {
        await pair.manager.switchToSolo();
        if (!mounted) return;
        _resetCodeInput();
        setState(() {});
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? cs.secondaryContainer : cs.surfaceContainerHigh,
        ),
        child: Icon(Icons.person_rounded,
            size: 21,
            color: active ? cs.onSecondaryContainer : cs.onSurfaceVariant),
      ),
    );
  }

  Widget _addBtn(ColorScheme cs) {
    return GestureDetector(
      onTap: _showAddGroupDialog,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
            shape: BoxShape.circle, color: cs.surfaceContainerHigh),
        child: Icon(Icons.add_rounded, size: 21, color: cs.onSurfaceVariant),
      ),
    );
  }

  // Узкий сосед-круг (44): аватар/буква пары или точка «ждём». Тап → в центр.
  Widget _peekSlot(Connection? c, ColorScheme cs, VoidCallback onTap) {
    if (c == null) return const SizedBox(width: 44, height: 52);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 420),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: _carouselTransition,
        child: KeyedSubtree(
          key: ValueKey('peek-${c.id}'),
          child: _peekCircle(c, cs),
        ),
      ),
    );
  }

  Widget _peekCircle(Connection c, ColorScheme cs) {
    final initial = (c.isPaired ? c.partnerName : '?').firstGraphemeUpper('?');
    final photo =
        (c.isPaired && c.partners.isNotEmpty) ? c.partners.first.avatar : '';
    return Container(
      width: 44,
      height: 44,
      decoration:
          BoxDecoration(shape: BoxShape.circle, color: cs.surfaceContainerHigh),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: !c.isPaired
          ? Container(
              width: 9,
              height: 9,
              decoration:
                  BoxDecoration(color: cs.primary, shape: BoxShape.circle))
          : (photo.isNotEmpty
              ? StorageImage(
                  imageUrl: photo,
                  fit: BoxFit.cover,
                  errorWidget: (a, b, e) => _letterBox(initial, cs))
              : _letterBox(initial, cs)),
    );
  }

  // Центральная активная пилюля: имя целиком; влезает — по центру, длинное —
  // бегущей строкой (телесуфлёр). Точка статуса слева.
  Widget _centerPill(Connection? c, ColorScheme cs, bool isSolo) {
    if (c == null) return const SizedBox(width: double.infinity, height: 52);
    final name = c.isPaired
        ? (c.partnerCount > 1
              ? '${c.partners.first.name} +${c.partnerCount - 1}'
              : c.partnerName)
        : LocaleService.current.waiting;
    final highlighted = !isSolo;
    final bg = highlighted ? cs.secondaryContainer : cs.surfaceContainerHigh;
    final fg = highlighted ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    final nameStyle = TextStyle(
        fontFamily: 'Onest',
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: fg);
    final dot = Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
            color: c.isPaired ? const Color(0xFF16A34A) : cs.primary,
            shape: BoxShape.circle));
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: Container(
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(26)),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, box) {
            const hPad = 14.0, dotGap = 8.0;
            final avail = box.maxWidth - hPad * 2 - 8 - dotGap;
            final tp = TextPainter(
              text: TextSpan(text: name, style: nameStyle),
              maxLines: 1,
              textDirection: TextDirection.ltr,
            )..layout();
            final fits = tp.width <= avail;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: hPad),
              child: fits
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        dot,
                        const SizedBox(width: dotGap),
                        Flexible(
                            child: Text(name,
                                maxLines: 1,
                                softWrap: false,
                                style: nameStyle)),
                      ],
                    )
                  : Row(
                      children: [
                        dot,
                        const SizedBox(width: dotGap),
                        Expanded(child: MarqueeText(name, style: nameStyle)),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _letterBox(String initial, ColorScheme cs) {
    return Center(
      child: Text(initial,
          style: TextStyle(
              fontFamily: 'Unbounded',
              fontWeight: FontWeight.w700,
              fontSize: 18,
              color: cs.primary)),
    );
  }

  void _resetCodeInput() {
    _codeController.clear();
    _showCodeInput = false;
    _codeError = false;
  }

  // ═══════════════════════════════════════════════════
  //  CONNECTED — partner linked
  // ═══════════════════════════════════════════════════
  Widget _buildConnectedContent() {
    return Theme(
      data: ProfileTheme.themeFor(widget.theme),
      child: Builder(
        builder: (context) {
          final cs = Theme.of(context).colorScheme;
          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
                20, 10, 20, MediaQuery.of(context).padding.bottom + 100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _connectedHero(cs),
                const SizedBox(height: 14),
                _chatTile(cs),
                const SizedBox(height: 14),
                _connectedActions(cs),
                const SizedBox(height: 14),
                _disconnectButton(cs),
              ],
            ),
          );
        },
      ),
    );
  }

  // Hero «Подключён» — бенто «Ступени»: «печенька» без подложки + счётчик дней
  // слева; имя-герой + онлайн/тип справа; снизу полоса годовщины. Колонны ровны
  // по высоте (214), аватар — сама фигура, без плитки за ней.
  Widget _connectedHero(ColorScheme cs) {
    final partner = pair.partners.isNotEmpty ? pair.partners.first : null;
    final title = partner != null
        ? pair.displayNameOf(partner)
        : LocaleService.current.waiting;
    final online =
        partner != null && (_partnerOnlineStatus[partner.uid] ?? false);
    // «Дней вместе» — из того же источника, что виджет и колесо на главной:
    // системный таймер отношений (его дату юзер и правит). Connection.startDate
    // (pair.daysInLove) — устаревшее второе поле, расходилось с ним.
    final relTimer =
        widget.timerService?.systemTimer ?? widget.timerService?.defaultTimer;
    final days =
        relTimer != null ? relTimer.daysElapsed.abs() : pair.daysInLove;

    // Годовщина: ближайшее наступление (месяц/день) от сегодня.
    int? annivDays;
    final av = pair.anniversaryDate;
    if (av != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      var next = DateTime(now.year, av.month, av.day);
      if (next.isBefore(today)) next = DateTime(now.year + 1, av.month, av.day);
      annivDays = next.difference(today).inDays;
    }

    return Column(
      children: [
        SizedBox(
          height: 214,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 116,
                child: Column(
                  children: [
                    _heroAvatar(92, partner?.uid ?? '',
                        partner?.avatar ?? '', partner?.name ?? '?', cs),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _statTile(cs, '$days',
                          LocaleService.current.daysTogetherStat,
                          bg: cs.tertiaryContainer, fg: cs.onTertiaryContainer),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  children: [
                    Expanded(child: _nameTile(cs, title, partner?.uid)),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 46,
                      child: _chipTile(
                        cs,
                        leading: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                                color: online
                                    ? const Color(0xFF16A34A)
                                    : cs.onSurfaceVariant,
                                shape: BoxShape.circle)),
                        text: online
                            ? LocaleService.current.online
                            : LocaleService.current.offline,
                        bg: cs.surfaceContainerHigh,
                        fg: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 46,
                      child: _chipTile(
                        cs,
                        leading: Icon(
                            relIconForType(pair.relationshipType,
                                customEmoji: pair.relationshipEmoji),
                            size: 16,
                            color: cs.onPrimaryContainer),
                        text: pair.relationshipLabel,
                        bg: cs.primaryContainer,
                        fg: cs.onPrimaryContainer,
                        onTap: () => showRelationshipTypeSheet(context, pair: pair, theme: widget.theme, onChanged: () { if (mounted) setState(() {}); }),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (annivDays != null) ...[
          const SizedBox(height: 12),
          _anniversaryStrip(cs, annivDays),
        ],
      ],
    );
  }

  // «Печенька» с фото партнёра, без подложки — сама фигура.
  // Смена данных ВНУТРИ неподвижного блока: проявление + лёгкий зум (как код).
  Widget _swap(Object k, Widget child) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (c, a) => FadeTransition(
          opacity: a,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1.0).animate(a),
            child: c,
          ),
        ),
        child: KeyedSubtree(key: ValueKey(k), child: child),
      );

  // Аватар в уникальной форме партнёра (по uid); при смене формы — морф.
  int _shapeIndexFor(String uid) =>
      _shapeIdx[uid] ?? defaultShapeIndexForUid(uid);

  Future<void> _loadShapes() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, int>{};
    for (final k in prefs.getKeys()) {
      if (k.startsWith('avatar_shape_')) {
        final v = prefs.getInt(k);
        if (v != null) map[k.substring('avatar_shape_'.length)] = v;
      }
    }
    if (mounted && map.isNotEmpty) setState(() => _shapeIdx = map);
  }

  // Тап по аватарке → следующая форма (морф). Выбор сохраняется локально.
  void _cycleShape(String uid) {
    if (uid.isEmpty) return;
    final next = (_shapeIndexFor(uid) + 1) % kAvatarShapes.length;
    setState(() => _shapeIdx = {..._shapeIdx, uid: next});
    SharedPreferences.getInstance()
        .then((p) => p.setInt('avatar_shape_$uid', next));
  }

  Widget _heroAvatar(
      double size, String uid, String photo, String name, ColorScheme cs) {
    final idx = _shapeIndexFor(uid);
    return Center(
      child: PressableScale(
        onTap: uid.isEmpty ? null : () => _cycleShape(uid),
        child: MorphAvatar(
          size: size,
          shapeKey: '$uid-$idx',
          shape: kAvatarShapes[idx],
          child: photo.isNotEmpty
              ? StorageImage(
                  imageUrl: photo,
                  fit: BoxFit.cover,
                  errorWidget: (c, u, e) => _heroInitial(name, cs))
              : _heroInitial(name, cs),
        ),
      ),
    );
  }

  Widget _statTile(ColorScheme cs, String number, String caption,
      {required Color bg, required Color fg}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(28)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _swap(
            'stat-$number',
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(number,
                  maxLines: 1,
                  style: TextStyle(
                      fontFamily: 'Unbounded',
                      fontWeight: FontWeight.w800,
                      fontSize: 36,
                      height: 0.95,
                      letterSpacing: -1.5,
                      color: fg)),
            ),
          ),
          const SizedBox(height: 2),
          Text(caption,
              maxLines: 2,
              style: TextStyle(
                  fontFamily: 'Onest',
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  height: 1.1,
                  color: fg)),
        ],
      ),
    );
  }

  Widget _nameTile(ColorScheme cs, String title, String? badgeUid) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 14, 16),
      decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(28)),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.bottomLeft,
            child: _swap(
              'name-$title',
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomLeft,
                child: Text(title,
                    maxLines: 1,
                    style: TextStyle(
                        fontFamily: 'Unbounded',
                        fontWeight: FontWeight.w800,
                        fontSize: 44,
                        height: 1.0,
                        letterSpacing: -1.5,
                        color: cs.onPrimaryContainer)),
              ),
            ),
          ),
          if (badgeUid != null)
            Positioned(top: 0, right: 0, child: _badgeIcon(badgeUid)),
        ],
      ),
    );
  }

  Widget _chipTile(ColorScheme cs,
      {required Widget leading,
      required String text,
      required Color bg,
      required Color fg,
      VoidCallback? onTap}) {
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(22)),
      child: _swap(
        'chip-$text',
        Row(
          children: [
            leading,
            const SizedBox(width: 8),
            Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Onest',
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: fg)),
            ),
          ],
        ),
      ),
    );
    return onTap == null ? tile : PressableScale(onTap: onTap, child: tile);
  }

  Widget _anniversaryStrip(ColorScheme cs, int daysUntil) {
    final today = daysUntil == 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 20, 12),
      decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(26)),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: cs.primary, borderRadius: BorderRadius.circular(16)),
            child: Icon(Icons.event_rounded, size: 24, color: cs.onPrimary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _swap(
              'anniv-$daysUntil',
              today
                  ? Text(LocaleService.current.anniversaryTodayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Unbounded',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: cs.onSurface))
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('$daysUntil',
                          style: TextStyle(
                              fontFamily: 'Unbounded',
                              fontWeight: FontWeight.w800,
                              fontSize: 23,
                              letterSpacing: -0.5,
                              color: cs.onSurface)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                            LocaleService.current.daysUntilAnniversary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: 'Onest',
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: cs.onSurfaceVariant)),
                      ),
                    ],
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroInitial(String name, ColorScheme cs) {
    return Container(
      color: cs.primary,
      alignment: Alignment.center,
      child: Text(
        name.firstGraphemeUpper('?'),
        style: TextStyle(
          fontFamily: 'Unbounded',
          fontWeight: FontWeight.w700,
          fontSize: 26,
          color: cs.onPrimary,
        ),
      ),
    );
  }

  Widget _membersCard(ColorScheme cs) {
    final partners = pair.partners;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 10, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              LocaleService.current
                  .membersCount(partners.length + 1)
                  .toUpperCase(),
              style: TextStyle(
                fontFamily: 'Onest',
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          ...partners.map(
            (m) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  _memberAvatar(m.avatar, m.name, 40),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                pair.displayNameOf(m).isNotEmpty
                                    ? pair.displayNameOf(m)
                                    : LocaleService.current.member,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Onest',
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: cs.onSurface,
                                ),
                              ),
                            ),
                            _badgeIcon(m.uid),
                          ],
                        ),
                        if (NicknameService.instance.get(m.uid).isNotEmpty)
                          Text(
                            m.name,
                            style: TextStyle(
                              fontFamily: 'Onest',
                              fontSize: 11.5,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _showRenameDialog(m),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.edit_rounded,
                        size: 18, color: cs.onSurfaceVariant),
                  ),
                  _buildPresenceBadge(m.uid),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _connectedActions(ColorScheme cs) {
    final canInvite = pair.canInviteMore;
    return Row(
      children: [
        if (canInvite) ...[
          Expanded(
            child: _connectTile(
              bg: cs.tertiaryContainer,
              fg: cs.onTertiaryContainer,
              icon: Icons.person_add_rounded,
              label: LocaleService.current.inviteMore,
              onTap: _showInviteMoreSheet,
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: _connectTile(
            bg: cs.surfaceContainerHighest,
            fg: cs.onSurface,
            icon: Icons.qr_code_2_rounded,
            label: LocaleService.current.showQr,
            onTap: _showQRDialog,
          ),
        ),
      ],
    );
  }

  Widget _disconnectButton(ColorScheme cs) {
    return PressableScale(
      onTap: _showUnpairDialog,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: cs.errorContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Center(
          child: Text(
            LocaleService.current.disconnect,
            style: TextStyle(
              fontFamily: 'Onest',
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  INVITE — connect partner (unpaired)
  // ═══════════════════════════════════════════════════
  Future<void> _handleRegenerate() async {
    if (_generating) return;
    setState(() => _generating = true);
    await pair.regenerateCode();
    if (!mounted) return;
    setState(() => _generating = false);
    _showSnack(LocaleService.current.newCodeGenerated);
  }

  void _handleCopy() {
    if (pair.inviteCode.isEmpty) return;
    Clipboard.setData(ClipboardData(text: pair.inviteCode));
    _showSnack(LocaleService.current.codeCopied);
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1300), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _handleShare() async {
    if (pair.inviteCode.isEmpty) return;
    final origin = shareOriginFromContext(context);
    await Share.share(
      LocaleService.current.shareInviteText(pair.inviteCode, pair.inviteLink),
      subject: LocaleService.current.loveAppInvitation,
      sharePositionOrigin: origin,
    );
  }

  // ═══════════════════════════════════════════════════
  //  INVITE — M3 Expressive
  // ═══════════════════════════════════════════════════
  Widget _buildInviteContent() {
    return Theme(
      data: ProfileTheme.themeFor(widget.theme),
      child: Builder(
        builder: (context) {
          final cs = Theme.of(context).colorScheme;
          final loading = _generating || pair.inviteCode.isEmpty;
          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
                20, 10, 20, MediaQuery.of(context).padding.bottom + 100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _heroCode(cs, loading),
                const SizedBox(height: 14),
                _actionsRow(cs),
                const SizedBox(height: 14),
                _chatTile(cs),
                const SizedBox(height: 14),
                _connectTiles(cs),
                const SizedBox(height: 14),
                _enterCodeCard(cs),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _heroCode(ColorScheme cs, bool loading) {
    final myInitial =
        (widget.userData?.displayName ?? '').firstGraphemeUpper('Я');
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 30),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(40),
      ),
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CookieAvatar(
                size: 64,
                color: cs.primary,
                onColor: cs.onPrimary,
                initial: myInitial,
              ),
              Transform.translate(
                offset: const Offset(-14, 0),
                child: DashedRing(
                  size: 64,
                  color: cs.onPrimaryContainer.withValues(alpha: 0.42),
                  child: Icon(Icons.add_rounded,
                      size: 26,
                      color: cs.onPrimaryContainer.withValues(alpha: 0.55)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            LocaleService.current.yourInviteCode.toUpperCase(),
            style: TextStyle(
              fontFamily: 'Onest',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.4,
              color: cs.onPrimaryContainer.withValues(alpha: 0.66),
            ),
          ),
          const SizedBox(height: 14),
          AnimatedInviteCode(
            code: pair.inviteCode,
            loading: loading,
            color: cs.onPrimaryContainer,
            fontSize: 52,
          ),
          const SizedBox(height: 18),
          GestureDetector(
            onTap: () => showRelationshipTypeSheet(context, pair: pair, theme: widget.theme, onChanged: () { if (mounted) setState(() {}); }),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: cs.onPrimaryContainer.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(pair.relationshipEmoji,
                      style: const TextStyle(fontSize: 15)),
                  const SizedBox(width: 7),
                  Text(
                    pair.relationshipLabel,
                    style: TextStyle(
                      fontFamily: 'Onest',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(Icons.expand_more_rounded,
                      size: 18,
                      color: cs.onPrimaryContainer.withValues(alpha: 0.6)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionsRow(ColorScheme cs) {
    final hasCode = pair.inviteCode.isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: hasCode ? _handleCopy : null,
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                key: ValueKey(_copied),
                size: 20,
              ),
            ),
            label: Text(LocaleService.current.copy),
          ),
        ),
        const SizedBox(width: 10),
        _circleButton(
          cs: cs,
          onTap: hasCode ? _handleShare : null,
          child: Icon(Icons.ios_share_rounded,
              size: 22, color: cs.onSecondaryContainer),
        ),
        const SizedBox(width: 10),
        _circleButton(
          cs: cs,
          onTap: _generating ? null : _handleRegenerate,
          child: _generating
              ? ExpressiveLoadingIndicator(
                  color: cs.primary,
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                )
              : Icon(Icons.refresh_rounded,
                  size: 22, color: cs.onSecondaryContainer),
        ),
      ],
    );
  }

  Widget _circleButton({
    required ColorScheme cs,
    required Widget child,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: cs.secondaryContainer,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(width: 56, height: 56, child: Center(child: child)),
      ),
    );
  }

  Widget _chatTile(ColorScheme cs) {
    return PressableScale(
      onTap: _openChat,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(18),
              ),
              child:
                  Icon(Icons.chat_bubble_rounded, color: cs.onPrimary, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                LocaleService.current.chatTitle,
                style: TextStyle(
                  fontFamily: 'Unbounded',
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  color: cs.onSecondaryContainer,
                ),
              ),
            ),
            StreamBuilder<bool>(
              stream:
                  ChatService.instance.watchHasUnread(widget.pairData.pairId),
              builder: (context, snap) {
                if (snap.data != true) return const SizedBox.shrink();
                return Container(
                  margin: const EdgeInsets.only(right: 8),
                  width: 10,
                  height: 10,
                  decoration:
                      BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                );
              },
            ),
            Icon(Icons.arrow_forward_rounded,
                size: 22,
                color: cs.onSecondaryContainer.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }

  Widget _connectTiles(ColorScheme cs) {
    return Row(
      children: [
        Expanded(
          child: _connectTile(
            bg: cs.tertiaryContainer,
            fg: cs.onTertiaryContainer,
            icon: Icons.qr_code_2_rounded,
            label: LocaleService.current.showQr,
            onTap: _showQRDialog,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _connectTile(
            bg: cs.surfaceContainerHighest,
            fg: cs.onSurface,
            icon: Icons.qr_code_scanner_rounded,
            label: LocaleService.current.scanQr,
            onTap: _openQRScanner,
          ),
        ),
      ],
    );
  }

  Widget _connectTile({
    required Color bg,
    required Color fg,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Column(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: fg.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: fg, size: 27),
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Onest',
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _enterCodeCard(ColorScheme cs) {
    final open = _showCodeInput;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(open ? 28 : 999),
      ),
      padding: EdgeInsets.all(open ? 18 : 12),
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showCodeInput = !_showCodeInput),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: cs.tertiaryContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(Icons.keyboard_rounded,
                      color: cs.onTertiaryContainer, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    LocaleService.current.haveACode,
                    style: TextStyle(
                      fontFamily: 'Onest',
                      fontWeight: FontWeight.w700,
                      fontSize: 15.5,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 240),
                  child: Icon(Icons.expand_more_rounded,
                      color: cs.onSurfaceVariant, size: 26),
                ),
              ],
            ),
          ),
          if (open) ...[
            const SizedBox(height: 16),
            _buildCodeInput(),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitCode,
                child: Text(LocaleService.current.connectPartnerBtn),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Бейдж онлайн/офлайн статуса для партнёра
  Widget _buildPresenceBadge(String uid) {
    final isOnline = _partnerOnlineStatus[uid] ?? false;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Container(
        key: ValueKey(isOnline),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isOnline
              ? const Color(0xFF4ADE80).withOpacity(0.12)
              : widget.theme.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline
                    ? const Color(0xFF16A34A)
                    : widget.theme.textMuted,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              isOnline
                  ? LocaleService.current.online
                  : LocaleService.current.offline,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: isOnline
                    ? const Color(0xFF16A34A)
                    : widget.theme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badgeIcon(String uid) {
    final badge = _partnerBadges[uid];
    if (badge == null || badge.isEmpty) return const SizedBox.shrink();
    final icon = ProfileIcon.byId(badge);
    return Transform.translate(
      offset: const Offset(-4, 0),
      child: GestureDetector(
        onTap: icon == null ? null : () => _showBadgeInfo(icon),
        child: Image.asset(
          icon?.asset ?? 'assets/images/icons/$badge.webp',
          width: 38,
          height: 38,
        ),
      ),
    );
  }

  void _showBadgeInfo(ProfileIcon icon) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Image.asset(icon.asset, width: 28, height: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(icon.name)),
          ],
        ),
        content: Text(icon.description),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _memberAvatar(String url, String name, double size) {
    final initial = name.firstGraphemeUpper('?');
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: widget.theme.isDark ? widget.theme.cardBorder : Colors.white,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 4),
        ],
      ),
      child: ClipOval(
        child: url.isNotEmpty
            ? StorageImage(
                imageUrl: url,
                fit: BoxFit.cover,
                errorWidget: (context, url, error) => Container(
                  color: primary.withOpacity(0.15),
                  child: Center(
                    child: Text(
                      initial,
                      style: TextStyle(
                        fontSize: size * 0.4,
                        fontWeight: FontWeight.w700,
                        color: primary,
                      ),
                    ),
                  ),
                ),
              )
            : Container(
                color: primary.withOpacity(0.15),
                child: Center(
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: size * 0.4,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  void _showInviteMoreSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: widget.theme.cardSurface,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: widget.theme.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              LocaleService.current.inviteMoreMembers,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: widget.theme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              LocaleService.current.membersOfMax(
                pair.members.length,
                pair.maxMembers,
              ),
              style: TextStyle(fontSize: 13, color: widget.theme.textMuted),
            ),
            const SizedBox(height: 24),
            _buildCodeCells(
              code: pair.inviteCode,
              color: primary,
              cellWidth: 42,
              cellHeight: 52,
              fontSize: 22,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _outlineButton(
                    icon: Icons.copy_rounded,
                    label: LocaleService.current.copy,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: pair.inviteCode));
                      Navigator.pop(context);
                      _showSnack(LocaleService.current.codeCopied);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        // origin считаем ДО Navigator.pop — иначе контекст
                        // диалога уже мёртв и на iPad popover не откроется.
                        final origin = shareOriginFromContext(context);
                        Navigator.pop(context);
                        await Share.share(
                          LocaleService.current.shareGroupInviteText(
                            pair.inviteCode,
                            pair.inviteLink,
                          ),
                          subject: LocaleService.current.groupInvitation,
                          sharePositionOrigin: origin,
                        );
                      },
                      icon: const Icon(Icons.share_rounded, size: 16),
                      label: Text(
                        LocaleService.current.share,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  UI HELPERS
  // ═══════════════════════════════════════════════════

  String _getConnectedSuccessMessage() {
    final s = LocaleService.current;
    switch (pair.relationshipType) {
      case RelationshipType.couple:
        return s.connectedWithCouple(pair.partnerName);
      case RelationshipType.married:
        return s.marriedTo(pair.partnerName);
      case RelationshipType.friends:
        return s.friendsWith(pair.partnerName);
      case RelationshipType.buddies:
        return s.buddiesWith(pair.partnerName);
      case RelationshipType.custom:
        return s.customRelWith(pair.relationshipLabel, pair.partnerName);
    }
  }

  // ═══════════════════════════════════════════════════
  //  JOIN ANOTHER GROUP (in connected view)
  // ═══════════════════════════════════════════════════
  Widget _buildJoinAnotherGroupCard() {
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.group_add_rounded,
                  color: Color(0xFF3B82F6),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      LocaleService.current.joinAnotherGroup,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: widget.theme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      LocaleService.current.enterCodeScanQr,
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.theme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ── Quick actions: Scan QR and Enter Code ──
          Row(
            children: [
              Expanded(
                child: _outlineButton(
                  icon: Icons.qr_code_scanner_rounded,
                  label: LocaleService.current.scanQr,
                  onTap: _openQRScanner,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _showCodeInput = !_showCodeInput),
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _showCodeInput ? primary : widget.theme.divider,
                      ),
                      color: _showCodeInput ? primary.withOpacity(0.05) : null,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.keyboard_rounded,
                          size: 16,
                          color: _showCodeInput
                              ? primary
                              : widget.theme.textSecondary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          LocaleService.current.enterCode,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _showCodeInput
                                ? primary
                                : widget.theme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_showCodeInput) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _codeController,
              textCapitalization: TextCapitalization.characters,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 8,
                color: primary,
              ),
              decoration: InputDecoration(
                counterText: '',
                hintText: '------',
                hintStyle: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 8,
                  color: widget.theme.textMuted,
                ),
                filled: true,
                fillColor: primary.withOpacity(0.04),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: _codeError
                        ? Colors.red.shade300
                        : primary.withOpacity(0.15),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: _codeError
                        ? Colors.red.shade300
                        : primary.withOpacity(0.15),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: primary, width: 2),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 20,
                ),
              ),
              onChanged: (_) {
                if (_codeError) setState(() => _codeError = false);
              },
            ),
            if (_codeError)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  LocaleService.current.invalidCodeTryAgain,
                  style: TextStyle(fontSize: 12, color: Colors.red.shade400),
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _submitCode,
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 8,
                  shadowColor: primary.withOpacity(0.3),
                ),
                child: Text(
                  LocaleService.current.joinGroup,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _glassCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: widget.theme.isDark
            ? widget.theme.cardSurface
            : const Color(0xC7FFFFFF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: widget.theme.isDark
              ? widget.theme.cardBorder
              : const Color(0x99FFFFFF),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _outlineButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: widget.theme.divider),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: widget.theme.textSecondary),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: widget.theme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  THEMED HELPERS
  // ═══════════════════════════════════════════════════

  Widget _themedCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: widget.theme.cardSurface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: widget.theme.cardBorder, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  /// Показывает 6 ячеек с символами кода. Если код пустой — пульсирующий
  /// скелетон (код ещё генерируется на сервере).
  Widget _buildCodeCells({
    required String code,
    required Color color,
    double cellWidth = 40,
    double cellHeight = 50,
    double fontSize = 20,
  }) {
    if (code.isEmpty) {
      return AnimatedBuilder(
        animation: _pulseController,
        builder: (context, _) {
          final alpha = 0.04 + _pulseController.value * 0.09;
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(6, (_) {
              return Container(
                width: cellWidth,
                height: cellHeight,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: alpha),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: color.withValues(alpha: (alpha * 2).clamp(0.0, 1.0)),
                  ),
                ),
              );
            }),
          );
        },
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: code.split('').map((ch) {
        return Container(
          width: cellWidth,
          height: cellHeight,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.12)),
          ),
          alignment: Alignment.center,
          child: Text(
            ch,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        );
      }).toList(),
    );
  }

  void _openChat() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          pairData: widget.pairData,
          theme: widget.theme,
          userData: widget.userData,
          myDisplayName: widget.userData?.displayName ??
              (PbAuthService().currentProfile()?['displayName'] as String?) ??
              'Me',
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  Widget _buildChatButton() {
    return GestureDetector(
      onTap: _openChat,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: widget.theme.heroGradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: widget.theme.accentGlow(
            primary,
            opacity: 0.25,
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.chat_bubble_rounded,
                    color: Colors.white, size: 24),
                // Красная точка непрочитанных
                Positioned(
                  right: -3,
                  top: -3,
                  child: StreamBuilder<bool>(
                    stream: ChatService.instance
                        .watchHasUnread(widget.pairData.pairId),
                    builder: (context, snap) {
                      if (snap.data != true) return const SizedBox.shrink();
                      return Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                LocaleService.current.chatTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded,
                color: Colors.white70, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 72,
        decoration: BoxDecoration(
          color: widget.theme.cardSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: widget.theme.cardBorder, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: primary),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: widget.theme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCodeInput() {
    return TextField(
      controller: _codeController,
      textCapitalization: TextCapitalization.characters,
      maxLength: 6,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        letterSpacing: 8,
        color: primary,
      ),
      decoration: InputDecoration(
        counterText: '',
        hintText: '------',
        hintStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: 8,
          color: widget.theme.textMuted,
        ),
        filled: true,
        fillColor: primary.withOpacity(0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: _codeError ? Colors.red.shade300 : primary.withOpacity(0.12),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: _codeError ? Colors.red.shade300 : primary.withOpacity(0.12),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 14,
          horizontal: 20,
        ),
      ),
      onChanged: (_) {
        if (_codeError) setState(() => _codeError = false);
      },
    );
  }

  Widget _avatarFallback(String name, double size) {
    final initial = name.firstGraphemeUpper('?');
    return Container(
      width: size,
      height: size,
      color: widget.theme.cardSurface,
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: size * 0.4,
            fontWeight: FontWeight.w700,
            color: primary,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  ACTIONS
  // ═══════════════════════════════════════════════════

  Future<void> _submitCode() async {
    final code = _codeController.text.trim().toUpperCase();
    if (pair.isSelfCode(code)) {
      setState(() => _codeError = true);
      _showSnack(LocaleService.current.cantInviteSelf);
      return;
    }
    final ok = await pair.acceptCode(code);
    // После await экран мог уйти (при успешном коннекте приложение само
    // переключается с этого экрана) → setState на размонтированном State падает
    // (_element! == null внутри setState).
    if (!mounted) return;
    if (ok) {
      setState(() {});
      _showSnack('\u{1F389} ${_getConnectedSuccessMessage()}');
    } else {
      setState(() => _codeError = true);
      _showSnack(LocaleService.current.codeNotFound);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 100),
        backgroundColor: Colors.grey.shade800,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  DIALOGS
  // ═══════════════════════════════════════════════════

  void _showQRDialog() {
    final random = Random();
    final isRickroll = random.nextInt(100) < 10;
    final qrData = isRickroll
        ? 'https://youtu.be/dQw4w9WgXcQ?si=owAivsztmdCvvm6v'
        // QR кодирует прямой deep link (loveapp://invite/CODE): скан камерой
        // открывает приложение сразу. Внутренний сканнер тоже парсит '/invite/'.
        : pair.inviteDeepLink;
    final cs = ProfileTheme.themeFor(widget.theme).colorScheme;
    final s = LocaleService.current;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: cs.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
      ),
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              sheetHandle(cs),
              sheetHeader(cs, s.scanToConnect),
              // QR: круглые модули и глаза в цвете темы; светлая подложка +
              // отступ (quiet zone) и коррекция M — чтобы стилизация не мешала
              // скану.
              Center(
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: QrImageView(
                    data: qrData,
                    version: QrVersions.auto,
                    size: 232,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    padding: EdgeInsets.zero,
                    eyeStyle: QrEyeStyle(
                      eyeShape: QrEyeShape.circle,
                      color: cs.primary,
                    ),
                    dataModuleStyle: QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.circle,
                      color: cs.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                pair.inviteCode,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Unbounded',
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: cs.primary,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 54,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          // iPad: origin ДО await, иначе share-лист не откроется.
                          final origin = shareOriginFromContext(context);
                          await Share.share(
                            s.joinMeLinkText(pair.inviteLink),
                            subject: s.loveAppInvitation,
                            sharePositionOrigin: origin,
                          );
                        },
                        icon: const Icon(Icons.share_rounded, size: 20),
                        label: Text(s.share),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: cs.primary,
                          side: BorderSide(color: cs.outlineVariant),
                          shape: const StadiumBorder(),
                          textStyle: const TextStyle(
                              fontFamily: 'Onest',
                              fontWeight: FontWeight.w700,
                              fontSize: 15),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 54,
                      child: FilledButton(
                        onPressed: () => Navigator.of(sheetCtx).pop(),
                        style: FilledButton.styleFrom(
                          backgroundColor: cs.primary,
                          foregroundColor: cs.onPrimary,
                          shape: const StadiumBorder(),
                          textStyle: const TextStyle(
                              fontFamily: 'Onest',
                              fontWeight: FontWeight.w700,
                              fontSize: 15),
                        ),
                        child: Text(s.done),
                      ),
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

  void _openQRScanner() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const QRScannerScreen(),
        settings: const RouteSettings(name: '/qr_scanner'),
      ),
    );

    if (code != null && mounted) {
      _codeController.text = code;
      _showCodeInput = true;
      setState(() {});
      _submitCode();
    }
  }

  void _showAddGroupDialog() {
    final allCustomTypes = <String, Map<String, String>>{};
    for (final conn in pair.manager.connections) {
      for (final ct in conn.customRelationshipTypes) {
        final id = ct['id'] ?? '';
        if (id.isNotEmpty && !allCustomTypes.containsKey(id)) {
          allCustomTypes[id] = ct;
        }
      }
    }
    final cs = ProfileTheme.themeFor(widget.theme).colorScheme;
    final s = LocaleService.current;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: cs.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
      ),
      builder: (sheetCtx) {
        Future<void> create(RelationshipType type,
            {String customLabel = '', String customEmoji = ''}) async {
          if (_creatingConnection) return;
          _creatingConnection = true;
          Navigator.of(sheetCtx).pop();
          _resetCodeInput();
          try {
            await pair.manager.addNewConnection(
                type: type, customLabel: customLabel, customEmoji: customEmoji);
            if (!mounted) return;
            setState(() {});
            _showSnack(s.newConnectionAdded);
          } finally {
            _creatingConnection = false;
          }
        }

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  sheetHandle(cs),
                  sheetHeader(
                      cs, s.addNewConnection, s.chooseTypeForConnection),
                  typeSheetOption(
                      cs: cs,
                      icon: Icons.favorite_rounded,
                      title: s.inLoveStatus,
                      subtitle: s.perfectForCouples,
                      onTap: () => create(RelationshipType.couple)),
                  typeSheetOption(
                      cs: cs,
                      icon: Icons.diamond_rounded,
                      title: s.married,
                      subtitle: s.forMarriedPartners,
                      onTap: () => create(RelationshipType.married)),
                  typeSheetOption(
                      cs: cs,
                      icon: Icons.handshake_rounded,
                      title: s.friends,
                      subtitle: s.connectWithBestFriend,
                      onTap: () => create(RelationshipType.friends)),
                  typeSheetOption(
                      cs: cs,
                      icon: Icons.groups_rounded,
                      title: s.bestBuddies,
                      subtitle: s.forInseparableCompanions,
                      onTap: () => create(RelationshipType.buddies)),
                  ...allCustomTypes.values.map((ct) => typeSheetOption(
                      cs: cs,
                      icon: relIconForEmoji(ct['emoji'] ?? ''),
                      title: ct['label'] ?? s.custom,
                      subtitle: s.yourCustomType,
                      onTap: () => create(RelationshipType.custom,
                          customLabel: ct['label'] ?? '',
                          customEmoji: ct['emoji'] ?? ''))),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showRenameDialog(GroupMember member) {
    final current = NicknameService.instance.get(member.uid);
    final controller = TextEditingController(text: current);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          LocaleService.current.renamePartner,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              LocaleService.current.renamePartnerHint,
              style: TextStyle(fontSize: 13, color: widget.theme.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 30,
              decoration: InputDecoration(
                hintText: member.name,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: primary, width: 2),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (current.isNotEmpty)
            TextButton(
              onPressed: () async {
                await pair.clearNickname(member.uid);
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (mounted) setState(() {});
              },
              child: Text(
                LocaleService.current.resetNickname,
                style: TextStyle(color: widget.theme.textMuted),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(LocaleService.current.cancel),
          ),
          TextButton(
            onPressed: () async {
              await pair.setNickname(member.uid, controller.text);
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (mounted) setState(() {});
            },
            child: Text(
              LocaleService.current.save,
              style: TextStyle(color: primary, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteConnection(String connectionId) {
    final cs = ProfileTheme.themeFor(widget.theme).colorScheme;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: cs.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 26),
                    decoration: BoxDecoration(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                Center(
                  child: Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                        color: cs.errorContainer, shape: BoxShape.circle),
                    child: Icon(Icons.link_off_rounded,
                        size: 38, color: cs.onErrorContainer),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  LocaleService.current.deleteConnection,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: 'Unbounded',
                      fontWeight: FontWeight.w700,
                      fontSize: 23,
                      height: 1.15,
                      color: cs.onSurface),
                ),
                const SizedBox(height: 10),
                Text(
                  LocaleService.current.deleteConnectionDesc,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: 'Onest',
                      fontSize: 15,
                      height: 1.42,
                      color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(
                          fontFamily: 'Onest',
                          fontSize: 16,
                          fontWeight: FontWeight.w700),
                    ),
                    // Закрываем ДО сетевого removeConnection: после pop кнопки
                    // нет — двойной тап и лишний pop нижнего экрана невозможны.
                    onPressed: () async {
                      Navigator.of(sheetCtx).pop();
                      await pair.manager.removeConnection(connectionId);
                      if (!mounted) return;
                      _resetCodeInput();
                      setState(() {});
                      _showSnack(LocaleService.current.connectionRemoved);
                    },
                    child: Text(LocaleService.current.delete),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 56,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: cs.onSurfaceVariant,
                      shape: const StadiumBorder(),
                      textStyle: const TextStyle(
                          fontFamily: 'Onest',
                          fontSize: 16,
                          fontWeight: FontWeight.w600),
                    ),
                    onPressed: () => Navigator.of(sheetCtx).pop(),
                    child: Text(LocaleService.current.cancel),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showUnpairDialog() async {
    final ok = await AppDialog.confirm(
      context,
      title: LocaleService.current.disconnectQuestion,
      message: LocaleService.current.disconnectDesc,
      confirmLabel: LocaleService.current.disconnect,
      destructive: true,
    );
    if (!ok || !mounted) return;
    pair.unpair();
    setState(() {});
  }
}

// ═══════════════════════════════════════════════════
// QR Scanner Screen
// ═══════════════════════════════════════════════════
class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  bool _codeDetected = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          LocaleService.current.scanPartnersQr,
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: MobileScanner(
        onDetect: (capture) {
          if (_codeDetected) return;

          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
            final String? rawValue = barcode.rawValue;
            if (rawValue != null) {
              String code = rawValue;

              if (rawValue.contains('/invite/')) {
                code = rawValue.split('/invite/').last;
              }

              if (code.length == 6) {
                _codeDetected = true;
                Navigator.pop(context, code.toUpperCase());
                return;
              }
            }
          }
        },
      ),
    );
  }
}
