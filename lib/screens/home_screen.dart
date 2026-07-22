import 'dart:async';
import 'dart:io';
import 'package:in_app_update/in_app_update.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/storage_image.dart';
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:home_widget/home_widget.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import '../utils/photo_crop.dart';
import '../utils/safe_pick.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/memory.dart';
import '../models/pair_achievement.dart';
import '../models/gift.dart';
import '../services/pb_data_service.dart';
import 'achievements_screen.dart';
import 'gifts/gift_shop_screen.dart';
import 'gifts/partner_profile_screen.dart';
import '../widgets/avatar_widget.dart';
import '../services/achievement_service.dart';
import '../widgets/achievement_unlock_overlay.dart';
import '../models/pair_data.dart';
import '../models/user_data.dart';
import '../models/mood_entry.dart';
import '../services/deep_link_service.dart';
import '../services/media_service.dart';
import '../services/memory_repository.dart';
import '../services/pocketbase_service.dart';
import '../services/pb_push_service.dart';
import '../services/push_background_service.dart';
import '../services/widget_background_refresh_service.dart';
import '../services/background_reliability_service.dart';
import '../services/pb_auth_service.dart';
import '../services/presence_service.dart';
import '../services/locale_service.dart';
import '../services/rate_limiter_service.dart';
import '../services/ui_prefs.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_scope.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/common/animations.dart';
import '../widgets/common/m3_loading.dart';
import 'home/widgets/mood_picker_dialog.dart';
import 'home/widgets/relationship_type_dialog.dart';
import 'home/home_header.dart';
import 'home/home_action_buttons.dart';
import 'home/home_memory_preview.dart';
import 'home/home_bottom_nav.dart';
import 'connect_partner_screen.dart';
import 'expandable_timer_card.dart';
import 'memory_lane_screen.dart';
import 'together/together_launcher.dart';
import 'mini_mood_calendar.dart';
import 'mood_calendar_screen.dart';
import 'profile_screen.dart';
import '../services/home_widget_service.dart';
import '../services/mood_service.dart';
import '../services/timer_service.dart';
import '../services/widget_service.dart';
import '../models/mascot.dart';
import '../services/canvas_storage_service.dart';
import '../services/mascot_service.dart';
import '../services/live_location_service.dart';
import '../widgets/active_mascot_widget.dart';
import '../widgets/common/coin_reward_toast.dart';
import 'home/widgets/live_map_card.dart';
import 'mascot_gallery_screen.dart';
import 'widget_screen.dart';

import 'draw_screen.dart';
import 'draw_gallery_screen.dart';
import '../services/celebration_notification_service.dart';
import '../services/days_together_notification_service.dart';
import '../services/mood_notification_service.dart';
import '../widgets/celebration_banner.dart';

class HomeScreen extends StatefulWidget {
  final UserData userData;
  const HomeScreen({super.key, required this.userData});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // -- Theme --
  AppTheme get _t => widget.userData.theme;
  Color get primary => _t.primary;
  Color get primaryLight => _t.primaryLight;

  // -- State --
  int _selectedNavIndex = 0;
  bool _showTodayButton = false;

  // Боковая кнопка навбара: стрелка → (открыть Ленту, дефолт) либо плюс +
  // (сразу создать пин). Хранится в [UiPrefs]; переключается удержанием кнопки
  // или тумблером в настройках. _sideBtnKey нужен для позиционирования
  // одноразовой подсказки про удержание.
  bool _sideActionIsArrow = true;
  final GlobalKey _sideBtnKey = GlobalKey();
  OverlayEntry? _sideHintEntry;
  // Одноразовый флаг: открыть настройки парного виджета при входе на вкладку
  // «Виджеты» (тап по парному виджету рабочего стола). Гасится в _buildWidgetsTab.
  bool _openPairEditorOnWidgetsTab = false;

  StreamSubscription? _deepLinkSub;

  // -- Pair data --
  final PairData _pairData = PairData();

  // -- Timer service --
  final TimerService _timerService = TimerService();

  // -- Mood service --
  final MoodService _moodService = MoodService();

  // -- Widget service --
  final WidgetService _widgetService = WidgetService();

  // -- Mascot service --
  final MascotService _mascotService = MascotService();
  AppLifecycleListener? _appLifecycleListener;

  // -- Memory Lane real-time --
  final MediaService _fb = MediaService();
  final CanvasStorageService _storage = CanvasStorageService.instance;
  List<Memory> _recentMemories = [];
  StreamSubscription? _memorySub;
  StreamSubscription? _achievementSub;

  // -- User location (for distance calc) --
  double? _userLat;
  double? _userLng;
  bool _wasPaired = false;

  /// Раздел подарков включён на сервере. По умолчанию выключен: если конфиг не
  /// прочитался, лучше не показывать кнопку, чем показать неработающую.
  bool _giftsEnabled = false;
  String _lastPairId = '';
  int _pairChangedGeneration = 0;

  // Debounce для _syncHomeWidgets: PairData notifyListeners срабатывает на
  // КАЖДОЕ изменение group doc (mood, status, timer, memories, missYouCount),
  // и каждый syncAllBoundWidgets внутри делает refreshRelationshipStats →
  // 3 Firestore reads. Без дебаунса один действие пользователя выливалось в
  // 5+ каскадных вызовов = 15+ лишних reads. Собираем все события за окно
  // в один вызов.
  Timer? _syncWidgetsDebounce;

  // Дебаунс mood-виджета: на каждое изменение календаря/настроения партнёра
  // _onMoodServiceChanged вызывал syncMood, который копирует PNG-ассеты и
  // пишет 30+ значений в SharedPreferences. При каскаде событий — заметные
  // I/O лаги. Не Firestore reads, но UX-критично на слабых телефонах.
  Timer? _syncMoodWidgetDebounce;
  Timer? _moodStreakRewardDebounce;

  @override
  void initState() {
    super.initState();
    _pairData.addListener(_onPairChanged);
    widget.userData.addListener(_onUserChanged);
    _moodService.addListener(_onMoodServiceChanged);
    _timerService.addListener(_onTimerServiceChanged);
    // Единая точка входа для всех пикеров настроения — MoodService.setMoodForToday.
    // Без bindServices сервис не сможет синхронизировать pair/widget при выборе.
    _moodService.bindServices(
      pairData: _pairData,
      widgetService: _widgetService,
    );
    _timerService.init();
    _initPairData();
    _loadSideActionPref();
    _loadGiftsFlag();

    // Онлайн-презенс: heartbeat в PocketBase, пока приложение активно.
    PresenceService().start();

    // Check if launched from homescreen widget > open Widgets tab
    _checkWidgetLaunch();
    HomeWidget.widgetClicked.listen(_onWidgetClicked);

    // Listen to deep link invites
    _deepLinkSub = DeepLinkService().inviteCodeStream.listen((code) {
      if (mounted && !_pairData.isPaired) {
        // Открываем вкладку подключения (индекс 2 — ConnectPartnerScreen в
        // _buildBody). Раньше стоял 1 = вкладка виджетов, экран пейринга не
        // монтировался и код инвайта в никуда. Сам экран заберёт код из буфера
        // DeepLinkService и/или из стрима.
        setState(() => _selectedNavIndex = 2);
      }
    });

    // Fetch user location for distance display
    _fetchUserLocation();

    // Check for Play Store update after a brief delay
    if (Platform.isAndroid) {
      Future.delayed(const Duration(seconds: 2), _checkForUpdate);
    }

    // Ежедневный бонус и разовые награды — через 4с после старта
    Future.delayed(const Duration(seconds: 4), _tryClaimStartupRewards);

    // Одноразовая подсказка про удержание боковой кнопки — после первого кадра
    // и небольшой задержки (даём навбару отрисоваться и паре загрузиться).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 1600), _maybeShowSideHint);
      // Просьба исключить из оптимизации батареи — без неё Android рвёт фоновый
      // сокет и виджеты/уведомления приходят только при открытии приложения.
      // Показываем с задержкой, чтобы не перекрыть подсказку и дать паре
      // загрузиться. Сервис сам решает, показывать ли (Android, не слишком часто).
      Future.delayed(const Duration(milliseconds: 4000), () {
        if (!mounted || !_pairData.isPaired) return;
        unawaited(
          BackgroundReliabilityService.instance.maybePrompt(context),
        );
      });
    });

    // Пересчёт расписания уведомлений о праздниках при каждом старте.
    Future.microtask(() async {
      await CelebrationNotificationService.instance.rescheduleOnAppStart();
      // Постоянный счётчик «дней вместе» (если включён) — пересчитать число.
      await DaysTogetherNotificationService.instance.rescheduleOnAppStart();
    });

    _appLifecycleListener = AppLifecycleListener(
      onResume: () {
        if (_pairData.isPaired) {
          _mascotService.recordDailyActivity();
          HomeWidgetService.instance.refreshPhotoOfDay(_pairData.pairId);
        }
        // Re-sync the love widget so partner's latest status/mood appears
        // immediately when the user returns to the home screen.
        _widgetService.syncNow();
        // Обновляем число в постоянном счётчике «дней вместе» (могла смениться
        // дата за полночь). No-op, если фича выключена.
        unawaited(DaysTogetherNotificationService.instance.refresh());
        // Lock-screen mood-уведомление: освежаем при возврате (день мог
        // смениться за полночь, настроение могло поменяться вне приложения).
        unawaited(_refreshLockScreenMoodNotification());
        // Попытка ежедневного бонуса при возврате в приложение
        _tryClaimDailyBonus();
      },
    );
  }

  @override
  void dispose() {
    _dismissSideHint();
    _syncWidgetsDebounce?.cancel();
    _syncMoodWidgetDebounce?.cancel();
    _moodStreakRewardDebounce?.cancel();
    _deepLinkSub?.cancel();
    _memorySub?.cancel();
    _achievementSub?.cancel();
    PbPushService().stop();
    _appLifecycleListener?.dispose();
    _mascotService.dispose();
    _timerService.removeListener(_onTimerServiceChanged);
    _pairData.removeListener(_onPairChanged);
    widget.userData.removeListener(_onUserChanged);
    _moodService.removeListener(_onMoodServiceChanged);
    _widgetService.dispose();
    _pairData.dispose();
    super.dispose();
  }

  /// Преобразует запись календаря в MemberMood для шапки.
  /// MoodEntry — каноничный источник для сегодня; HomeHeader исторически
  /// принимает MemberMood, поэтому здесь маппим.
  MemberMood _memberMoodFromEntry(MoodEntry? entry) {
    if (entry == null) return const MemberMood();
    return MemberMood(
      imagePath: entry.imagePath,
      label: entry.localizedLabel,
      updatedAt: entry.timestamp,
    );
  }

  Future<void> _initPairData() async {
    await _pairData.init(myName: widget.userData.displayName);
  }

  /// Проверяет, запущено ли приложение кликом на виджет
  Future<void> _checkWidgetLaunch() async {
    try {
      final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (uri != null) {
        _handleWidgetUri(uri);
      }
    } catch (e) {
      debugPrint('HomeWidget initial launch check failed: $e');
    }
  }

  /// Обработчик клика на виджет рабочего стола
  void _onWidgetClicked(Uri? uri) {
    if (uri != null) {
      _handleWidgetUri(uri);
    }
  }

  void _handleWidgetUri(Uri uri) {
    // loveapp://widgets → вкладка виджетов (index 1)
    // loveapp://widgets/pair → ещё и сразу раскрыть настройки парного виджета
    if (uri.host == 'widgets' || uri.toString().contains('widgets')) {
      final wantPairEditor = uri.pathSegments.contains('pair');
      if (mounted) {
        setState(() {
          _selectedNavIndex = 1;
          if (wantPairEditor) _openPairEditorOnWidgetsTab = true;
        });
      }
    }
    // loveapp://home → главная (index 0)
    else if (uri.host == 'home') {
      if (mounted) {
        setState(() => _selectedNavIndex = 0);
      }
    }
    // loveapp://memory_lane → открыть Memory Lane (с общим навбаром)
    else if (uri.host == 'memory_lane') {
      if (mounted && _pairData.isPaired) {
        _openMemoryLane();
      }
    }
    // loveapp://mood → открыть Mood Calendar
    else if (uri.host == 'mood') {
      if (mounted && _pairData.isPaired) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MoodCalendarScreen(
              pairData: _pairData,
              moodService: _moodService,
              widgetService: _widgetService,
              theme: _t,
            ),
            settings: const RouteSettings(name: '/mood_calendar'),
          ),
        );
      }
    }
  }

  void _onPairChanged() {
    if (!mounted) return;
    unawaited(_handlePairChanged());
    // Появилась пара → можно показать одноразовую подсказку про боковую кнопку.
    unawaited(_maybeShowSideHint());
  }

  /// Когда меняется дефолтный таймер — синхронизируем все виджеты,
  /// чтобы «Дни вместе» подхватил новый таймер так же, как таймер-виджет.
  void _onTimerServiceChanged() {
    if (!mounted || !_pairData.isPaired) return;
    _scheduleSyncHomeWidgets();
    // Уведомление-счётчик «дней вместе» считает от даты ОСНОВНОГО (дефолтного)
    // таймера — той же, что видна в приложении; системный таймер хранит дату
    // пары (≈сегодня) и дал бы 0, если основным сделан пользовательский таймер.
    // При правке даты обновляем уведомление. null НЕ передаём (иначе снялось бы).
    final start = _timerService.defaultTimer?.startDate ??
        _timerService.systemTimer?.startDate ??
        _pairData.startDate;
    if (start != null) {
      unawaited(
        DaysTogetherNotificationService.instance.onStartDateChanged(start),
      );
    }
  }

  Future<void> _handlePairChanged() async {
    if (!mounted) return;
    // Increment generation so stale concurrent calls can self-cancel.
    final generation = ++_pairChangedGeneration;

    final isPaired = _pairData.isPaired;
    final isSolo = _pairData.isSolo;
    final currentPairId = _pairData.pairId;

    // Detect if group changed (even within paired mode)
    final groupChanged = _lastPairId != currentPairId;
    _lastPairId = currentPairId;

    // Re-subscribe to memories ONLY when the group/pairing state actually
    // changed. PairData notifies on every group-doc field update (mood,
    // status, memoriesUpdatedAt, etc.), and each restart re-reads the
    // limit window from Firestore — a major source of read amplification.
    if (groupChanged || _wasPaired != isPaired) {
      _startMemoryListener();
      _updatePartnerPush(isPaired);
    }

    // isPaired check does NOT require startDate — mood/widget services bind
    // to the group regardless of whether startDate is set yet.
    if (isPaired) {
      // Rebind services only when group actually changed or pairing state flipped.
      // Restarting listenToPartner() on every trivial PairData change causes a
      // cascade: Firestore re-emits → MoodService notifies → _onMoodServiceChanged
      // → pairData.setMood → PairData notifies → _handlePairChanged again → loop.
      if (groupChanged || _wasPaired != isPaired) {
        // Unbind from old group first
        await _timerService.unbindFromGroup();
        // Bail if a newer call has already finished and bound to the correct group.
        if (generation != _pairChangedGeneration) return;
        _moodService.unbindFromGroup();
        await _widgetService.unbindFromGroup();
        if (generation != _pairChangedGeneration) return;

        // Bind timer service to group for Firestore sync
        await _timerService.bindToGroup(_pairData.pairId);
        if (generation != _pairChangedGeneration) return;

        // Bind mood service to group for Firestore sync
        _moodService.bindToGroup(_pairData.pairId);

        // Bind widget service to group for Firestore sync
        await _widgetService.bindToGroup(_pairData.pairId);
        if (generation != _pairChangedGeneration) return;
        for (final p in _pairData.partners) {
          _widgetService.listenToPartner(p.uid);
          // Subscribe to partner moods so MoodWidgetProvider stays updated
          _moodService.listenToPartner(p.uid);
        }

        // Bind mascot service only on actual group change.
        // recordDailyActivity makes a Firestore read+write on each call;
        // calling it on every group-doc update (e.g. memoriesUpdatedAt) causes
        // a cascade: write → group listener fires → _handlePairChanged → write …
        _bindMascotService(_pairData.pairId);

        // Возобновляем фоновый шеринг геопозиции (карта «Где мы»), если
        // пользователь его включал. Идемпотентно; при выключенном флаге — no-op.
        unawaited(
          LiveLocationService.instance.resumeIfEnabled(
            _pairData.pairId,
            partnerUid: _pairData.partnerUid,
          ),
        );
      }

      // Create system timer only when startDate is known.
      if (_pairData.startDate != null) {
        if (generation != _pairChangedGeneration) return;
        await _timerService.createSystemTimer(
          startDate: _pairData.startDate!,
          relationshipLabel: _pairData.relationshipLabel,
          relationshipEmoji: _pairData.relationshipEmoji,
          partnerName: _pairData.partnerDisplayName,
        );
        // Title устанавливается только при создании таймера (первый вход в пару).
        // Дальнейшие изменения статуса отношений не меняют название — пользователь
        // может свободно редактировать его через UI.
        // updateSystemTimerTitle был удалён, т.к. перезаписывал ручные правки.

        // Постоянный счётчик «дней вместе»: считаем от даты СИСТЕМНОГО таймера
        // (её пользователь может редактировать — это та же дата, что в видимом
        // круге и в десктоп-виджете «Дни вместе»), а НЕ от даты создания пары
        // (_pairData.startDate) — иначе уведомление расходится с тем, что видно.
        unawaited(
          DaysTogetherNotificationService.instance.onStartDateChanged(
            _timerService.defaultTimer?.startDate ??
                _timerService.systemTimer?.startDate ??
                _pairData.startDate,
          ),
        );
      }

      // Синхронизируем виджеты рабочего стола с актуальными данными
      _scheduleSyncHomeWidgets();
    } else if (isSolo) {
      // Solo mode: load local timers and sync widget
      await _timerService.unbindFromGroup();
      if (generation != _pairChangedGeneration) return;
      _moodService.unbindFromGroup();
      await _widgetService.unbindFromGroup();
      _mascotService.unbind();
      // Sync widgets for solo mode (already done in unbindFromGroup)
      _scheduleSyncHomeWidgets();
    } else {
      await _timerService.unbindFromGroup();
      if (generation != _pairChangedGeneration) return;
      _moodService.unbindFromGroup();
      await _widgetService.unbindFromGroup();
      _mascotService.unbind();
      // Sync widgets for single user mode (no group)
      _scheduleSyncHomeWidgets();
    }

    // Нет пары → убрать постоянный счётчик «дней вместе» из шторки.
    if (!isPaired) {
      unawaited(
        DaysTogetherNotificationService.instance.onStartDateChanged(null),
      );
      // Нет пары → гасим фоновый шеринг геопозиции и убираем свою точку.
      unawaited(
        LiveLocationService.instance.stopSharing(removePoint: true),
      );
    }

    // Auto-navigate to home tab when user just joined a group.
    final justPaired = !_wasPaired && isPaired;
    _wasPaired = isPaired;

    // Разовая награда за приглашение партнёра — триггерим в МОМЕНТ образования
    // пары, а не только на старте (_tryClaimStartupRewards). Иначе свежеподклю-
    // чившийся пользователь видит задание выполненным, но монеты не приходят до
    // перезапуска приложения. Эта точка достигается только пережившим generation-
    // check вызовом, поэтому проблемы прерывания (см. _tryClaimStartupRewards) нет.
    // Идемпотентно: серверный флаг partnerInviteRewardGranted + локальный кеш —
    // повторный вызов вместе со стартовым безопасен.
    if (justPaired) {
      unawaited(_tryClaimPartnerInviteReward());
    }

    if (mounted) {
      setState(() {
        if (justPaired && _selectedNavIndex == 2) {
          _selectedNavIndex = 0;
        }
      });
    }
  }

  void _bindMascotService(String groupId) {
    _mascotService.bindToGroup(groupId);
    // Record that someone opened the app today (streak tracking).
    _mascotService.recordDailyActivity();
  }

  void _openMascotGallery() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MascotGalleryScreen(
          mascotService: _mascotService,
          theme: _t,
          myUid: widget.userData.uid,
        ),
        settings: const RouteSettings(name: '/mascot_gallery'),
      ),
    );
  }

  /// Планирует sync виджетов с дебаунсом 350ms. PairData notifyListeners
  /// срабатывает кучу раз за короткий промежуток (mood + status + timer +
  /// memoriesUpdatedAt и т.д.) — собираем всё в один вызов.
  void _scheduleSyncHomeWidgets() {
    _syncWidgetsDebounce?.cancel();
    _syncWidgetsDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _syncHomeWidgets();
    });
  }

  /// Синхронизирует виджеты рабочего стола.
  /// Вызов дешёвый — обновляет данные виджета только при необходимости.
  Future<void> _syncHomeWidgets() async {
    // Allow single user mode (no group) to sync personal widgets

    final hws = HomeWidgetService.instance;
    final myName = widget.userData.displayName;
    final partnerName = _pairData.partnerDisplayName;

    final myGender = widget.userData.gender?.name ?? '';
    final partnerGender = _widgetService.firstPartnerData?.gender ?? '';

    await hws.syncAllBoundWidgets(
      activeGroupId: _pairData.pairId,
      activeTimers: _timerService.timers,
      activeSysTimer: _timerService.systemTimer,
      activeStartDate: _pairData.startDate,
      coupleNames: '$myName & $partnerName',
      emoji: _pairData.relationshipEmoji,
      myGender: myGender,
      partnerGender: partnerGender,
      relationshipStatusId: _pairData.relationshipStatusId,
      isRomantic:
          _pairData.relationshipType == RelationshipType.couple ||
          _pairData.relationshipType == RelationshipType.married,
      themeIndex: widget.userData.themeId,
    );

    // Sync the mood widget from today's Mood Calendar entries
    await _syncMoodWidget();
  }

  /// пїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅ пїЅпїЅпїЅпїЅпїЅпїЅ пїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅ (MoodWidgetProvider) пїЅ пїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅ
  /// Mood Calendar пїЅпїЅ пїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅ пїЅпїЅпїЅпїЅ пїЅ пїЅ пїЅпїЅпїЅпїЅпїЅ, пїЅ пїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅ.
  Future<void> _syncMoodWidget() async {
    if (!_pairData.isPaired) return;
    final today = DateTime.now();

    // пїЅпїЅ пїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅ пїЅпїЅпїЅпїЅпїЅпїЅпїЅ
    final myEntries = _moodService.myEntriesForDay(today);
    final myEntry = myEntries.isNotEmpty ? myEntries.first : null;

    // пїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅ пїЅпїЅпїЅпїЅпїЅпїЅпїЅпїЅ пїЅпїЅпїЅпїЅпїЅпїЅпїЅ
    final partnerUid = _pairData.partners.isNotEmpty
        ? _pairData.partners.first.uid
        : '';
    final partnerEntries = partnerUid.isNotEmpty
        ? _moodService.partnerEntriesForDay(partnerUid, today)
        : <MoodEntry>[];
    final partnerEntry = partnerEntries.isNotEmpty
        ? partnerEntries.first
        : null;

    if (myEntry == null && partnerEntry == null) {
      debugPrint(
        'HomeWidgetService.syncMood skipped in HomeScreen: no mood entries today',
      );
      return;
    }

    await HomeWidgetService.instance.syncMood(
      groupId: _pairData.pairId,
      moodEmojiAssetPath: myEntry?.imagePath ?? '',
      moodLabel: myEntry?.localizedLabel ?? '',
      moodScore: myEntry?.score ?? 0,
      moodColor: myEntry != null
          ? '#${myEntry.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}'
          : '',
      userName: widget.userData.displayName,
      partnerMoodEmojiAssetPath: partnerEntry?.imagePath ?? '',
      partnerMoodLabel: partnerEntry?.localizedLabel ?? '',
      partnerMoodColor: partnerEntry != null
          ? '#${partnerEntry.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}'
          : '',
      partnerMoodScore: partnerEntry?.score ?? 0,
      partnerUserName: _pairData.partnerDisplayName,
      noMoodText: LocaleService.current.noMoodRecorded,
      nameFallbackMe: LocaleService.current.me,
      nameFallbackPartner: LocaleService.current.partner,
      ratingPrefix: LocaleService.current.moodScorePrefix,
    );
  }

  /// Lock-screen mood-уведомление (Android) живёт отдельно от десктоп-виджета и
  /// раньше обновлялось ТОЛЬКО с экрана виджетов → если настроение задавали в
  /// другом месте (главный экран/календарь), оно застывало на «Настроение не
  /// задано». Держим его в синхроне с настроением здесь — как десктоп-виджет.
  /// No-op, если пары нет или фича выключена.
  Future<void> _refreshLockScreenMoodNotification() async {
    if (!_pairData.isPaired) return;
    final enabled =
        await HomeWidgetService.instance.getLockScreenMoodEnabled();
    if (!enabled) return;
    final today = DateTime.now();
    final myEntries = _moodService.myEntriesForDay(today);
    final myEntry = myEntries.isNotEmpty ? myEntries.first : null;
    final partnerUid =
        _pairData.partners.isNotEmpty ? _pairData.partners.first.uid : '';
    final partnerEntries = partnerUid.isNotEmpty
        ? _moodService.partnerEntriesForDay(partnerUid, today)
        : <MoodEntry>[];
    final partnerEntry =
        partnerEntries.isNotEmpty ? partnerEntries.first : null;
    await MoodNotificationService.instance.show(
      myMood: myEntry?.localizedLabel ?? '',
      myName: widget.userData.displayName,
      partnerMood: partnerEntry?.localizedLabel ?? '',
      partnerName: _pairData.partnerDisplayName,
    );
  }

  void _startMemoryListener() {
    _memorySub?.cancel();
    final groupId = _pairData.pairId;
    if (groupId.isEmpty || !_pairData.isPaired) {
      _recentMemories = [];
      unawaited(AchievementService.instance.stop());
      _achievementSub?.cancel();
      _achievementSub = null;
      return;
    }
    // Достижения пары: следим за счётчиками группы; на разблокировку — оверлей.
    unawaited(AchievementService.instance.start(groupId));
    _achievementSub ??= AchievementService.instance.unlocks.listen((a) {
      if (mounted) AchievementUnlockOverlay.show(context, a);
    });
    // PocketBase live-лента (SSE). Берём 10 свежих для превью на главной —
    // watch отдаёт всё новым-сверху, ограничиваем take(10) как прежний limit.
    _memorySub = MemoryRepository().watch(groupId).listen(
      (memories) {
        if (mounted) {
          // Превью на главной не имеет PIN-гейта/sealed-рендера — прячем
          // секретные и ещё запечатанные капсулы, чтобы не светить контент.
          setState(() => _recentMemories = memories
              .where((m) => !m.sealedNow() && !m.isSecret)
              .take(10)
              .toList());
        }
      },
      onError: (e) => debugPrint('home: memory watch error: $e'),
    );
  }

  /// Уведомления о партнёре (SSE chat/mood/miss_you → локальные баннеры).
  ///
  /// Android: доставку держит [PushBackgroundService] — foreground-сервис с
  /// отдельным изолятом, который продолжает слушать сервер даже когда
  /// приложение свёрнуто или выгружено из недавних (§5). Запускаем его, пока
  /// мы на переднем плане (иначе Android 12+ заблокировал бы старт из фона).
  ///
  /// iOS: постоянный фоновый сокет невозможен (нужен APNs) — слушаем хотя бы
  /// пока приложение открыто, в главном изоляте через [PbPushService].
  void _updatePartnerPush(bool isPaired) {
    final myUid = PocketBaseService().userId ?? '';
    final partnerUid = _pairData.partnerUid;
    if (isPaired && myUid.isNotEmpty && partnerUid.isNotEmpty) {
      // Доставка уведомлений партнёра по SSE — БЕЗ FCM.
      // (1) ГЛАВНЫЙ изолят: подписку держим всегда, пока приложение открыто —
      // здесь та же рабочая PB-сессия и SSE, что питают живые счётчики, поэтому
      // foreground-доставка надёжна и не зависит от запуска сервиса.
      PbPushService().start(
        groupId: _pairData.pairId,
        myUid: myUid,
        partnerUid: partnerUid,
        partnerName: _pairData.partnerDisplayName,
      );
      // (2) Android: вдобавок foreground-сервис — чтобы доставка пережила
      // сворачивание/выгрузку приложения. Уведомления дедуплицируются по
      // детерминированному id, поэтому двойного баннера не будет.
      if (Platform.isAndroid) {
        unawaited(PushBackgroundService().start(
          groupId: _pairData.pairId,
          myUid: myUid,
          partnerUid: partnerUid,
          partnerName: _pairData.partnerDisplayName,
        ));
        // (3) Android: живучий фолбэк — периодический WorkManager-рефреш
        // виджетов на случай, когда OEM-киллер (Xiaomi/Samsung) убил
        // foreground-сервис и realtime-сокет мёртв.
        unawaited(WidgetBackgroundRefreshService.instance.ensureScheduled());
      }
    } else {
      PbPushService().stop();
      unawaited(PushBackgroundService().stop());
      unawaited(WidgetBackgroundRefreshService.instance.cancel());
    }
  }

  void _onUserChanged() {
    if (mounted) setState(() {});
    // Тема пары меняется через userData → синкаем виджеты рабочего стола,
    // иначе лепестковый таймер остаётся на старой/дефолтной теме.
    _scheduleSyncHomeWidgets();
  }

  /// Обновление MoodService: применять изменения настроения из pairData
  /// и синхронизировать виджет настроения при изменении состояния.
  void _onMoodServiceChanged() {
    if (!mounted) return;
    // Sync the Android home-screen mood widget and rebuild the in-app UI.
    // Do NOT call _pairData.setMood() / clearMood() here: that would write to
    // Firestore and call PairData.notifyListeners(), triggering _handlePairChanged
    // which restarts Firestore listeners and creates a feedback loop (blinking).
    // memberMoods stays in sync via the group-document Firestore listener.
    // Дебаунс: setMoodForToday триггерит цепочку (calendar delete → add → pair
    // update → widget update), каждый из которых notify-ит MoodService. Без
    // дебаунса syncMood копирует PNG-ассеты 5+ раз подряд.
    _syncMoodWidgetDebounce?.cancel();
    _syncMoodWidgetDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _syncMoodWidget();
      // Lock-screen mood-уведомление держим в синхроне с настроением (раньше
      // обновлялось только с экрана виджетов → показывало «не задано»).
      unawaited(_refreshLockScreenMoodNotification());
    });
    if (mounted) setState(() {});

    // Проверяем стрик настроения — дебаунс 2с, т.к. _onMoodServiceChanged
    // срабатывает 3-5 раз подряд за одно действие (cascade: delete→add→pair→widget)
    if (_pairData.isPaired) {
      _moodStreakRewardDebounce?.cancel();
      _moodStreakRewardDebounce = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        if (_moodService.bothPartnersStreakDays >= 7)
          _tryClaimMoodStreakReward();
      });
    }
  }

  String get _statusBadgeText {
    if (!_pairData.isPaired) return LocaleService.current.solo;
    return _pairData.relationshipLabel;
  }

  String get _statusBadgeEmoji {
    if (!_pairData.isPaired) return '';
    return _pairData.relationshipEmoji;
  }

  // =============================================
  // BUILD
  // =============================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // -- Background --
          Positioned.fill(
            child: RepaintBoundary(
              child: _t.bgImageUrl != null
                  ? StorageImage(
                      imageUrl: _t.bgImageUrl!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      placeholder: (_, __) => DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: _t.bgGradient,
                          ),
                        ),
                      ),
                      errorWidget: (_, __, ___) => DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: _t.bgGradient,
                          ),
                        ),
                      ),
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: _t.bgGradient,
                        ),
                      ),
                    ),
            ),
          ),
          // -- Main content --
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                HomeHeader(
                  theme: _t,
                  isPaired: _pairData.isPaired,
                  partnerCount: _pairData.partnerCount,
                  myAvatarUrl: widget.userData.avatarUrl,
                  myDisplayName: widget.userData.displayName,
                  partners: _pairData.partners,
                  // Читаем из MoodService — единый источник правды для сегодня.
                  // Раньше шапка читала из pairData.myMood (group memberMoods),
                  // календарь — из moodService entries, и они расходились.
                  myMood: _memberMoodFromEntry(_moodService.myMoodToday),
                  moodOf: (uid) =>
                      _memberMoodFromEntry(_moodService.partnerMoodToday(uid)),
                  statusBadgeText: _statusBadgeText,
                  statusBadgeEmoji: _statusBadgeEmoji,
                  onRelationshipTap: _showRelationshipTypeDialog,
                  pairId: _pairData.pairId,
                ),
                _buildPartnerAilmentBanner(),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
          // -- Active mascot floating overlay --
          if (_pairData.isPaired)
            ActiveMascotWidget(
              mascotService: _mascotService,
              theme: _t,
              onOpenGallery: _openMascotGallery,
            ),
          // -- Theme preview banner (показывается только на главной вкладке) --
          if (widget.userData.isPreviewingTheme && _selectedNavIndex == 0)
            _buildThemePreviewBanner(),
          // -- Bottom Nav (hidden when timer card is expanded) --
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: HomeBottomNav(
              selectedIndex: _selectedNavIndex,
              theme: _t,
              isPaired: _pairData.isPaired,
              onTap: (i) {
                setState(() => _selectedNavIndex = i);
                // Возврат на главную — освежаем режим боковой кнопки (мог
                // смениться в Настройках → Профиль).
                if (i == 0) unawaited(_loadSideActionPref());
              },
              onCreatePin: _pairData.isPaired ? _onSideAction : null,
              sideIsArrow: _sideActionIsArrow,
              onSideLongPress: _pairData.isPaired ? _toggleSideAction : null,
              sideButtonKey: _sideBtnKey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_selectedNavIndex) {
      case 0:
        return _buildHomeTab();
      case 1:
        return _buildWidgetsTab();
      case 2:
        return ConnectPartnerScreen(
          pairData: _pairData,
          theme: _t,
          userData: widget.userData,
        );
      case 3:
        return _buildProfileTab();
      default:
        return _buildHomeTab();
    }
  }

  Future<void> _loadSideActionPref() async {
    final isArrow = await UiPrefs.sideActionIsArrow();
    if (!mounted) return;
    setState(() => _sideActionIsArrow = isArrow);
  }

  /// Тап по боковой кнопке навбара. Стрелка → открывает Ленту (без авто-создания),
  /// плюс + сразу открывает создание пина.
  void _onSideAction() {
    if (_sideActionIsArrow) {
      _openMemoryLane();
    } else {
      _openCreatePin();
    }
  }

  /// Удержание боковой кнопки — переключить режим стрелка ↔ плюс и запомнить.
  Future<void> _toggleSideAction() async {
    final next = !_sideActionIsArrow;
    setState(() => _sideActionIsArrow = next);
    HapticFeedback.selectionClick();
    await UiPrefs.setSideActionIsArrow(next);
    // Если подсказку ещё не закрывали — удержание её закрывает (юзер всё понял).
    _dismissSideHint();
    unawaited(UiPrefs.markSideActionHintSeen());
    if (!mounted) return;
    final s = LocaleService.current;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1600),
        content: Text(next ? s.sideActionOpenFeed : s.sideActionCreatePin),
      ),
    );
  }

  /// Открыть Ленту воспоминаний (общий навбар внутри; вкладки возвращают
  /// на главную через onNavTab). Без авто-создания пина.
  void _openMemoryLane({bool openCreateOnStart = false}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MemoryLaneScreen(
          pairData: _pairData,
          theme: _t,
          userData: widget.userData,
          openCreateOnStart: openCreateOnStart,
          onNavTab: (i) {
            Navigator.of(context).pop();
            setState(() => _selectedNavIndex = i);
          },
        ),
        settings: const RouteSettings(name: '/memory_lane'),
      ),
    );
  }

  /// Открыть Memory Lane сразу на создании нового пина (режим «плюс»).
  void _openCreatePin() => _openMemoryLane(openCreateOnStart: true);

  // ── Одноразовая подсказка про удержание боковой кнопки ──────────────────────
  bool _sideHintResolved = false;

  /// Показывает подсказку один раз: пара есть, мы на главной, кнопка отрисована
  /// и юзер ещё её не видел. Идемпотентно — безопасно дёргать много раз.
  Future<void> _maybeShowSideHint() async {
    if (_sideHintResolved || _sideHintEntry != null) return;
    if (!mounted || !_pairData.isPaired || _selectedNavIndex != 0) return;
    if (await UiPrefs.sideActionHintSeen()) {
      _sideHintResolved = true;
      return;
    }
    if (!mounted || !_pairData.isPaired || _selectedNavIndex != 0) return;
    if (_sideBtnKey.currentContext == null) return; // ещё не отрисована — позже
    _sideHintResolved = true;
    _showSideHint();
  }

  void _showSideHint() {
    final ctx = _sideBtnKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final overlay = Overlay.of(context);
    final pos = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.of(context).size;
    final s = LocaleService.current;
    const bubbleW = 244.0;
    double left = screen.width - 16 - bubbleW;
    if (left < 12) left = 12;
    final bottom = screen.height - pos.dy + 6; // чуть выше кнопки
    // Стрелка-указатель примерно под центром кнопки (правый край экрана).
    final arrowRight = (screen.width - (pos.dx + box.size.width / 2) - 18)
        .clamp(8.0, bubbleW - 36);

    _sideHintEntry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _dismissSideHint,
          child: Stack(
            children: [
              Positioned(
                left: left,
                bottom: bottom,
                width: bubbleW,
                child: Material(
                  color: Colors.transparent,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(14, 12, 12, 6),
                        decoration: BoxDecoration(
                          color: primary,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.touch_app_rounded,
                                    color: Colors.white, size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    s.sideActionHint,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      height: 1.25,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _dismissSideHint,
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: Text(
                                  s.gotIt,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.only(right: arrowRight),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Transform.translate(
                            offset: const Offset(0, -6),
                            child: Icon(Icons.arrow_drop_down,
                                color: primary, size: 38),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    overlay.insert(_sideHintEntry!);
    unawaited(UiPrefs.markSideActionHintSeen());
    Future.delayed(const Duration(seconds: 9), _dismissSideHint);
  }

  void _dismissSideHint() {
    _sideHintEntry?.remove();
    _sideHintEntry = null;
  }

  // =============================================
  // HOME TAB
  // =============================================
  Widget _buildHomeTab() {
    // ── Проверяем праздники сегодня ──
    final conn = _pairData.manager.activeConnection;
    final anniversaryDate = conn?.anniversaryDate;
    final myBirthDate = widget.userData.birthDate;
    final isAnniversaryToday =
        anniversaryDate != null &&
        CelebrationNotificationService.isToday(anniversaryDate);
    final isBirthdayToday =
        myBirthDate != null &&
        CelebrationNotificationService.isToday(myBirthDate);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 100,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Баннер праздника (если сегодня годовщина или ДР) ──
          if (isAnniversaryToday)
            CelebrationBanner(
              message: LocaleService.current.celebrationBannerAnniversary,
              emoji: '🎉',
              color: const Color(0xFFE91E8C),
            ),
          if (isBirthdayToday && !isAnniversaryToday)
            CelebrationBanner(
              message: LocaleService.current.celebrationBannerBirthday,
              emoji: '🎂',
              color: const Color(0xFFFF6B35),
            ),
          // ── Приглашение «смотрим вместе» от партнёра (0 новых чтений:
          //    реюзает hub-листенер group-doc) ──
          if (_pairData.isPaired)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: TogetherInviteBanner(
                pairId: _pairData.pairId,
                partnerUid: _pairData.partnerUid,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 16),
                AnimatedSlideIn(
                  delay: const Duration(milliseconds: 100),
                  child: MiniMoodCalendar(
                    moodService: _moodService,
                    theme: _t,
                    onDayTap: _pairData.isPaired
                        ? _showMoodPickerForDate
                        : null,
                    onTodayButtonVisibilityChanged: (v) =>
                        setState(() => _showTodayButton = v),
                  ),
                ),
                const SizedBox(height: 8),
                // Shift dial UP closer to calendar (disabled when Today button is visible)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  transform: Matrix4.translationValues(
                    0,
                    _showTodayButton ? 0 : -20,
                    0,
                  ),
                  child: AnimatedSlideIn(
                    delay: const Duration(milliseconds: 200),
                    child: ExpandableTimerCard(
                      theme: _t,
                      timerService: _timerService,
                      myAvatarUrl: widget.userData.avatarUrl,
                      partnerAvatarUrl: _pairData.partnerAvatarUrl,
                      isPaired: _pairData.isPaired,
                      onPetalTap: _pairData.isPaired
                          ? (label) => _openMemoryLaneForPetal(label)
                          : null,
                    ),
                  ),
                ),
                // Restore buttons offset to -15 for tighter layout
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  transform: Matrix4.translationValues(
                    0,
                    _showTodayButton ? 0 : -15,
                    0,
                  ),
                  child: AnimatedSlideIn(
                    delay: const Duration(milliseconds: 300),
                    child: HomeActionButtons(
                      theme: _t,
                      isPaired: _pairData.isPaired,
                      // Единый источник правды — календарь (myMoodToday), как у
                      // шапки. Раньше кнопка читала pairData.myMood (group
                      // memberMoods) и расходилась с мини-календарём/шапкой:
                      // настроение с мини-календаря не отображалось на кнопке.
                      myMoodImagePath:
                          _moodService.myMoodToday?.imagePath ?? '',
                      onDraw: _openDraw,
                      onMood: _showMoodPicker,
                      onCalendar: _openMoodCalendar,
                      onPost: _postPhoto,
                    ),
                  ),
                ),
                if (!_pairData.isPaired) ...[
                  const SizedBox(height: 8),
                  AnimatedSlideIn(
                    delay: const Duration(milliseconds: 400),
                    child: _buildConnectPrompt(),
                  ),
                ],
                if (_pairData.isPaired) ...[
                  const SizedBox(height: 8),
                  AnimatedSlideIn(
                    delay: const Duration(milliseconds: 380),
                    child: _buildMascotRow(),
                  ),
                  // Карта «Где мы»: live-геопозиция обоих партнёров.
                  AnimatedSlideIn(
                    delay: const Duration(milliseconds: 420),
                    child: LiveMapCard(
                      pairId: _pairData.pairId,
                      partnerUid: _pairData.partnerUid,
                      partnerName: _pairData.partnerDisplayName,
                      partnerAvatarUrl: _pairData.partnerAvatarUrl,
                      theme: _t,
                    ),
                  ),
                ],
                const SizedBox(height: 40),
              ],
            ),
          ),
          if (_pairData.isPaired)
            AnimatedSlideIn(
              delay: const Duration(milliseconds: 460),
              child: _achievementsEntry(),
            ),
          if (_pairData.isPaired && _giftsEnabled) ...[
            AnimatedSlideIn(
              delay: const Duration(milliseconds: 465),
              child: _partnerEntry(),
            ),
            AnimatedSlideIn(
              delay: const Duration(milliseconds: 470),
              child: _giftsEntry(),
            ),
          ],
          AnimatedSlideIn(
            delay: const Duration(milliseconds: 500),
            child: MemoryLanePreview(
              isPaired: _pairData.isPaired,
              memories: _recentMemories,
              pairData: _pairData,
              theme: _t,
              userLat: _userLat,
              userLng: _userLng,
              userData: widget.userData,
              onNavTab: (i) => setState(() => _selectedNavIndex = i),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildMascotRow() {
    return ValueListenableBuilder<bool>(
      valueListenable: mascotHiddenNotifier,
      builder: (context, isHidden, _) {
        return ListenableBuilder(
          listenable: _mascotService,
          builder: (context, _) {
            return _MascotButton(
              mascot: _mascotService.activeMascot,
              service: _mascotService,
              theme: _t,
              streak: _mascotService.state.activeStreak,
              isHidden: isHidden,
              onTap: _openMascotGallery,
              onShowOverlay: showMascotOverlay,
            );
          },
        );
      },
    );
  }

  // =============================================
  // WIDGETS TAB
  // =============================================
  Widget _buildWidgetsTab() {
    // Флаг открытия настроек парного виджета одноразовый — гасим сразу,
    // чтобы при обычном переходе на вкладку карточка не раскрывалась снова.
    final openPair = _openPairEditorOnWidgetsTab;
    _openPairEditorOnWidgetsTab = false;
    return WidgetScreen(
      userData: widget.userData,
      pairData: _pairData,
      widgetService: _widgetService,
      moodService: _moodService,
      timerService: _timerService,
      mascotService: _mascotService,
      theme: _t,
      openPairEditorOnStart: openPair,
    );
  }

  // =============================================
  // PROFILE TAB
  // =============================================
  Widget _buildProfileTab() {
    return ProfileScreen(
      userData: widget.userData,
      pairData: _pairData,
      timerService: _timerService,
      widgetService: _widgetService,
      onSwitchToHome: () => setState(() => _selectedNavIndex = 0),
    );
  }

  // =============================================
  // THEME PREVIEW BANNER
  // =============================================
  Widget _buildThemePreviewBanner() {
    final previewId = widget.userData.previewThemeId!;
    final t = AppThemes.byIndex(previewId);
    final canAfford = widget.userData.coins >= t.price;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Positioned(
      bottom: 76 + bottomInset,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          decoration: BoxDecoration(
            color: _t.cardSurface,
            borderRadius: BorderRadius.circular(20),
            boxShadow: t.accentGlow(
              t.primary,
              opacity: 0.25,
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
            border: Border.all(color: t.primary.withOpacity(0.15), width: 1),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: t.heroGradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      LocaleService.current.previewLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: _t.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      t.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _t.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Кнопка "Купить"
              GestureDetector(
                onTap: canAfford ? () => _buyPreviewTheme(previewId, t) : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    gradient: canAfford
                        ? LinearGradient(
                            colors: t.heroGradient,
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    color: canAfford ? null : _t.surfaceMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/images/icons/coin.webp',
                        width: 16,
                        height: 16,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${t.price}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: canAfford
                              ? Colors.white
                              : _t.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Кнопка "Закрыть"
              GestureDetector(
                onTap: () {
                  widget.userData.setPreviewTheme(null);
                  setState(() {});
                },
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _t.surfaceMuted,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: _t.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _buyPreviewTheme(int themeId, AppTheme t) async {
    final ok = await widget.userData.purchaseTheme(themeId);
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(content: Text(LocaleService.current.notEnoughCoins)),
        );
      }
      return;
    }
    await widget.userData.setThemeId(themeId);
    widget.userData.setPreviewTheme(null);
    if (mounted) setState(() {});
  }

  // =============================================
  // RELATIONSHIP TYPE DIALOG
  // =============================================
  void _showRelationshipTypeDialog() {
    showRelationshipTypeDialog(
      context: context,
      pairData: _pairData,
      primary: primary,
      onStateChanged: () => setState(() {}),
    );
  }

  // =============================================
  // MOOD PICKER
  // =============================================

  void _openDraw() {
    final s = LocaleService.current;
    final t = _t;
    showModalBottomSheet(
      context: context,
      backgroundColor: t.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.divider,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.drawingMode,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              DrawModeOption(
                icon: Icons.add_circle_outline_rounded,
                color: t.primary,
                title: s.newCanvas,
                subtitle: s.startWithBlankCanvas,
                onTap: () {
                  Navigator.pop(ctx);
                  _openNewCanvas();
                },
              ),
              const SizedBox(height: 10),
              DrawModeOption(
                icon: Icons.collections_rounded,
                color: const Color(0xFF8B5CF6),
                title: s.myDrawings,
                subtitle: s.openSavedDrawing,
                onTap: () {
                  Navigator.pop(ctx);
                  _openDrawGallery();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openMemoryLaneForPetal(String petalLabel) {
    if (!_pairData.isPaired) return;
    final mode = petalLabel == LocaleService.current.daysShortLabel
        ? MemoryFilterMode.day
        : MemoryFilterMode.month;
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 500),
        reverseTransitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (_, __, ___) => MemoryLaneScreen(
          pairData: _pairData,
          theme: _t,
          filterMode: mode,
          userData: widget.userData,
        ),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(
            parent: anim,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.12),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Future<void> _openNewCanvas() async {
    final s = LocaleService.current;
    final canvases = await _storage.getCanvases(
      widget.userData.uid,
      groupId: _pairData.pairId,
    );
    final meta = await _storage.createCanvas(
      widget.userData.uid,
      name: '${s.untitledCanvas} ${canvases.length + 1}',
      groupId: _pairData.pairId,
    );
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DrawScreen(
          userData: widget.userData,
          pairData: _pairData,
          theme: _t,
          canvasId: meta.id,
          canvasName: meta.name,
        ),
        fullscreenDialog: true,
        settings: const RouteSettings(name: '/draw'),
      ),
    );
  }

  void _openDrawGallery() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DrawGalleryScreen(
          userData: widget.userData,
          pairData: _pairData,
          theme: _t,
        ),
        settings: const RouteSettings(name: '/draw_gallery'),
      ),
    );
  }

  void _openMoodCalendar() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MoodCalendarScreen(
          pairData: _pairData,
          moodService: _moodService,
          widgetService: _widgetService,
          theme: _t,
        ),
        settings: const RouteSettings(name: '/mood_calendar'),
      ),
    );
  }

  /// Открыть выбор настроения для конкретной даты.
  void _showMoodPickerForDate(DateTime date) {
    showMoodPickerForDate(
      context: context,
      date: date,
      pairData: _pairData,
      moodService: _moodService,
      widgetService: _widgetService,
      primary: primary,
      navActiveIcon: _t.navActiveIcon, // добавлено
    );
  }

  /// Баннер под шапкой: показывается, когда партнёру нездоровится
  /// (он выбрал «болячку» в пикере «Самочувствие»).
  Widget _buildPartnerAilmentBanner() {
    if (!_pairData.isPaired) return const SizedBox.shrink();
    for (final p in _pairData.partners) {
      final a = _pairData.ailmentOf(p.uid);
      if (a.isNotEmpty) {
        final name = p.name.isNotEmpty ? p.name : LocaleService.current.partner;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _t.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _t.primary.withValues(alpha: 0.18)),
            ),
            child: Row(
              children: [
                Text(a.emoji, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    LocaleService.current.partnerAilmentBanner(name, a.label),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _t.primary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }
    return const SizedBox.shrink();
  }

  void _showMoodPicker() {
    showMoodPicker(
      context: context,
      pairData: _pairData,
      moodService: _moodService,
      widgetService: _widgetService,
      primary: primary,
      navActiveIcon: _t.navActiveIcon, // добавлено
    );
  }

  /// Локальное включение раздела для проверки на своём устройстве:
  /// `flutter build apk --dart-define=GIFTS_FORCE=true`. Так подарки можно
  /// погонять вживую, не открывая их всем парам сразу.
  static const bool _giftsForced = bool.fromEnvironment('GIFTS_FORCE');

  Future<void> _loadGiftsFlag() async {
    if (_giftsForced) {
      if (mounted && !_giftsEnabled) setState(() => _giftsEnabled = true);
      return;
    }
    final on = await PbDataService().fetchGiftsEnabled();
    if (mounted && on != _giftsEnabled) setState(() => _giftsEnabled = on);
  }

  /// Карточка-вход в профиль партнёра: что ему дарили и когда он скучает.
  Widget _partnerEntry() {
    final name = _pairData.partnerDisplayName;
    final avatar = _pairData.partnerAvatarUrl;
    final start = _pairData.startDate;
    final days = start == null
        ? null
        : DateTime.now().difference(start).inDays;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PartnerProfileScreen(
              theme: _t,
              groupId: _pairData.pairId,
              partnerUid: _pairData.partnerUid,
              partnerName: name,
              partnerAvatarUrl: avatar,
              daysTogether: days,
            ),
            settings: const RouteSettings(name: '/partner'),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _t.cardSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _t.divider, width: 0.5),
          ),
          child: Row(
            children: [
              AvatarWidget(
                uid: _pairData.partnerUid,
                liveUrl: avatar,
                name: name,
                size: 44,
                primary: _t.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name.isEmpty ? LocaleService.current.partnerGiftsTitle : name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: _t.textPrimary,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: _t.textMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// Карточка-вход «Подарки». Показывается только когда раздел включён на
  /// сервере (`app_config.gifts_enabled`) — флаг гасит его без релиза.
  Widget _giftsEntry() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GiftShopScreen(
              theme: _t,
              groupId: _pairData.pairId,
              coins: widget.userData.coins,
            ),
            settings: const RouteSettings(name: '/gifts'),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _t.cardSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _t.divider, width: 0.5),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _t.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Image.asset(GiftCatalog.all.first.asset,
                    width: 26, height: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  LocaleService.current.giftShopTitle,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: _t.textPrimary,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: _t.textMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// Компактная карточка-вход «Достижения пары» на главном. Счётчик «N из M»
  /// живёт на снимке [AchievementService.stats] и обновляется в реальном времени.
  Widget _achievementsEntry() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AchievementsScreen(theme: _t),
            settings: const RouteSettings(name: '/achievements'),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _t.cardSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _t.divider, width: 0.5),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _t.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Text('🏆', style: TextStyle(fontSize: 22)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      LocaleService.current.achievementsTitle,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _t.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    ValueListenableBuilder<AchievementStats>(
                      valueListenable: AchievementService.instance.stats,
                      builder: (_, stats, __) {
                        final n = PairAchievement.all
                            .where((a) => a.isUnlockedBy(stats))
                            .length;
                        return Text(
                          LocaleService.current.achievementsUnlockedOf(
                              n, PairAchievement.all.length),
                          style:
                              TextStyle(fontSize: 12.5, color: _t.textMuted),
                        );
                      },
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: _t.textMuted, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  // =============================================
  // POST PHOTO (camera > upload > Memory Lane)
  // =============================================
  Future<void> _postPhoto() async {
    if (!_pairData.isPaired || _pairData.pairId.isEmpty) return;

    final picker = ImagePicker();
    // Отказ в доступе к камере раньше улетал в Crashlytics как Fatal. safePick
    // глотает сбой пикера; onError показывает подсказку про настройки.
    final XFile? photo = await safePick(
      () => picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      ),
      onError: (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(LocaleService.current.cameraPermissionDenied),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      },
    );
    if (photo == null || !mounted) return;

    final croppedPath = await cropPhoto(photo.path, accentColor: _t.primary);
    if (!mounted) return;
    final effectivePath = croppedPath ?? photo.path;

    // Геолокация запускается параллельно с диалогом — не блокирует UI.
    // Пока пользователь вводит название/описание, координаты уже грузятся.
    final locationFuture = _resolvePhotoLocation(effectivePath);

    // Диалог: название/описание + три тумблера «куда отправить».
    // Дефолты тумблеров запоминаются (общие ключи с виджет-экраном).
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final result = await _showCaptionDialog(
      initToMemories: _widgetService.autoSendPhotoToMemory,
      initToPairWidget: prefs.getBool('widget_sendPhotoToPairWidget') ?? true,
      initToPartnerWidget:
          prefs.getBool('widget_sendPhotoToPartnerWidget') ?? true,
      partnerName: _pairData.partnerName,
    );
    if (!mounted) return;
    // null = отмена; ничего не выбрано — выходим.
    if (result == null) return;
    if (!result.toMemories &&
        !result.toPairWidget &&
        !result.toPartnerWidget) {
      return;
    }
    // Запоминаем выбор на следующий раз.
    await _widgetService.setAutoSendPhotoToMemory(result.toMemories);
    await prefs.setBool('widget_sendPhotoToPairWidget', result.toPairWidget);
    await prefs.setBool(
      'widget_sendPhotoToPartnerWidget',
      result.toPartnerWidget,
    );

    // Лимит проверяем только если фото идёт в ленту воспоминаний.
    final messenger = ScaffoldMessenger.of(context);
    if (result.toMemories) {
      try {
        await RateLimiterService().checkMemory();
      } on RateLimitException catch (e) {
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(e.message),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
        return;
      }
    }

    // К этому моменту пользователь уже потратил время на ввод названия —
    // геолокация скорее всего уже готова; ждём максимум 3 сек.
    final location = await locationFuture.timeout(
      const Duration(seconds: 3),
      onTimeout: () => (lat: null, lng: null, name: null),
    );

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: _t.cardSurface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                M3LoadingDots(color: primaryLight),
                const SizedBox(height: 16),
                Text(
                  LocaleService.current.posting,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _t.textSecondary,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      // Upload to Firebase Storage
      final ext = effectivePath.split('.').last;
      final destination =
          'memories/${_pairData.pairId}/${DateTime.now().millisecondsSinceEpoch}.$ext';
      final downloadUrl = await _fb.uploadFile(effectivePath, destination);

      if (downloadUrl == null) {
        if (mounted) Navigator.of(context).pop(); // dismiss loading
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(LocaleService.current.failedUploadPhoto)),
          );
        }
        return;
      }

      // 1. Лента воспоминаний.
      Memory? createdMemory;
      if (result.toMemories) {
        final me = PbAuthService().currentProfile();
        createdMemory = await MemoryRepository().add(
          groupId: _pairData.pairId,
          authorName: (me?['displayName'] as String?) ?? '',
          authorAvatar: (me?['avatarUrl'] as String?) ?? '',
          type: MemoryType.photo,
          imageUrl: downloadUrl,
          title: result.title,
          caption: result.caption,
          locationName: location.name,
          latitude: location.lat,
          longitude: location.lng,
        );
      }
      // add() возвращает null при тихом дропе (нет сессии/пустой groupId). Раньше
      // мы всё равно показывали «Добавлено в ленту воспоминаний!» и начисляли
      // награду — фото уходило в виджеты, но НЕ в воспоминания, а пользователь
      // был уверен в обратном. Теперь отличаем реальный успех от дропа.
      final memoryFailed = result.toMemories && createdMemory == null;
      if (memoryFailed) {
        unawaited(Sentry.captureMessage(
          'Instant photo: memory add returned null (не добавилось в ленту)',
          withScope: (s) {
            s.level = SentryLevel.error;
            s.setExtra('isLoggedIn', PocketBaseService().isLoggedIn);
            s.setExtra('userIdNull', PocketBaseService().userId == null);
            s.setExtra('pairIdEmpty', _pairData.pairId.isEmpty);
          },
        ));
      }

      // 2. Парный виджет (моя половина).
      if (result.toPairWidget) {
        try {
          await _widgetService.updatePhotoUrl(downloadUrl);
        } catch (e) {
          debugPrint('Failed to set pair widget photo: $e');
        }
      }

      // 3. Виджет «Фото партнёра».
      if (result.toPartnerWidget && _pairData.pairId.isNotEmpty) {
        try {
          await _widgetService.updatePhotoForPartnerUrl(downloadUrl);
          await prefs.setString(
            'photo_day_path_${_pairData.pairId}',
            photo.path,
          );
          final hws = HomeWidgetService.instance;
          await hws.refreshPhotoOfDay(_pairData.pairId);
        } catch (e) {
          debugPrint('Failed to set widget photo day: $e');
        }
      }

      if (mounted) Navigator.of(context).pop(); // dismiss loading
      if (mounted) {
        final String msg;
        if (memoryFailed) {
          msg = LocaleService.current.memoryNotSaved;
        } else if (result.toMemories) {
          msg = LocaleService.current.postedToMemoryLane;
        } else {
          msg = LocaleService.current.photoSent;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: memoryFailed ? Colors.orange : primary,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
      // Награда (1 🪙 в день) — только если фото РЕАЛЬНО добавлено в ленту.
      if (result.toMemories && !memoryFailed) _tryClaimMemoryReward();
    } catch (e) {
      if (mounted) Navigator.of(context).pop(); // dismiss loading
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<({double? lat, double? lng, String? name})> _resolvePhotoLocation(
    String photoPath,
  ) async {
    double? lat;
    double? lng;
    String? name;

    try {
      final bytes = await File(photoPath).readAsBytes();
      final exifData = await readExifFromBytes(bytes);
      final latTag = exifData['GPS GPSLatitude'];
      final lngTag = exifData['GPS GPSLongitude'];
      final latRef = exifData['GPS GPSLatitudeRef'];
      final lngRef = exifData['GPS GPSLongitudeRef'];
      if (latTag != null && lngTag != null) {
        lat = _exifGpsToDouble(latTag.values, latRef?.printable ?? 'N');
        lng = _exifGpsToDouble(lngTag.values, lngRef?.printable ?? 'E');
      }
    } catch (e) {
      debugPrint('EXIF extraction failed: $e');
    }

    if (lat == null || lng == null) {
      try {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (serviceEnabled) {
          LocationPermission perm = await Geolocator.checkPermission();
          if (perm == LocationPermission.denied) {
            perm = await Geolocator.requestPermission();
          }
          if (perm == LocationPermission.always ||
              perm == LocationPermission.whileInUse) {
            final pos = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.low,
                timeLimit: Duration(seconds: 10),
              ),
            );
            lat = pos.latitude;
            lng = pos.longitude;
          }
        }
      } catch (e) {
        debugPrint('Geolocator fallback failed: $e');
      }
    }

    if (lat != null && lng != null) {
      try {
        final placemarks = await placemarkFromCoordinates(lat, lng);
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          final parts = <String>[
            if (p.locality != null && p.locality!.isNotEmpty) p.locality!,
            if (p.country != null && p.country!.isNotEmpty) p.country!,
          ];
          if (parts.isNotEmpty) name = parts.join(', ');
        }
      } catch (e) {
        debugPrint('Reverse geocode failed: $e');
      }
    }

    return (lat: lat, lng: lng, name: name);
  }

  Future<
    ({
      String? title,
      String? caption,
      bool toMemories,
      bool toPairWidget,
      bool toPartnerWidget,
    })?
  >
  _showCaptionDialog({
    required bool initToMemories,
    required bool initToPairWidget,
    required bool initToPartnerWidget,
    required String partnerName,
  }) async {
    final titleController = TextEditingController();
    final controller = TextEditingController();
    return showDialog<
      ({
        String? title,
        String? caption,
        bool toMemories,
        bool toPairWidget,
        bool toPartnerWidget,
      })
    >(
      context: context,
      builder: (ctx) {
        bool toMemories = initToMemories;
        bool toPairWidget = initToPairWidget;
        bool toPartnerWidget = initToPartnerWidget;
        return StatefulBuilder(
          builder: (ctx, setDlgState) {
            final partner = partnerName.isNotEmpty
                ? partnerName
                : LocaleService.current.partnerFallback;
            final nothingSelected =
                !toMemories && !toPairWidget && !toPartnerWidget;
            return Dialog(
              backgroundColor: _t.cardSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SvgPicture.asset(
                          'assets/icons/ic_photo.svg',
                          width: 22,
                          height: 22,
                          colorFilter: ColorFilter.mode(
                            _t.textPrimary,
                            BlendMode.srcIn,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          LocaleService.current.newPhoto,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: _t.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Заголовок
                    TextField(
                      controller: titleController,
                      textCapitalization: TextCapitalization.sentences,
                      maxLength: 60,
                      decoration: InputDecoration(
                        hintText: LocaleService.current.titleHint,
                        hintStyle: TextStyle(color: _t.textMuted),
                        filled: true,
                        fillColor: _t.surfaceMuted,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: primary, width: 1.5),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Описание
                    TextField(
                      controller: controller,
                      autofocus: false,
                      maxLines: 3,
                      maxLength: 200,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: LocaleService.current.descriptionOptionalHint,
                        hintStyle: TextStyle(color: _t.textMuted),
                        filled: true,
                        fillColor: _t.surfaceMuted,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: primary, width: 1.5),
                        ),
                        contentPadding: const EdgeInsets.all(16),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Куда отправить фото — три независимых тумблера.
                    _captionDestRow(
                      title: LocaleService.current.captionDestMemories,
                      subtitle: LocaleService.current.captionDestMemoriesSub,
                      value: toMemories,
                      onChanged: (v) => setDlgState(() => toMemories = v),
                    ),
                    _captionDestRow(
                      title: LocaleService.current.captionDestPairWidget,
                      subtitle:
                          LocaleService.current.captionDestPairWidgetSub(partner),
                      value: toPairWidget,
                      onChanged: (v) => setDlgState(() => toPairWidget = v),
                    ),
                    _captionDestRow(
                      title: LocaleService.current.captionDestPartnerWidget,
                      subtitle: LocaleService.current
                          .captionDestPartnerWidgetSub(partner),
                      value: toPartnerWidget,
                      onChanged: (v) => setDlgState(() => toPartnerWidget = v),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text(
                              LocaleService.current.skip,
                              style: TextStyle(
                                color: _t.textMuted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: nothingSelected
                                ? null
                                : () {
                                    final titleText = titleController.text
                                        .trim();
                                    final text = controller.text.trim();
                                    Navigator.pop(ctx, (
                                      title: titleText.isEmpty
                                          ? null
                                          : titleText,
                                      caption: text.isEmpty ? null : text,
                                      toMemories: toMemories,
                                      toPairWidget: toPairWidget,
                                      toPartnerWidget: toPartnerWidget,
                                    ));
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primary,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: _t.surfaceMuted,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            child: Text(
                              LocaleService.current.post,
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Строка-тумблер «куда отправить фото» в диалоге публикации.
  Widget _captionDestRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _t.textPrimary,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 11, color: _t.textMuted),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeColor: primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  // =============================================
  // CONNECT PROMPT (shown when unpaired)
  // =============================================
  Widget _buildConnectPrompt() {
    return GestureDetector(
      onTap: () => setState(() => _selectedNavIndex = 2),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _t.cardSurface,
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: _t.cardBorder, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 24,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: primary.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.person_add_rounded, color: primary, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    LocaleService.current.inviteYourPartner,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: _t.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    LocaleService.current.shareLinkCodeQr,
                    style: TextStyle(fontSize: 13, color: _t.textMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, size: 16, color: primary),
          ],
        ),
      ),
    );
  }

  // =============================================
  // HELPER METHODS: Location, EXIF, Time
  // =============================================

  // ── Ежедневный бонус ────────────────────────────────────────────────────────

  /// Вызывается один раз при старте (через 4с). Надёжнее чем триггер в
  /// _handlePairChanged, который может прерваться из-за generation-check.
  Future<void> _tryClaimStartupRewards() async {
    if (!mounted) return;
    await _tryClaimDailyBonus();
    // Разовая награда за партнёра: сервер сам проверит флаг partnerInviteRewardGranted
    if (_pairData.isPaired) await _tryClaimPartnerInviteReward();
  }

  Future<void> _tryClaimDailyBonus() async {
    if (!mounted) return;
    final awarded = await widget.userData.claimDailyBonus();
    if (!awarded || !mounted) return;
    CoinRewardToast.show(
      context,
      amount: 1,
      label: LocaleService.current.dailyBonusTitle,
    );
  }

  Future<void> _tryClaimMemoryReward() async {
    if (!mounted) return;
    final amount = await widget.userData.claimMemoryReward();
    if (amount <= 0 || !mounted) return;
    CoinRewardToast.show(
      context,
      amount: amount,
      label: LocaleService.current.memoryRewardTitle,
    );
  }

  Future<void> _tryClaimPartnerInviteReward() async {
    if (!mounted) return;
    // Награда теперь за УНИКАЛЬНУЮ пару людей (не одноразово на аккаунт), поэтому
    // и локальный кеш — на конкретного партнёра, а не глобальный флаг.
    final partnerUid = _pairData.partnerUid;
    if (partnerUid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = 'partnerInviteRewarded_local_$partnerUid';
    if (prefs.getBool(cacheKey) == true) return;

    final amount = await widget.userData.claimPartnerInviteReward(partnerUid);
    if (amount > 0) {
      await prefs.setBool(cacheKey, true);
    }
    if (amount <= 0 || !mounted) return;
    CoinRewardToast.show(
      context,
      amount: amount,
      label: LocaleService.current.partnerInviteRewardTitle,
    );
  }

  Future<void> _tryClaimMoodStreakReward() async {
    if (!mounted || _pairData.pairId.isEmpty) return;
    final amount = await widget.userData.claimMoodStreakReward(
      _pairData.pairId,
    );
    if (amount <= 0 || !mounted) return;
    CoinRewardToast.show(
      context,
      amount: amount,
      label: LocaleService.current.moodStreakRewardTitle,
    );
  }

  // ── In-app update ──────────────────────────────────────────────────────────

  Future<void> _checkForUpdate() async {
    if (!mounted) return;
    // Sideload-сборки (установленные из публичного GitHub-репо, а не из Play
    // Store) не получают обновления через Google Play — проверяем version.json
    // в релизах вручную и отдаём установку системному установщику.
    if (await UpdateService.isSideloaded()) {
      final upd = await UpdateService.checkForUpdate();
      if (!mounted || upd == null) return;
      _showGithubUpdateSheet(upd);
      return;
    }
    try {
      final info = await InAppUpdate.checkForUpdate();
      if (!mounted) return;
      if (info.updateAvailability == UpdateAvailability.updateAvailable) {
        _showUpdateSheet(info);
      }
    } catch (e) {
      debugPrint('HomeScreen._checkForUpdate failed: $e');
    }
  }

  /// Лист обновления для sideload-сборок: ведёт на скачивание APK из публичного
  /// GitHub-репо (браузер докачивает файл и вызывает системный установщик).
  void _showGithubUpdateSheet(GithubUpdate upd) {
    final p = primary;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _t.cardSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          24,
          12,
          24,
          MediaQuery.of(ctx).viewPadding.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _t.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: p.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.system_update_rounded, color: p, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        LocaleService.current.updateAvailableTitle,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: _t.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        upd.versionName.isNotEmpty
                            ? '${LocaleService.current.updateAvailableSubtitle} · ${upd.versionName}'
                            : LocaleService.current.updateAvailableSubtitle,
                        style: TextStyle(
                          fontSize: 13,
                          color: _t.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final uri = Uri.parse(upd.apkUrl);
                  try {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  } catch (e) {
                    debugPrint('GitHub update launch failed: $e');
                  }
                },
                icon: const Icon(Icons.download_rounded),
                label: Text(LocaleService.current.updateButton),
                style: ElevatedButton.styleFrom(
                  backgroundColor: p,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  LocaleService.current.updateLaterButton,
                  style: TextStyle(
                    color: _t.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showUpdateSheet(AppUpdateInfo info) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _UpdateBottomSheet(info: info, primaryColor: primary),
    );
  }

  // ── User location ───────────────────────────────────────────────────────────

  /// Fetch user location for distance calculation on photo cards.
  /// На входе в приложение разрешение НЕ запрашиваем — только используем уже
  /// выданное. Иначе пользователю, который отказал, диалог геолокации всплывал
  /// бы на каждом запуске. Сам запрос остаётся в контекстных экранах (добавление
  /// воспоминания с локацией, выбор точки на карте), где он уместен.
  Future<void> _fetchUserLocation() async {
    // Не трогаем GPS, если «Показывать мою геопозицию» выключено. Раньше
    // расстояние до мест на карточках воспоминаний читало GPS при КАЖДОМ
    // открытии главного экрана независимо от тумблера → iOS зажигал индикатор
    // геолокации, хотя трансляция выключена (жалоба тестера). Теперь уважаем
    // тумблер: нет трансляции — нет обращения к GPS.
    if (!LiveLocationService.instance.sharingEnabled.value) return;
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse) {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
            timeLimit: Duration(seconds: 10),
          ),
        );
        if (mounted) {
          setState(() {
            _userLat = pos.latitude;
            _userLng = pos.longitude;
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to get user location: $e');
    }
  }

  /// Convert EXIF GPS rational values to double degrees.
  /// Based on the official exif package example (gps_coords.dart).
  double _exifGpsToDouble(IfdValues values, String ref) {
    if (values is! IfdRatios) return 0.0;

    double sum = 0.0;
    double unit = 1.0;
    for (final v in values.ratios) {
      sum += v.toDouble() * unit;
      unit /= 60.0;
    }

    if (ref == 'S' || ref == 'W') sum = -sum;
    return sum;
  }
}

// ── Mascot preview in the home row ────────────────────────────────────────────

class _MascotPreviewWidget extends StatelessWidget {
  final Mascot mascot;
  final MascotService service;

  const _MascotPreviewWidget({required this.mascot, required this.service});

  @override
  Widget build(BuildContext context) {
    final asset = service.resolvedAssetForMood(mascot);
    if (asset != null) {
      return buildMascotAssetImage(asset, fit: BoxFit.contain);
    }
    // Каталожные (уровневые) маскоты рендерятся по публичному catalogUrl.
    // Без этой ветки они падали в Icon(face) → «нет превью» в карточке серии.
    if (mascot.catalogUrl != null) {
      return CachedNetworkImage(
        imageUrl: mascot.catalogUrl!,
        fit: BoxFit.contain,
        placeholder: (_, _) => const SizedBox.shrink(),
        errorWidget: (_, _, _) => const Icon(Icons.face),
      );
    }
    if (mascot.imageUrl != null) {
      return StorageImage(
        imageUrl: mascot.imageUrl!,
        fit: BoxFit.contain,
        placeholder: (_, _) => const SizedBox.shrink(),
        errorWidget: (_, _, _) => const Icon(Icons.face),
      );
    }
    return const Icon(Icons.face);
  }
}

// ── Animated mascot button ────────────────────────────────────────────────────

class _MascotButton extends StatefulWidget {
  final Mascot? mascot;
  final MascotService service;
  final AppTheme theme;
  final int streak;
  final bool isHidden;
  final VoidCallback onTap;
  final Future<void> Function()? onShowOverlay;

  const _MascotButton({
    required this.mascot,
    required this.service,
    required this.theme,
    required this.streak,
    required this.isHidden,
    required this.onTap,
    this.onShowOverlay,
  });

  @override
  State<_MascotButton> createState() => _MascotButtonState();
}

class _MascotButtonState extends State<_MascotButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mascot = widget.mascot;
    final streak = widget.streak;
    final t = widget.theme;
    final hasStreak = streak > 0;

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: t.cardSurface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: hasStreak
                  ? t.primary.withValues(alpha: 0.22)
                  : t.cardBorder,
              width: hasStreak ? 1.5 : 1.0,
            ),
            boxShadow: hasStreak
                ? t.accentGlow(
                    t.primary,
                    opacity: 0.1,
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  )
                : [],
          ),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: mascot != null
                    ? _MascotPreviewWidget(
                        mascot: mascot,
                        service: widget.service,
                      )
                    : Icon(
                        Icons.sentiment_satisfied_alt,
                        size: 36,
                        color: t.primary.withAlpha(120),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      mascot != null
                          ? mascot.localizedName
                          : LocaleService.current.groupMascot,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (hasStreak)
                      _StreakBadge(
                        streak: streak,
                        theme: t,
                        pulseCtrl: _pulseCtrl,
                      )
                    else
                      Text(
                        mascot != null
                            ? LocaleService.current.tapForGallery
                            : LocaleService.current.selectMascot,
                        style: TextStyle(
                          fontSize: 12,
                          color: t.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              if (mascot != null)
                GestureDetector(
                  onTap: widget.isHidden
                      ? () => widget.onShowOverlay?.call()
                      : null,
                  behavior: HitTestBehavior.opaque,
                  child: widget.isHidden
                      ? Padding(
                          padding: const EdgeInsets.only(left: 4, right: 2),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: t.primary.withAlpha(20),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: t.primary.withAlpha(60),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.visibility_outlined,
                                  size: 14,
                                  color: t.primary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  LocaleService.current.showLabel,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: t.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 14,
                          color: t.textMuted,
                        ),
                )
              else
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 14,
                  color: t.textMuted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Animated streak badge ─────────────────────────────────────────────────────

class _StreakBadge extends StatelessWidget {
  final int streak;
  final AppTheme theme;
  final AnimationController pulseCtrl;

  const _StreakBadge({
    required this.streak,
    required this.theme,
    required this.pulseCtrl,
  });

  Color _color() {
    if (streak >= 30) return const Color(0xFFFF9500);
    if (streak >= 7) return const Color(0xFFFF6B35);
    return theme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final color = _color();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: pulseCtrl,
            builder: (_, _) {
              final scale = Tween<double>(begin: 1.0, end: 1.4)
                  .animate(
                    CurvedAnimation(parent: pulseCtrl, curve: Curves.easeInOut),
                  )
                  .value;
              return Transform.scale(
                scale: scale,
                child: const Text('🔥', style: TextStyle(fontSize: 11)),
              );
            },
          ),
          const SizedBox(width: 5),
          TweenAnimationBuilder<int>(
            tween: IntTween(begin: 0, end: streak),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (_, val, _) => Text(
              LocaleService.current.streakLabel(val),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Update bottom sheet widget
// ─────────────────────────────────────────────────────────────

class _UpdateBottomSheet extends StatefulWidget {
  final AppUpdateInfo info;
  final Color primaryColor;

  const _UpdateBottomSheet({required this.info, required this.primaryColor});

  @override
  State<_UpdateBottomSheet> createState() => _UpdateBottomSheetState();
}

class _UpdateBottomSheetState extends State<_UpdateBottomSheet> {
  bool _isUpdating = false;
  bool _isDownloaded = false;

  Future<void> _startUpdate() async {
    if (_isUpdating) return;
    setState(() => _isUpdating = true);

    try {
      await InAppUpdate.startFlexibleUpdate();
      if (!mounted) return;
      setState(() {
        _isUpdating = false;
        _isDownloaded = true;
      });
    } catch (e) {
      debugPrint('In-app update start failed: $e');
      if (!mounted) return;
      setState(() {
        _isUpdating = false;
        _isDownloaded = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(LocaleService.current.failedUpdateStatus(e.toString())),
        ),
      );
    }
  }

  Future<void> _applyUpdate() async {
    if (!mounted) return;
    Navigator.of(context).maybePop();
    try {
      await InAppUpdate.completeFlexibleUpdate();
    } catch (e) {
      debugPrint('In-app update completion failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(LocaleService.current.failedUpdateStatus(e.toString())),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.primaryColor;
    final t = context.appTheme;
    return Container(
      decoration: BoxDecoration(
        color: t.cardSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      // Отступ снизу учитывает системную навигационную панель (жесты/кнопки),
      // иначе кнопка «перезапустить» налезает на неё и плохо нажимается.
      padding: EdgeInsets.fromLTRB(
          24, 16, 24, 24 + MediaQuery.of(context).viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: t.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // Icon + title row
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: p.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.system_update_rounded, color: p, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      LocaleService.current.updateAvailableTitle,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: t.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      LocaleService.current.updateAvailableSubtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: t.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // What's new block
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 300),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.surfaceMuted,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.divider),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.star_rounded, color: p, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      LocaleService.current.updateWhatsNew,
                      style: TextStyle(
                        fontSize: 13,
                        color: t.textSecondary,
                        fontWeight: FontWeight.w500,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          if (_isDownloaded) ...[
            // Ready to install — restart button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _applyUpdate,
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(LocaleService.current.updateRestartButton),
                style: ElevatedButton.styleFrom(
                  backgroundColor: p,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
              ),
            ),
          ] else ...[
            // Update + Later buttons
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isUpdating ? null : _startUpdate,
                style: ElevatedButton.styleFrom(
                  backgroundColor: p,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: p.withOpacity(0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: _isUpdating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        LocaleService.current.updateButton,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  LocaleService.current.updateLaterButton,
                  style: TextStyle(
                    color: t.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
