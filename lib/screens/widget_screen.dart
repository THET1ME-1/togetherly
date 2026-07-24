import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import '../widgets/mood_image.dart';
import '../widgets/storage_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:home_widget/home_widget.dart';
import 'package:image_picker/image_picker.dart';
import '../utils/safe_pick.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../logic/photo_day_widget_logic.dart';
import '../models/pair_data.dart';
import '../models/timer_item.dart';
import '../models/widget_data.dart';
import '../models/user_data.dart';
import '../models/mood_entry.dart';
import '../models/memory.dart';
import '../services/media_service.dart';
import '../services/pocketbase_service.dart';
import '../services/pb_auth_service.dart';
import '../services/pb_data_service.dart';
import '../services/memory_repository.dart';
import '../services/miss_you_repository.dart';
import '../services/home_widget_service.dart';
import '../services/level_service.dart';
import '../services/locale_service.dart';
import '../services/mood_notification_service.dart';
import '../services/mood_service.dart';
import '../services/mascot_service.dart';
import '../services/timer_service.dart';
import '../services/widget_service.dart';
import '../theme/app_theme.dart';
import '../theme/profile_theme.dart';
import '../widgets/common/ad_banner.dart';
import '../widgets/common/m3_loading.dart';
import '../widgets/petal_timer_dial.dart';
import '../widgets/mood_hearts_preview.dart';
import 'home/widgets/mood_picker_dialog.dart';
import 'home/widgets/photo_day_carousel_editor.dart';
import 'home/widgets/memory_photo_picker.dart';
import 'postcard/postcard_editor_screen.dart';

/// Экран виджетов — два тайла (мой / партнёра) + настройки автоотправки.
class WidgetScreen extends StatefulWidget {
  final UserData userData;
  final PairData pairData;
  final WidgetService widgetService;
  final MoodService moodService;
  final TimerService timerService;
  final MascotService mascotService;
  final AppTheme theme;

  /// Открыт по тапу на парный виджет рабочего стола — сразу разворачиваем
  /// карточку «Парный виджет» и прокручиваем к ней (правка фото/музыки и т.д.).
  final bool openPairEditorOnStart;

  const WidgetScreen({
    super.key,
    required this.userData,
    required this.pairData,
    required this.widgetService,
    required this.moodService,
    required this.timerService,
    required this.mascotService,
    required this.theme,
    this.openPairEditorOnStart = false,
  });

  @override
  State<WidgetScreen> createState() => _WidgetScreenState();
}

class _WidgetScreenState extends State<WidgetScreen>
    with WidgetsBindingObserver {
  AppTheme get _t => widget.theme;
  ColorScheme get _cs => ProfileTheme.themeFor(_t).colorScheme;
  WidgetService get _ws => widget.widgetService;
  MoodService get _moodService => widget.moodService;
  TimerService get _timerService => widget.timerService;
  MascotService get _mascotService => widget.mascotService;
  PairData get _pair => widget.pairData;
  AppStrings get _s => LocaleService.current;

  // Скролл галереи + ключ карточки «Парный виджет» — чтобы прокрутить к ней
  // при открытии по тапу на виджет рабочего стола.
  final ScrollController _galleryScrollController = ScrollController();
  final GlobalKey _pairWidgetKey = GlobalKey();

  bool _canPinWidgets = false;
  bool _pairWidgetExpanded = false;
  bool _timerWidgetExpanded = false;
  bool _petalTimerWidgetExpanded = false;
  // Счётчик дней: персонализация «наши фото» (фича за коины)
  // Цена — зеркало FEATURE_PRICES['days_widget_photos'] на сервере.
  static const int _daysPhotosPrice = 20;
  bool _daysCounterExpanded = false;
  bool _daysPhotosEnabled = false;
  bool _daysPhotosBusy = false;
  String? _widgetTimerId;

  int? _memoriesCount;
  int? _drawingsCount;
  int? _missYouCount;
  StreamSubscription? _missYouSub;
  Timer? _loadPhotoDayDebounce;

  // Экран блокировки: настроение
  bool _lockScreenMoodEnabled = false;

  // Фото-сетка
  bool _photoGridExpanded = false;
  int _photoGridCount = 1; // МОЁ количество (для настройки)
  List<String> _photoGridPaths = []; // локальные пути МОИХ фото (для выбора)
  bool _isLoadingPhotoGrid = false;

  // Фото-виджет (личный) и Фото партнёра — две независимые карточки
  bool _photoDayExpanded = true;
  bool _partnerPhotoExpanded = false;
  bool _savePhotoAsMemory = true;

  List<int> _personalWidgetIds = [];
  List<int> _partnerWidgetIds = [];
  Map<int, String> _photoDayWidgetNames = const {};
  Map<int, String?> _photoDayWidgetOwnPhotoPaths = const {};
  // Per-widget кеш URL-ов (длина → счётчик в превью)
  Map<int, List<String>> _photoDayWidgetUrls = const {};
  // Per-widget настройки ротации (для подсказок в превью)
  Map<int, String> _photoDayWidgetRotationType = const {};
  Map<int, int> _photoDayWidgetRotationInterval = const {};

  int? _selectedPersonalWidgetId;
  int? _selectedPartnerWidgetId;

  String get _widgetTimerKey => 'widget_timer_id_${_pair.pairId}';

  static const String _heartSvg =
      '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor"><path d="m11.645 20.91-.007-.003-.022-.012a15.247 15.247 0 0 1-.383-.218 25.18 25.18 0 0 1-4.244-3.17C4.688 15.36 2.25 12.174 2.25 8.25 2.25 5.322 4.714 3 7.688 3A5.5 5.5 0 0 1 12 5.052 5.5 5.5 0 0 1 16.313 3c2.973 0 5.437 2.322 5.437 5.25 0 3.925-2.438 7.111-4.739 9.256a25.175 25.175 0 0 1-4.244 3.17 15.247 15.247 0 0 1-.383.219l-.022.012-.007.004-.003.001a.752.752 0 0 1-.704 0l-.003-.001Z" /></svg>''';
  static const String _calendarSvg =
      '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor"><path fill-rule="evenodd" d="M6.75 2.25A.75.75 0 0 1 7.5 3v1.5h9V3A.75.75 0 0 1 18 3v1.5h.75a3 3 0 0 1 3 3v11.25a3 3 0 0 1-3 3H5.25a3 3 0 0 1-3-3V7.5a3 3 0 0 1 3-3H6V3a.75.75 0 0 1 .75-.75Zm13.5 9a1.5 1.5 0 0 0-1.5-1.5H5.25a1.5 1.5 0 0 0-1.5 1.5v7.5a1.5 1.5 0 0 0 1.5 1.5h13.5a1.5 1.5 0 0 0 1.5-1.5v-7.5Z" clip-rule="evenodd" /></svg>''';
  static const String _timerSvg =
      '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor"><path fill-rule="evenodd" d="M12 2.25c-5.385 0-9.75 4.365-9.75 9.75s4.365 9.75 9.75 9.75 9.75-4.365 9.75-9.75S17.385 2.25 12 2.25ZM12.75 6a.75.75 0 0 0-1.5 0v6c0 .414.336.75.75.75h4.5a.75.75 0 0 0 0-1.5h-3.75V6Z" clip-rule="evenodd" /></svg>''';
  static const String _photoSvg =
      '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor"><path fill-rule="evenodd" d="M1.5 6a2.25 2.25 0 0 1 2.25-2.25h16.5A2.25 2.25 0 0 1 22.5 6v12a2.25 2.25 0 0 1-2.25 2.25H3.75A2.25 2.25 0 0 1 1.5 18V6ZM3 16.06V18c0 .414.336.75.75.75h16.5A.75.75 0 0 0 21 18v-1.94l-2.69-2.689a1.5 1.5 0 0 0-2.12 0l-.88.879.97.97a.75.75 0 1 1-1.06 1.06l-5.16-5.159a1.5 1.5 0 0 0-2.12 0L3 16.061Zm10.125-7.81a1.125 1.125 0 1 1 2.25 0 1.125 1.125 0 0 1-2.25 0Z" clip-rule="evenodd" /></svg>''';
  static const String _moodSvg =
      '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor"><path fill-rule="evenodd" d="M12 2.25c-5.385 0-9.75 4.365-9.75 9.75s4.365 9.75 9.75 9.75 9.75-4.365 9.75-9.75S17.385 2.25 12 2.25Zm-2.625 6c-.54 0-.828.419-.936.634a1.96 1.96 0 0 0-.189.866c0 .298.059.605.189.866.108.215.395.634.936.634.54 0 .828-.419.936-.634.13-.26.189-.568.189-.866 0-.298-.059-.605-.189-.866-.108-.215-.395-.634-.936-.634Zm4.314.634c.108-.215.395-.634.936-.634.54 0 .828.419.936.634.13.26.189.568.189.866 0 .298-.059.605-.189.866-.108.215-.395.634-.936.634-.54 0-.828-.419-.936-.634a1.96 1.96 0 0 1-.189-.866c0-.298.059-.605.189-.866Zm-4.34 7.964a.75.75 0 0 1-1.061-1.06 5.236 5.236 0 0 1 3.73-1.538 5.236 5.236 0 0 1 3.695 1.538.75.75 0 1 1-1.061 1.06 3.736 3.736 0 0 0-2.639-1.098 3.736 3.736 0 0 0-2.664 1.098Z" clip-rule="evenodd" /></svg>''';
  static const String _statsSvg =
      '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor"><path fill-rule="evenodd" d="M3 6a3 3 0 0 1 3-3h12a3 3 0 0 1 3 3v12a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V6Zm4.5 7.5a.75.75 0 0 1 .75.75v2.25a.75.75 0 0 1-1.5 0v-2.25a.75.75 0 0 1 .75-.75Zm3.75-1.5a.75.75 0 0 0-1.5 0v4.5a.75.75 0 0 0 1.5 0V12Zm2.25-3a.75.75 0 0 1 .75.75v6.75a.75.75 0 0 1-1.5 0V9.75A.75.75 0 0 1 13.5 9Zm3.75-1.5a.75.75 0 0 0-1.5 0v9a.75.75 0 0 0 1.5 0v-9Z" clip-rule="evenodd" /></svg>''';

  // Геттер: выбранный таймер для виджета (любой, включая системный)
  TimerItem? get _widgetTimer {
    final timers = _timerService.timers;
    if (timers.isEmpty) return null;
    if (_widgetTimerId != null) {
      try {
        return timers.firstWhere((t) => t.id == _widgetTimerId);
      } catch (_) {}
    }
    // Приоритет: дефолтный таймер (в т.ч. системный — дата начала отношений)
    return _timerService.defaultTimer ?? timers.first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pair.addListener(_onDataChanged);
    _ws.addListener(_onDataChanged);
    _timerService.addListener(_onDataChanged);
    _moodService.addListener(_onDataChanged);
    _mascotService.addListener(_onDataChanged);
    for (final p in _pair.partners) {
      _moodService.listenToPartner(p.uid);
    }
    // Превью «Огонёк пары» показывает реальную серию. Заодно форсим
    // пере-синхронизацию нативного виджета, чтобы на рабочем столе не висело
    // устаревшее значение.
    _mascotService.resyncStreakWidget();
    _loadAllInitialPrefs();

    // Открыты по тапу на парный виджет → сразу разворачиваем его настройки.
    if (widget.openPairEditorOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openPairEditor());
    }
  }

  /// Разворачивает карточку «Парный виджет» и прокручивает к ней.
  void _openPairEditor() {
    if (!mounted) return;
    setState(() => _pairWidgetExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _pairWidgetKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          alignment: 0.0,
        );
      }
    });
  }

  Future<void> _loadAllInitialPrefs() async {
    final hws = HomeWidgetService.instance;

    final pinSupportedFuture = _checkPinSupportSilent();
    final timerIdFuture = _loadWidgetTimerIdSilent();
    final lockScreenFuture = hws.getLockScreenMoodEnabled();
    final photoGridCount = _ws.myData?.photoGridCount ?? 1;
    final photoDaySaveFuture = hws.getPhotoDaySaveMemory(_pair.pairId);
    final photoDayWidgetsFuture = _loadPhotoDayWidgetsSilent();
    final statsFuture = _loadStatsSilent();
    final daysPhotosFuture = hws.isDaysCounterPhotosEnabled();

    final results = await Future.wait([
      pinSupportedFuture,
      timerIdFuture,
      lockScreenFuture,
      photoDaySaveFuture,
      photoDayWidgetsFuture,
      statsFuture,
      daysPhotosFuture,
    ]);

    if (!mounted) return;

    final canPin = results[0] as bool;
    final timerId = results[1] as String?;
    final lockEnabled = results[2] as bool;
    final photoDaySave = results[3] as bool;
    final photoDayState = results[4] as Map<String, dynamic>;
    final statsState = results[5] as Map<String, dynamic>;
    final daysPhotos = results[6] as bool;

    setState(() {
      _canPinWidgets = canPin;
      _widgetTimerId = timerId;
      _lockScreenMoodEnabled = lockEnabled;
      _savePhotoAsMemory = photoDaySave;
      _daysPhotosEnabled = daysPhotos;
      _photoGridCount = photoGridCount;
      _personalWidgetIds = List<int>.from(photoDayState['personalIds'] ?? []);
      _partnerWidgetIds = List<int>.from(photoDayState['partnerIds'] ?? []);
      _photoDayWidgetNames = Map<int, String>.from(photoDayState['names'] ?? {});
      _photoDayWidgetOwnPhotoPaths = Map<int, String?>.from(photoDayState['ownPhotoPaths'] ?? {});
      _photoDayWidgetUrls = Map<int, List<String>>.from(photoDayState['urls'] ?? {});
      _photoDayWidgetRotationType = Map<int, String>.from(photoDayState['rotationType'] ?? {});
      _photoDayWidgetRotationInterval = Map<int, int>.from(photoDayState['rotationInterval'] ?? {});
      _selectedPersonalWidgetId = photoDayState['selectedPersonal'] as int?;
      _selectedPartnerWidgetId = photoDayState['selectedPartner'] as int?;
      _memoriesCount = statsState['memoriesCount'] as int?;
      _drawingsCount = statsState['drawingsCount'] as int?;
      _missYouCount = statsState['missYouCount'] as int?;
    });

    _startMissYouListener();

    // Post-setState async operations
    await MoodNotificationService.instance.init();
    if (lockEnabled) await _syncLockScreenMoodWidget(true);
  }

  void _startMissYouListener() {
    _missYouSub?.cancel();
    final groupId = _pair.pairId;
    if (groupId.isEmpty) return;
    // Live-счётчик «Я скучаю» (сумма по паре) из PB — чтения бесплатны.
    _missYouSub = MissYouRepository().watchCounts(groupId).listen((counts) {
      if (mounted) {
        setState(
          () => _missYouCount = counts.values.fold<int>(0, (s, v) => s + v),
        );
      }
    });
  }

  Future<bool> _checkPinSupportSilent() async {
    try {
      final supported = await HomeWidget.isRequestPinWidgetSupported();
      return (supported ?? false) || true;
    } catch (_) {
      return true;
    }
  }

  Future<String?> _loadWidgetTimerIdSilent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_widgetTimerKey);
  }

  Future<Map<String, dynamic>> _loadStatsSilent() async {
    final groupId = _pair.pairId;
    if (groupId.isEmpty) {
      return {'memoriesCount': 0, 'drawingsCount': 0, 'missYouCount': 0};
    }

    final rec = await PbDataService().loadGroupById(groupId);
    final memoriesCount = (rec?.data['memories_count'] as num?)?.toInt() ?? 0;
    final drawingsCount = (rec?.data['drawings_count'] as num?)?.toInt() ?? 0;

    return {
      'memoriesCount': memoriesCount,
      'drawingsCount': drawingsCount,
      'missYouCount': null,
    };
  }

  Future<Map<String, dynamic>> _loadPhotoDayWidgetsSilent() async {
    final hws = HomeWidgetService.instance;
    final allIds = await hws.getPhotoDayWidgetIds();
    final rawPersonalIds = await hws.getSelfPhotoWidgetIds();
    final rawPartnerIds = await hws.getPartnerPhotoWidgetIds();
    final personalIds = <int>[];
    final partnerIds = <int>[];

    for (final id in rawPersonalIds) {
      final widgetGroupId = await hws.getPhotoDayWidgetGroupId(id);
      final isCurrentGroup = _pair.pairId.isEmpty
          ? (widgetGroupId == null || widgetGroupId.isEmpty || widgetGroupId == 'solo')
          : (widgetGroupId == _pair.pairId || widgetGroupId == null);
      if (isCurrentGroup) personalIds.add(id);
    }

    for (final id in rawPartnerIds) {
      final widgetGroupId = await hws.getPhotoDayWidgetGroupId(id);
      final isCurrentGroup = _pair.pairId.isEmpty
          ? (widgetGroupId == null || widgetGroupId.isEmpty || widgetGroupId == 'solo')
          : (widgetGroupId == _pair.pairId || widgetGroupId == null);
      if (isCurrentGroup) partnerIds.add(id);
    }

    final selectedPersonal = PhotoDayWidgetLogic.resolveSelectedWidgetId(
      personalIds,
      _selectedPersonalWidgetId,
    );
    final selectedPartner = PhotoDayWidgetLogic.resolveSelectedWidgetId(
      partnerIds,
      _selectedPartnerWidgetId,
    );

    final widgetNames = <int, String>{};
    final widgetOwnPhotoPaths = <int, String?>{};
    final widgetUrls = <int, List<String>>{};
    final widgetRotationType = <int, String>{};
    final widgetRotationInterval = <int, int>{};

    for (final widgetId in allIds) {
      widgetNames[widgetId] = (await hws.getPhotoDayWidgetName(widgetId)) ?? '';
      final widgetDisplay = await hws.getPhotoDayWidgetDisplay(widgetId);
      final widgetMode = await hws.getPhotoDayWidgetMode(
        widgetId,
        fallbackGroupId: _pair.pairId,
      );
      final preview = await hws.getPhotoDayWidgetPreview(widgetId);
      var customPath = await hws.getPhotoDayWidgetCustomPath(widgetId);
      if (customPath != null &&
          customPath.isNotEmpty &&
          !File(customPath).existsSync()) {
        customPath = null;
      }
      final urls = await hws.getPhotoDayWidgetUrls(widgetId);
      widgetUrls[widgetId] = urls;
      widgetRotationType[widgetId] = await hws.getPhotoDayWidgetRotationType(
        widgetId,
      );
      widgetRotationInterval[widgetId] = await hws
          .getPhotoDayWidgetRotationInterval(widgetId);

      final preferredOwnPath = _resolveWidgetPreviewPath(
        isPartner: widgetDisplay == 'partner',
        widgetUrls: urls,
        widgetPreviewPath: preview['path'],
      );

      final widgetState = PhotoDayWidgetLogic.resolveState(
        selectedWidgetId: widgetId,
        mode: widgetMode,
        display: widgetDisplay,
        widgetPreviewPath: preview['path'],
        widgetCustomPath: customPath,
        fallbackPartnerPhotoPath: _partnerSharedPreviewPath,
      );
      widgetOwnPhotoPaths[widgetId] =
           preferredOwnPath ?? widgetState.ownPhotoPath;
    }

    return {
      'personalIds': personalIds,
      'partnerIds': partnerIds,
      'names': widgetNames,
      'ownPhotoPaths': widgetOwnPhotoPaths,
      'urls': widgetUrls,
      'rotationType': widgetRotationType,
      'rotationInterval': widgetRotationInterval,
      'selectedPersonal': selectedPersonal,
      'selectedPartner': selectedPartner,
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Пользователь вернулся из лончера (после добавления виджета на рабочий
    // стол) — обновляем список виджетов, чтобы новый виджет появился сразу.
    if (state == AppLifecycleState.resumed) {
      _loadPhotoDayWidgets();
    }
  }

  void _loadStats() {
    _missYouSub?.cancel();
    final groupId = _pair.pairId;
    if (groupId.isEmpty) {
      if (mounted) {
        setState(() {
          _memoriesCount = 0;
          _drawingsCount = 0;
          _missYouCount = 0;
        });
      }
      return;
    }

    // Денормализованные счётчики из group-дока PB.
    PbDataService().loadGroupById(groupId).then((rec) {
      if (rec == null || !mounted) return;
      setState(() {
        _memoriesCount = (rec.data['memories_count'] as num?)?.toInt() ?? 0;
        _drawingsCount = (rec.data['drawings_count'] as num?)?.toInt() ?? 0;
      });
    });

    // Live-счётчик «Я скучаю» (сумма по паре) из PB.
    _missYouSub = MissYouRepository().watchCounts(groupId).listen((counts) {
      if (mounted) {
        setState(
          () => _missYouCount = counts.values.fold<int>(0, (s, v) => s + v),
        );
      }
    });
  }

  Future<void> _loadWidgetTimerId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_widgetTimerKey);
    if (mounted) setState(() => _widgetTimerId = id);
  }

  Future<void> _loadPhotoDayPrefs() async {
    final hws = HomeWidgetService.instance;
    final save = await hws.getPhotoDaySaveMemory(_pair.pairId);

    if (mounted) {
      setState(() => _savePhotoAsMemory = save);
    }
  }

  Future<void> _loadPhotoDayWidgets() async {
    final hws = HomeWidgetService.instance;
    final allIds = await hws.getPhotoDayWidgetIds();
    final rawPersonalIds = await hws.getSelfPhotoWidgetIds();
    final rawPartnerIds = await hws.getPartnerPhotoWidgetIds();
    final personalIds = <int>[];
    final partnerIds = <int>[];

    for (final id in rawPersonalIds) {
      final widgetGroupId = await hws.getPhotoDayWidgetGroupId(id);
      final isCurrentGroup = _pair.pairId.isEmpty
          ? (widgetGroupId == null || widgetGroupId.isEmpty || widgetGroupId == 'solo')
          : (widgetGroupId == _pair.pairId || widgetGroupId == null);
      if (isCurrentGroup) personalIds.add(id);
    }

    for (final id in rawPartnerIds) {
      final widgetGroupId = await hws.getPhotoDayWidgetGroupId(id);
      final isCurrentGroup = _pair.pairId.isEmpty
          ? (widgetGroupId == null || widgetGroupId.isEmpty || widgetGroupId == 'solo')
          : (widgetGroupId == _pair.pairId || widgetGroupId == null);
      if (isCurrentGroup) partnerIds.add(id);
    }

    final selectedPersonal = PhotoDayWidgetLogic.resolveSelectedWidgetId(
      personalIds,
      _selectedPersonalWidgetId,
    );
    final selectedPartner = PhotoDayWidgetLogic.resolveSelectedWidgetId(
      partnerIds,
      _selectedPartnerWidgetId,
    );

    final widgetNames = <int, String>{};
    final widgetOwnPhotoPaths = <int, String?>{};
    final widgetUrls = <int, List<String>>{};
    final widgetRotationType = <int, String>{};
    final widgetRotationInterval = <int, int>{};

    for (final widgetId in allIds) {
      widgetNames[widgetId] = (await hws.getPhotoDayWidgetName(widgetId)) ?? '';
      final widgetDisplay = await hws.getPhotoDayWidgetDisplay(widgetId);
      final widgetMode = await hws.getPhotoDayWidgetMode(
        widgetId,
        fallbackGroupId: _pair.pairId,
      );
      final preview = await hws.getPhotoDayWidgetPreview(widgetId);
      var customPath = await hws.getPhotoDayWidgetCustomPath(widgetId);
      if (customPath != null &&
          customPath.isNotEmpty &&
          !File(customPath).existsSync()) {
        customPath = null;
      }
      final urls = await hws.getPhotoDayWidgetUrls(widgetId);
      widgetUrls[widgetId] = urls;
      widgetRotationType[widgetId] = await hws.getPhotoDayWidgetRotationType(
        widgetId,
      );
      widgetRotationInterval[widgetId] = await hws
          .getPhotoDayWidgetRotationInterval(widgetId);

      // Превью: для личного виджета сначала свои URL, для партнёрского —
      // фото партнёра из Firestore, чтобы карточка сразу показывала именно его.
      final preferredOwnPath = _resolveWidgetPreviewPath(
        isPartner: widgetDisplay == 'partner',
        widgetUrls: urls,
        widgetPreviewPath: preview['path'],
      );

      // myPhotoUrl (Firestore) используется только если у виджета есть
      // собственные URL — иначе новый виджет копировал бы превью уже
      // настроенного виджета.
      final widgetState = PhotoDayWidgetLogic.resolveState(
        selectedWidgetId: widgetId,
        mode: widgetMode,
        display: widgetDisplay,
        widgetPreviewPath: preview['path'],
        widgetCustomPath: customPath,
        fallbackPartnerPhotoPath: _partnerSharedPreviewPath,
      );
      widgetOwnPhotoPaths[widgetId] =
           preferredOwnPath ?? widgetState.ownPhotoPath;
    }

    if (!mounted) return;
    setState(() {
      _personalWidgetIds = personalIds;
      _partnerWidgetIds = partnerIds;
      _photoDayWidgetNames = widgetNames;
      _photoDayWidgetOwnPhotoPaths = widgetOwnPhotoPaths;
      _photoDayWidgetUrls = widgetUrls;
      _photoDayWidgetRotationType = widgetRotationType;
      _photoDayWidgetRotationInterval = widgetRotationInterval;
      _selectedPersonalWidgetId = selectedPersonal;
      _selectedPartnerWidgetId = selectedPartner;
    });
  }

  Future<void> _selectPhotoDayWidget(int widgetId) async {
    final hws = HomeWidgetService.instance;
    final kind = await hws.getPhotoDayWidgetKind(widgetId);
    if (!mounted) return;
    setState(() {
      if (kind == 'partner') {
        _selectedPartnerWidgetId = widgetId;
      } else {
        _selectedPersonalWidgetId = widgetId;
      }
    });
  }

  Future<void> _toggleSavePhotoAsMemory(bool value) async {
    final hws = HomeWidgetService.instance;
    await hws.setPhotoDaySaveMemory(_pair.pairId, value);
    if (mounted) setState(() => _savePhotoAsMemory = value);
  }

  String? get _partnerSharedPreviewPath {
    final partnerUrls =
        _ws.firstPartnerData?.photoForPartnerUrls ?? const <String>[];
    if (partnerUrls.isNotEmpty) return partnerUrls.first;

    final singleUrl = _ws.firstPartnerData?.photoForPartnerUrl;
    if (singleUrl != null && singleUrl.isNotEmpty) return singleUrl;

    return null;
  }

  String? _resolveWidgetPreviewPath({
    required bool isPartner,
    required List<String> widgetUrls,
    required String? widgetPreviewPath,
  }) {
    if (isPartner) {
      return _partnerSharedPreviewPath ?? widgetPreviewPath;
    }

    if (widgetUrls.isNotEmpty) return widgetUrls.first;
    return widgetPreviewPath;
  }


  Future<void> _toggleLockScreenMood(bool value) async {
    final hws = HomeWidgetService.instance;
    await hws.setLockScreenMoodEnabled(value);
    if (mounted) setState(() => _lockScreenMoodEnabled = value);
    await _syncLockScreenMoodWidget(value);
  }

  Future<void> _syncLockScreenMoodWidget(bool enabled) async {
    final hws = HomeWidgetService.instance;
    final mns = MoodNotificationService.instance;

    if (!_pair.isPaired) {
      await mns.hide();
      return;
    }

    final today = DateTime.now();
    final myEntries = _moodService.myEntriesForDay(today);
    final myEntry = myEntries.isNotEmpty ? myEntries.first : null;
    final partnerUid = _pair.partners.isNotEmpty
        ? _pair.partners.first.uid
        : '';
    final partnerEntries = partnerUid.isNotEmpty
        ? _moodService.partnerEntriesForDay(partnerUid, today)
        : <MoodEntry>[];
    final partnerEntry = partnerEntries.isNotEmpty
        ? partnerEntries.first
        : null;
    final myName = _ws.myData?.displayName ?? '';
    final partnerName = _pair.partnerDisplayName;

    // iOS: HomeWidget (LockScreenMoodWidgetProvider)
    await hws.syncLockScreenMood(
      enabled: enabled,
      moodEmojiAssetPath: myEntry?.imagePath ?? '',
      moodLabel: myEntry?.localizedLabel ?? '',
      userName: myName,
      partnerMoodEmojiAssetPath: partnerEntry?.imagePath ?? '',
      partnerMoodLabel: partnerEntry?.localizedLabel ?? '',
      partnerUserName: partnerName,
    );

    // Android: постоянное уведомление на шторке / экране блокировки
    if (enabled) {
      await mns.show(
        myMood: myEntry?.localizedLabel ?? '',
        myName: myName,
        partnerMood: partnerEntry?.localizedLabel ?? '',
        partnerName: partnerName,
      );
    } else {
      await mns.hide();
    }
  }

  Future<void> _showPhotoDayPhotoSourcePicker(int widgetId) async {
    await _selectPhotoDayWidget(widgetId);
    if (!mounted) return;

    final hws = HomeWidgetService.instance;

    // Каждый виджет редактирует ТОЛЬКО свои фото (per-widgetId).
    // Новый виджет открывается с пустым редактором — фото Firestore других
    // виджетов сюда не подставляются, чтобы каждый экземпляр был уникальным.
    final List<String> initialPaths = await hws.getPhotoDayWidgetUrls(widgetId);

    final initialRotationType = await hws.getPhotoDayWidgetRotationType(
      widgetId,
    );
    final initialRotationInterval = await hws.getPhotoDayWidgetRotationInterval(
      widgetId,
    );

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => PhotoDayCarouselEditor(
        theme: _t,
        initialPaths: initialPaths,
        initialRotationType: initialRotationType,
        initialRotationInterval: initialRotationInterval,
        onPickFromMemories: _pair.pairId.isNotEmpty
            ? (maxCount) => MemoryPhotoPicker.show(
                  ctx,
                  groupId: _pair.pairId,
                  theme: _t,
                  maxCount: maxCount,
                  alreadySelected: initialPaths,
                )
            : null,
        onSave:
            ({
              required paths,
              required rotationType,
              required rotationInterval,
            }) async {
              await _saveCarouselForWidget(
                widgetId: widgetId,
                paths: paths,
                rotationType: rotationType,
                rotationInterval: rotationInterval,
              );
            },
      ),
    );
  }

  Future<void> _showPhotoForPartnerSourcePicker() async {
    if (_pair.pairId.isEmpty) return;

    final initialPaths =
        _ws.myData?.photoForPartnerUrls ?? const <String>[];

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => PhotoDayCarouselEditor(
        theme: _t,
        initialPaths: initialPaths,
        initialRotationType: 'none',
        initialRotationInterval: 60,
        onPickFromMemories: (maxCount) => MemoryPhotoPicker.show(
          ctx,
          groupId: _pair.pairId,
          theme: _t,
          maxCount: maxCount,
          alreadySelected: initialPaths,
        ),
        onSave:
            ({
              required paths,
              required rotationType,
              required rotationInterval,
            }) async {
              await _savePhotosForPartner(paths);
            },
      ),
    );
  }

  Future<void> _saveCarouselForWidget({
    required int widgetId,
    required List<String> paths,
    required String rotationType,
    required int rotationInterval,
  }) async {
    final hws = HomeWidgetService.instance;
    final fb = MediaService();

    List<String> uploadedUrls = [];

    // Upload local files, keep remote urls (http/https, gs:// or sb://)
    for (int i = 0; i < paths.length; i++) {
      final path = paths[i];
      if (path.startsWith('http') ||
          path.startsWith('gs://') ||
          path.startsWith('sb://') ||
          path.startsWith('pb://')) {
        // Уже загруженный URL (в т.ч. pb:// — фото «из ленты») — переиспользуем,
        // НЕ пытаемся грузить как локальный файл (File(pb://) не существует).
        uploadedUrls.add(path);
      } else {
        try {
          final uid = PocketBaseService().userId ?? '';
          final ts = DateTime.now().millisecondsSinceEpoch;
          // Когда pairId пустой (соло-режим), используем uid как папку.
          // Путь с пустым сегментом (widget//uid.jpg) отклоняется Firebase Storage.
          final folder = _pair.pairId.isNotEmpty ? _pair.pairId : uid;

          if (_savePhotoAsMemory && _pair.pairId.isNotEmpty) {
            final destination = 'memories/$folder/photo_day_$ts.jpg';
            final uploadedUrl = await fb.uploadFile(path, destination);
            if (uploadedUrl != null) {
              final me = PbAuthService().currentProfile();
              await MemoryRepository().add(
                groupId: _pair.pairId,
                authorName: (me?['displayName'] as String?) ?? '',
                authorAvatar: (me?['avatarUrl'] as String?) ?? '',
                type: MemoryType.photo,
                imageUrl: uploadedUrl,
                caption: LocaleService.current.setAsPhotoOfDay,
              );
              uploadedUrls.add(uploadedUrl);
            }
          } else {
            final uploadedUrl = await fb.uploadFile(
              path,
              'widget/$folder/${uid}_$ts.jpg',
            );
            if (uploadedUrl != null) uploadedUrls.add(uploadedUrl);
          }
        } catch (e) {
          debugPrint('Failed to upload photo for carousel: $e');
        }
      }
    }

    // Per-widget URL-набор: каждый экземпляр виджета держит СВОИ фото.
    await hws.setPhotoDayWidgetUrls(widgetId, uploadedUrls);

    // Личный фото-виджет — всегда custom (без режима «случайное из воспоминаний»).
    await hws.setPhotoDayWidgetMode(widgetId, 'custom');
    await hws.setPhotoDayWidgetRotationType(widgetId, rotationType);
    await hws.setPhotoDayWidgetRotationInterval(widgetId, rotationInterval);

    // Provide the first local path for backward compatibility preview logic
    if (paths.isNotEmpty) {
      await hws.setPhotoDayWidgetCustomPath(widgetId, paths.first);
    }

    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    await hws.refreshPhotoOfDay(_pair.pairId, widgetId: widgetId);
    await _loadPhotoDayWidgets();
  }

  Future<void> _savePhotosForPartner(List<String> paths) async {
    final fb = MediaService();
    final uid = PocketBaseService().userId ?? '';
    final groupId = _pair.pairId;
    if (uid.isEmpty || groupId.isEmpty) return;

    final uploadedUrls = <String>[];

    for (final path in paths) {
      if (path.startsWith('http') ||
          path.startsWith('gs://') ||
          path.startsWith('sb://') ||
          path.startsWith('pb://')) {
        uploadedUrls.add(path);
        continue;
      }

      try {
        final ts = DateTime.now().millisecondsSinceEpoch;
        final uploadedUrl = await fb.uploadFile(
          path,
          'widget/$groupId/${uid}_partner_$ts.jpg',
        );
        if (uploadedUrl != null) {
          uploadedUrls.add(uploadedUrl);
        }
      } catch (e) {
        debugPrint('Failed to upload photo for partner widget: $e');
      }
    }

    await _ws.updatePhotoForPartnerCarousel(uploadedUrls);
    // Не вызываем refreshPhotoOfDay здесь: виджет «Фото партнёра» на ЭТОМ устройстве
    // показывает фото ПАРТНЁРА, а не мои. Устройство партнёра обновится само через
    // Firestore-листенер, когда получит изменение моего документа.
    await _loadPhotoDayWidgets();
  }

  Future<void> _renamePhotoDayWidget(int widgetId, String nextName) async {
    final trimmedName = nextName.trim();
    await HomeWidgetService.instance.setPhotoDayWidgetName(
      widgetId,
      trimmedName,
    );
    if (!mounted) return;
    setState(() {
      _photoDayWidgetNames = Map<int, String>.from(_photoDayWidgetNames)
        ..[widgetId] = trimmedName;
    });
  }

  void _showPhotoDayWidgetNameEditor(int widgetId, int index) {
    _showTextEditor(
      title: _s.edit,
      hint: _s.name,
      initial: _photoDayWidgetNames[widgetId]?.trim().isNotEmpty == true
          ? _photoDayWidgetNames[widgetId]!
          : _s.widgetSlotTitle(index),
      maxLength: 40,
      onSave: (value) => _renamePhotoDayWidget(widgetId, value),
    );
  }

  Future<void> _selectWidgetTimer(TimerItem timer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_widgetTimerKey, timer.id);
    if (mounted) setState(() => _widgetTimerId = timer.id);
    await HomeWidgetService.instance.syncTimer(timer, groupId: _pair.pairId);
  }

  Future<void> _pinWidget(String qualifiedName, {String? widgetType}) async {
    debugPrint(
      '_pinWidget called: qualifiedName=$qualifiedName, widgetType=$widgetType',
    );
    try {
      final className = qualifiedName.split('.').last;
      debugPrint('_pinWidget: requesting pin for className=$className');

      // Photo day self: works for both solo and paired modes
      if (widgetType == 'photo_day_self') {
        await HomeWidgetService.instance.enqueuePhotoDayWidgetConfig(
          groupId: _pair.pairId,
          // Личный фото-виджет всегда работает с собственными фото пользователя.
          mode: 'custom',
          kind: 'self',
        );
      } else if (widgetType == 'photo_day_partner' && _pair.pairId.isNotEmpty) {
        // Partner photo widget requires a group (partner)
        await HomeWidgetService.instance.enqueuePhotoDayWidgetConfig(
          groupId: _pair.pairId,
          mode: 'random',
          kind: 'partner',
        );
      }

      // Save next_bind_group so Kotlin picks it up on first onUpdate.
      // 'streak' uses global keys (not per-group binding) — skip it, otherwise
      // the default switch branch would wrongly hijack the timer binding.
      if (widgetType != null &&
          !widgetType.startsWith('photo_day') &&
          widgetType != 'pair' &&
          widgetType != 'streak') {
        final realType = widgetType;
        final bindTypeKey = switch (realType) {
          'petal_timer' => 'petal_timer',
          'days_counter' => 'days_counter',
          'mood' => 'mood',
          'stats' || 'relationship_stats' => 'stats',
          _ => 'timer', // 'timer' and others
        };
        await HomeWidget.saveWidgetData<String>(
          '${bindTypeKey}_next_bind_group',
          _pair.pairId,
        );
      }

      await HomeWidget.requestPinWidget(
        name: className,
        androidName: className,
      );
      debugPrint('_pinWidget: requestPinWidget completed successfully');
      unawaited(LevelService.instance.award(XpAction.setWidget));
      // Привязываем виджет к текущей группе и СРАЗУ синхронизируем данные
      // For solo mode, we still sync with empty groupId
      if (widgetType != null) {
        final realType = widgetType.startsWith('photo_day')
            ? 'photo_day'
            : widgetType;
        await HomeWidgetService.instance.bindWidgetToGroup(
          realType,
          _pair.pairId,
        );
        // Немедленно записать актуальные данные в виджет
        await _syncWidgetDataAfterPin(widgetType);
        if (widgetType.startsWith('photo_day')) {
          await _loadPhotoDayWidgets();
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.widgetAddedToHome),
            backgroundColor: Colors.green.shade400,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('Pin widget failed: $e');
      debugPrint('Pin widget stack: $stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.failedAddWidget('$e')),
            backgroundColor: Colors.red.shade400,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Сразу после пина записывает данные текущей группы в виджет.
  Future<void> _syncWidgetDataAfterPin(String widgetType) async {
    final hws = HomeWidgetService.instance;
    switch (widgetType) {
      case 'days_counter':
        // Используем тот же алгоритм выбора таймера, что и Timer-виджет,
        // чтобы Days Counter всегда показывал дни того же таймера.
        final activeTimer = await hws.resolveActiveTimerPublic(
          _timerService.timers,
          _pair.pairId,
        );
        final timer = activeTimer ??
            _timerService.systemTimer ??
            _timerService.defaultTimer;
        final start = timer?.startDate ?? _pair.startDate;
        final emoji = timer?.emoji ?? _pair.relationshipEmoji;
        final days = timer != null
            ? timer.daysElapsed.abs()
            : (start != null ? DateTime.now().difference(start).inDays : 0);
        final startLabel = start != null
            ? '${start.day.toString().padLeft(2, '0')}.${start.month.toString().padLeft(2, '0')}.${start.year}'
            : '';
        final names = _pair.partnerName.isNotEmpty ? _pair.partnerName : '';
        await hws.syncDaysCounter(
          groupId: _pair.pairId,
          daysCount: days,
          coupleNames: names,
          emoji: emoji,
          startDate: startLabel,
          myGender: widget.userData.gender?.name ?? '',
          partnerGender: _ws.firstPartnerData?.gender ?? '',
        );
        break;
      case 'timer':
      case 'petal_timer':
        final timer = _widgetTimer;
        if (timer != null) await hws.syncTimer(timer, groupId: _pair.pairId);
        break;
      case 'photo_day_self':
      case 'photo_day_partner':
      case 'photo_day':
        // Ждём, пока система зарегистрирует новый виджет (requestPinWidget возвращает
        // управление сразу, а ID появляется только когда пользователь бросает виджет
        // на рабочий стол). Без задержки новый виджет ещё не виден в getPhotoDayWidgetIds.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final ids = await hws.getPhotoDayWidgetIds();
        // Передаём kind явно, чтобы не было race condition когда Kotlin ещё
        // не записал kind='partner' в SharedPreferences через assignConfig().
        final partnerIds = (await hws.getPartnerPhotoWidgetIds()).toSet();
        for (final widgetId in ids) {
          final widgetGroupId = await hws.getPhotoDayWidgetGroupId(widgetId);
          // For solo mode, sync widgets without group or with empty group
          final shouldSync = _pair.pairId.isEmpty
              ? (widgetGroupId == null || widgetGroupId.isEmpty)
              : (widgetGroupId == _pair.pairId || widgetGroupId == null);
          if (shouldSync) {
            await hws.refreshPhotoOfDay(
              _pair.pairId,
              widgetId: widgetId,
              overrideKind: partnerIds.contains(widgetId) ? 'partner' : null,
            );
          }
        }
        if (ids.isEmpty) {
          await hws.refreshPhotoOfDay(_pair.pairId);
        }
        break;
      case 'photo_grid':
        // Photo grid requires a group (partner), skip for solo mode
        if (_pair.pairId.isNotEmpty) {
          await hws.refreshPhotoGrid(_pair.pairId);
        }
        break;
      case 'pair':
        // Парный виджет синхронизируется WidgetService
        break;
      case 'mood':
        // Ждём, пока система зарегистрирует новый виджет перед синхронизацией.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        // Синхронизируем из Mood Calendar за сегодня
        {
          final today = DateTime.now();
          final myEntries = _moodService.myEntriesForDay(today);
          final myEntry = myEntries.isNotEmpty ? myEntries.first : null;
          final partnerUid = _pair.partners.isNotEmpty
              ? _pair.partners.first.uid
              : '';
          final partnerEntries = partnerUid.isNotEmpty
              ? _moodService.partnerEntriesForDay(partnerUid, today)
              : <MoodEntry>[];
          final partnerEntry = partnerEntries.isNotEmpty
              ? partnerEntries.first
              : null;
          await hws.syncMood(
            groupId: _pair.pairId,
            moodEmojiAssetPath: myEntry?.imagePath ?? '',
            moodLabel: myEntry?.localizedLabel ?? '',
            moodScore: myEntry?.score ?? 0,
            moodColor: myEntry != null ? '#${myEntry.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}' : '',
            userName: _ws.myData?.displayName ?? '',
            partnerMoodEmojiAssetPath: partnerEntry?.imagePath ?? '',
            partnerMoodLabel: partnerEntry?.localizedLabel ?? '',
            partnerMoodColor: partnerEntry != null ? '#${partnerEntry.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}' : '',
            partnerMoodScore: partnerEntry?.score ?? 0,
            partnerUserName: _pair.partnerName,
            noMoodText: _s.noMoodRecorded,
            nameFallbackMe: _s.me,
            nameFallbackPartner: _s.partner,
            ratingPrefix: _s.moodScorePrefix,
          );
        }
        break;
      case 'relationship_stats':
        // «Дни вместе» от ОСНОВНОГО (дефолтного) таймера — как Days Counter и
        // круг; системный таймер хранит дату пары (≈сегодня) → давал бы 0.
        final relTimer = _timerService.defaultTimer ?? _timerService.systemTimer;
        final start = relTimer?.startDate ?? _pair.startDate;
        await hws.syncRelationshipStats(
          groupId: _pair.pairId,
          daysTogether: start != null
              ? DateTime.now().difference(start).inDays
              : 0,
          memoriesCount: _memoriesCount ?? 0,
          drawingsCount: _drawingsCount ?? 0,
          missYouCount: _missYouCount ?? 0,
          daysLabel: LocaleService.current.daysTogetherStat,
          memoriesLabel: LocaleService.current.memoriesStat,
          drawingsLabel: LocaleService.current.drawingsStat,
          missYouLabel: LocaleService.current.missYousStat,
        );
        break;
    }
  }

  @override
  void didUpdateWidget(WidgetScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pairData.pairId != widget.pairData.pairId) {
      // Сменилась группа — загружаем выбор таймера для новой группы
      _loadWidgetTimerId();
      _loadStats();
      _loadPhotoDayPrefs();
      _loadPhotoDayWidgets();
    }
    // Тап по парному виджету, когда вкладка «Виджеты» уже открыта (initState
    // не пересоздаётся) — ловим переход флага false→true.
    if (!oldWidget.openPairEditorOnStart && widget.openPairEditorOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openPairEditor());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _missYouSub?.cancel();
    _loadPhotoDayDebounce?.cancel();
    _pair.removeListener(_onDataChanged);
    _ws.removeListener(_onDataChanged);
    _timerService.removeListener(_onDataChanged);
    _moodService.removeListener(_onDataChanged);
    _mascotService.removeListener(_onDataChanged);
    _galleryScrollController.dispose();
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) setState(() {});
    // Обновляем уведомление при изменении настроения
    if (_lockScreenMoodEnabled) {
      _syncLockScreenMoodWidget(true);
    }
    // Если изменились фото-сетки партнёра — обновляем нативный виджет
    final partnerGridUrls = _ws.firstPartnerData?.photoGridUrls ?? [];
    if (partnerGridUrls.isNotEmpty && _pair.pairId.isNotEmpty) {
      HomeWidgetService.instance.refreshPhotoGrid(_pair.pairId);
    }
    if (_pair.pairId.isNotEmpty) {
      _loadPhotoDayDebounce?.cancel();
      _loadPhotoDayDebounce = Timer(
        const Duration(milliseconds: 500),
        _loadPhotoDayWidgets,
      );
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // BUILD
  // ════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _t.bgImageUrl != null
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
        SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  controller: _galleryScrollController,
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                      20, 8, 20, 120 + MediaQuery.of(context).padding.bottom),
                  child: Column(
                    children: [
                      // ── Открытки ──
                      _buildPostcardBanner(),
                      const SizedBox(height: 16),
                      // ── Галерея виджетов рабочего стола ──
                      _buildWidgetGallery(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // HEADER
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: _cs.secondaryContainer,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(Icons.widgets_rounded,
                color: _cs.onSecondaryContainer, size: 24),
          ),
          const SizedBox(width: 12),
          Text(
            _s.widgetsTitle,
            style: TextStyle(
              fontFamily: 'Unbounded',
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
              color: _cs.onSurface,
            ),
          ),
          const Spacer(),
          // Сбросить мой виджет
          if (_ws.myData != null && !_ws.myData!.isEmpty)
            GestureDetector(
              onTap: _confirmClearAll,
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.restart_alt_rounded, size: 18, color: _cs.primary),
                  const SizedBox(width: 6),
                  Text(
                    _s.resetBtn,
                    style: TextStyle(
                      fontFamily: 'Onest',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _cs.primary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // WIDGET PREVIEW (как выглядит на рабочем столе)
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildWidgetPreview() {
    final my = _ws.myData ?? WidgetData(uid: '');
    final partner = _ws.firstPartnerData ?? WidgetData(uid: '');

    // Те же источники фото, что и в нативном виджете (_syncToNativeWidget):
    // моя сторона — ТОЛЬКО photoUrl (фото «для партнёра» сюда не протекает);
    // сторона партнёра — photoForPartnerUrl, иначе photoUrl.
    final myPhoto = my.photoUrl ?? '';
    final partnerPhoto = (partner.photoForPartnerUrl?.isNotEmpty ?? false)
        ? partner.photoForPartnerUrl!
        : (partner.photoUrl ?? '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Icon(
                Icons.phone_android_rounded,
                size: 14,
                color: _t.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                _s.desktopPreview,
                style: GoogleFonts.rubik(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _t.textMuted,
                ),
              ),
            ],
          ),
        ),
        // 1:1 с нативным LoveWidget: две половины (фото или цветная панель),
        // по центру круглый эмодзи, аватар в углу, белый разделитель с сердцем.
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 2.0,
              child: Row(
                children: [
                  Expanded(
                    child: _buildPreviewHalf(
                      data: my,
                      photoUrl: myPhoto,
                      panelColor: const Color(0xFFFFCDD9),
                      isLeft: true,
                    ),
                  ),
                  // Разделитель с сердцем (как в нативном виджете)
                  Container(
                    width: 14,
                    color: Colors.white,
                    alignment: Alignment.center,
                    child: const Text(
                      '♥',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFFFF6B8A),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _buildPreviewHalf(
                      data: partner,
                      photoUrl: partnerPhoto,
                      panelColor: const Color(0xFFE8DAFF),
                      isLeft: false,
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

  Widget _buildPreviewHalf({
    required WidgetData data,
    required String photoUrl,
    required Color panelColor,
    required bool isLeft,
  }) {
    final hasPhoto = photoUrl.isNotEmpty;
    final textColor = hasPhoto ? Colors.white : const Color(0xCC000000);
    final subColor = hasPhoto
        ? Colors.white.withOpacity(0.85)
        : const Color(0x99000000);

    Widget panel() => ColoredBox(color: panelColor);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Фон: фото (cover) или цветная панель
        if (hasPhoto)
          StorageImage(
            imageUrl: photoUrl,
            fit: BoxFit.cover,
            placeholder: (_, __) => panel(),
            errorWidget: (_, __, ___) => panel(),
          )
        else
          panel(),
        // Лёгкое затемнение поверх фото
        if (hasPhoto) const ColoredBox(color: Color(0x1A000000)),
        // Центральный контент
        Padding(
          padding: const EdgeInsets.all(6),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (data.hasMood)
                  ClipOval(
                    child: Image.asset(
                      data.moodEmoji,
                      width: 38,
                      height: 38,
                      fit: BoxFit.cover,
                    ),
                  ),
                if (data.hasStatus) ...[
                  const SizedBox(height: 4),
                  Text(
                    data.status,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.rubik(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (data.hasMessage) ...[
                  const SizedBox(height: 2),
                  Text(
                    data.message,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.rubik(
                      fontSize: 9,
                      color: subColor,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (data.hasMusic) ...[
                  const SizedBox(height: 3),
                  Text(
                    '♪ ${data.musicTitle}',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.rubik(
                      fontSize: 8,
                      color: subColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
        // Аватар в нижнем углу (как в нативном виджете)
        if (data.avatarUrl.isNotEmpty)
          Positioned(
            bottom: 4,
            left: isLeft ? 4 : null,
            right: isLeft ? null : 4,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: ClipOval(
                child: StorageImage(
                  imageUrl: data.avatarUrl,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) =>
                      ColoredBox(color: Colors.white.withOpacity(0.4)),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // WIDGET GALLERY — все виджеты с превью и кнопкой «Добавить»
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildWidgetGallery() {
    final isPaired = _pair.isPaired;

    // Простые виджеты — компактными плитками по два в ряд (бенто).
    final halfTiles = <Widget>[
      if (isPaired)
        _buildHalfItem(
          title: LocaleService.current.widgetStreakTitle,
          qualifiedName: 'com.togetherly.love.StreakWidgetProvider',
          widgetType: 'streak',
          preview: _streakCompact(),
        ),
      _buildHalfItem(
        title: LocaleService.current.timerWidgetTitle,
        qualifiedName: 'com.togetherly.love.TimerWidgetProvider',
        widgetType: 'timer',
        preview: _timerCompact(),
        onPreviewTap: _openTimerSelectorSheet,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, top: 6, bottom: 14),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _cs.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.dashboard_customize_rounded,
                    size: 18, color: _cs.onSecondaryContainer),
              ),
              const SizedBox(width: 11),
              Text(
                LocaleService.current.homeScreenWidgets,
                style: TextStyle(
                  fontFamily: 'Unbounded',
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: _cs.onSurface,
                ),
              ),
            ],
          ),
        ),

        // ── 1. Парный виджет ──
        if (!isPaired) ...[_buildNotPairedBanner(), const SizedBox(height: 16)],

        if (isPaired) ...[
          KeyedSubtree(
            key: _pairWidgetKey,
            child: _buildGalleryItem(
              title: LocaleService.current.pairWidgetTitle,
              subtitle: LocaleService.current.pairWidgetSubtitle,
              svgString: _heartSvg,
              qualifiedName: 'com.togetherly.love.LoveWidgetProvider',
              preview: _buildWidgetPreview(),
              widgetType: 'pair',
              expandedContent: _buildPairWidgetExpandedContent(),
              isExpanded: _pairWidgetExpanded,
              onToggleExpand: () =>
                  setState(() => _pairWidgetExpanded = !_pairWidgetExpanded),
            ),
          ),
          const SizedBox(height: 16),

          // ── Баннер 1 ──
          _buildAdBanner('ad_banner_1'),
          const SizedBox(height: 16),

          // ── 2. Счётчик дней вместе ──
          _buildGalleryItem(
            title: LocaleService.current.daysTogetherStat,
            subtitle: LocaleService.current.daysCounterSubtitle,
            svgString: _calendarSvg,
            qualifiedName: 'com.togetherly.love.DaysCounterWidgetProvider',
            preview: _buildDaysCounterPreview(),
            widgetType: 'days_counter',
            expandedContent: _buildDaysPhotosCard(),
            isExpanded: _daysCounterExpanded,
            onToggleExpand: () =>
                setState(() => _daysCounterExpanded = !_daysCounterExpanded),
          ),
          const SizedBox(height: 16),
        ],

        // ── Бенто: Огонёк + Таймер по два в ряд ──
        _halfGrid(halfTiles),
        if (halfTiles.isNotEmpty) const SizedBox(height: 16),

        // ── Лепестковый таймер (настоящее превью + выбор) ──
        _buildGalleryItem(
          title: LocaleService.current.widgetPetalTimerTitle,
          subtitle: LocaleService.current.widgetPetalTimerSubtitle,
          svgString: _timerSvg,
          qualifiedName: 'com.togetherly.love.PetalTimerWidgetProvider',
          preview: _buildPetalTimerPreview(),
          widgetType: 'petal_timer',
          expandedContent: _buildTimerSelector(),
          isExpanded: _petalTimerWidgetExpanded,
          onToggleExpand: () => setState(
            () => _petalTimerWidgetExpanded = !_petalTimerWidgetExpanded,
          ),
        ),
        const SizedBox(height: 16),

        if (isPaired) ...[
          // ── Настроение (настоящее превью) ──
          _buildGalleryItem(
            title: LocaleService.current.mood,
            subtitle: LocaleService.current.moodWidgetSubtitle,
            svgString: _moodSvg,
            qualifiedName: 'com.togetherly.love.MoodWidgetProvider',
            preview: _buildMoodPreview(),
            widgetType: 'mood',
          ),
          const SizedBox(height: 16),
          // ── Статистика отношений (настоящее превью) ──
          _buildGalleryItem(
            title: LocaleService.current.relationshipStats,
            subtitle: LocaleService.current.relationshipStatsSubtitle,
            svgString: _statsSvg,
            qualifiedName:
                'com.togetherly.love.RelationshipStatsWidgetProvider',
            preview: _buildRelationshipStatsPreview(),
            widgetType: 'relationship_stats',
          ),
          const SizedBox(height: 16),
        ],

        // ── 4. Фото-виджет (личный) ──
        if (isPaired || _pair.isSolo) ...[
          _buildGalleryItem(
            title: LocaleService.current.widgetPhotoTitle,
            subtitle: LocaleService.current.widgetPhotoSubtitle,
            svgString: _photoSvg,
            qualifiedName: 'com.togetherly.love.SelfPhotoWidgetProvider',
            widgetType: 'photo_day_self',
            expandedContent: _buildPhotoDayExpandedContent(),
            isExpanded: _photoDayExpanded,
            onToggleExpand: () =>
                setState(() => _photoDayExpanded = !_photoDayExpanded),
          ),
          const SizedBox(height: 16),

          // ── 4б. Фото партнёра ──
          if (isPaired) ...[
            _buildGalleryItem(
              title: LocaleService.current.widgetModePartner,
              subtitle: LocaleService.current.photoDayPartnerSubtitle,
              svgString: _photoSvg,
              qualifiedName: 'com.togetherly.love.PartnerPhotoWidgetProvider',
              widgetType: 'photo_day_partner',
              expandedContent: _buildPartnerPhotoExpandedContent(),
              isExpanded: _partnerPhotoExpanded,
              onToggleExpand: () => setState(
                () => _partnerPhotoExpanded = !_partnerPhotoExpanded,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ],

        // ── Настроение на экране блокировки + Фото-сетка ──
        if (isPaired) ...[
          _buildLockScreenMoodCard(),
          const SizedBox(height: 16),

          // ── 5в. Фото-сетка ──
          _buildGalleryItem(
            title: LocaleService.current.photoGridWidget,
            subtitle: LocaleService.current.photoGridWidgetSubtitle,
            svgString: _photoSvg,
            qualifiedName: 'com.togetherly.love.PhotoGridWidgetProvider',
            preview: _buildPhotoGridPreview(),
            widgetType: 'photo_grid',
            expandedContent: _buildPhotoGridExpandedContent(),
            isExpanded: _photoGridExpanded,
            onToggleExpand: () =>
                setState(() => _photoGridExpanded = !_photoGridExpanded),
          ),
          const SizedBox(height: 16),

          // ── Баннер 2 ──
          _buildAdBanner('ad_banner_2'),
        ],
      ],
    );
  }

  // ── Бенто: сетка простых виджетов по два в ряд ──
  Widget _halfGrid(List<Widget> tiles) {
    if (tiles.isEmpty) return const SizedBox.shrink();
    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i += 2) {
      if (i + 1 < tiles.length) {
        rows.add(IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: tiles[i]),
              const SizedBox(width: 12),
              Expanded(child: tiles[i + 1]),
            ],
          ),
        ));
      } else {
        rows.add(tiles[i]); // нечётный последний — во всю ширину
      }
      if (i + 2 < tiles.length) rows.add(const SizedBox(height: 12));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  /// Компактная плитка простого виджета: квадратное превью + имя + круглая
  /// кнопка «добавить на рабочий стол».
  Widget _buildHalfItem({
    required String title,
    required String qualifiedName,
    required String widgetType,
    required Widget preview,
    VoidCallback? onPreviewTap,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(26),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: onPreviewTap,
            behavior: HitTestBehavior.opaque,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(height: 128, child: preview),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Onest',
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.15,
              color: _cs.onSurface,
            ),
          ),
          if (_canPinWidgets) ...[
            const SizedBox(height: 9),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: FilledButton.icon(
                onPressed: () =>
                    _pinWidget(qualifiedName, widgetType: widgetType),
                icon: const Icon(Icons.add_to_home_screen_rounded, size: 17),
                label: const Text(
                  'Добавить',
                  style: TextStyle(
                    fontFamily: 'Onest',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _cs.primary,
                  foregroundColor: _cs.onPrimary,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openTimerSelectorSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _cs.surface,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          4,
          16,
          MediaQuery.of(ctx).viewInsets.bottom +
              MediaQuery.of(ctx).padding.bottom +
              24,
        ),
        child: SingleChildScrollView(child: _buildTimerSelector()),
      ),
    );
  }

  Widget _halfTileBg(List<Color> colors, Widget child) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
        ),
        child: Center(child: child),
      );

  Widget _streakCompact() => _halfTileBg(
        const [Color(0xFFFFB23E), Color(0xFFFF6A3D)],
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.local_fire_department_rounded,
                color: Colors.white, size: 40),
            Text(
              '${_mascotService.activeStreak}',
              style: const TextStyle(
                fontFamily: 'Unbounded',
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.05,
              ),
            ),
            Text(
              LocaleService.current.daysInARow,
              style: TextStyle(
                fontFamily: 'Onest',
                fontSize: 10,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      );

  Widget _timerCompact() => _halfTileBg(
        const [Color(0xFF7A5AD0), Color(0xFF9D6FF0)],
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.favorite_rounded, color: Colors.white, size: 34),
            SizedBox(height: 6),
            Text(
              'вместе',
              style: TextStyle(
                fontFamily: 'Onest',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      );

  Widget _buildAdBanner(String slot) {
    const realId = 'ca-app-pub-1956369312643059/2560361524';
    // Стабильный ключ: без него при каждом setState (раскрытие/сворачивание
    // карточек выше) Flutter может пересоздать элемент баннера и дёрнуть
    // новый loadAd — лишние запросы и риск спама в AdMob.
    return AdBanner(
      key: ValueKey(slot),
      adUnitId: kDebugMode ? '' : realId,
    );
  }

  Widget _buildGalleryItem({
    required String title,
    required String subtitle,
    required String svgString,
    required String qualifiedName,
    Widget? preview,
    String? widgetType,
    Widget? expandedContent,
    bool isExpanded = false,
    VoidCallback? onToggleExpand,
  }) {
    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Заголовок ──
          GestureDetector(
            onTap: onToggleExpand,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _cs.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: SvgPicture.string(
                      svgString,
                      width: 22,
                      height: 22,
                      colorFilter: ColorFilter.mode(
                          _cs.onPrimaryContainer, BlendMode.srcIn),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontFamily: 'Unbounded',
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: _cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontFamily: 'Onest',
                          fontSize: 12.5,
                          color: _cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onToggleExpand != null)
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 250),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: _cs.onSurfaceVariant,
                      size: 24,
                    ),
                  ),
              ],
            ),
          ),
          if (preview != null) ...[const SizedBox(height: 14), preview],
          // ── Кнопка «Добавить на рабочий стол» ──
          if (_canPinWidgets) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton.icon(
                onPressed: () =>
                    _pinWidget(qualifiedName, widgetType: widgetType),
                icon: const Icon(Icons.add_to_home_screen_rounded, size: 18),
                label: Text(
                  LocaleService.current.addToHomeScreen,
                  style: const TextStyle(
                    fontFamily: 'Onest',
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _cs.primary,
                  foregroundColor: _cs.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ],
          // ── Раскрываемое содержимое ──
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOut,
            child: expandedContent != null && isExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 20),
                      Divider(color: _cs.outlineVariant, height: 1),
                      const SizedBox(height: 16),
                      expandedContent,
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ВИДЖЕТ-ПРЕВЬЮ: Счётчик дней
  // ════════════════════════════════════════════════════════════════════════════

  static const String _flameSvg =
      '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor"><path fill-rule="evenodd" d="M12.963 2.286a.75.75 0 0 0-1.071-.136 9.742 9.742 0 0 0-3.539 6.177 7.547 7.547 0 0 1-1.705-1.715.75.75 0 0 0-1.152-.082A9 9 0 1 0 15.68 4.534a7.46 7.46 0 0 1-2.717-2.248ZM15.75 14.25a3.75 3.75 0 1 1-7.313-1.172c.628.465 1.35.81 2.133 1a5.99 5.99 0 0 1 1.925-3.547 3.75 3.75 0 0 1 3.255 3.719Z" clip-rule="evenodd" /></svg>''';

  /// Иллюстративный превью виджета «Огонёк пары».
  Widget _buildStreakPreview() {
    return Container(
      width: double.infinity,
      height: 200,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFB23E), Color(0xFFFF6A3D), Color(0xFFF9417B)],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('🔥', style: TextStyle(fontSize: 76)),
            const SizedBox(width: 18),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  LocaleService.current.streakTogetherCaps,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 1.4,
                  ),
                ),
                Text(
                  '${_mascotService.activeStreak}',
                  style: const TextStyle(
                    fontSize: 64,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1.05,
                  ),
                ),
                Text(
                  LocaleService.current.daysInARow,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  LocaleService.current.keepItUp,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDaysCounterPreview() {
    final s = LocaleService.current;
    // Берём тот же активный таймер, что и виджет на рабочем столе
    final timer = _widgetTimer ?? _timerService.systemTimer;
    final start = timer?.startDate ?? _pair.startDate;
    final totalDays = timer != null
        ? timer.daysElapsed.abs()
        : (start != null ? DateTime.now().difference(start).inDays : 0);
    final startLabel = start != null
        ? '${start.day.toString().padLeft(2, '0')}.${start.month.toString().padLeft(2, '0')}.${start.year}'
        : '';

    final myGender = widget.userData.gender?.name ?? '';
    final partnerGender = _ws.firstPartnerData?.gender.isNotEmpty == true
        ? _ws.firstPartnerData!.gender
        : '';

    String imgName = 'widget_couple_mf';
    bool flipCouple = false;
    if (myGender == 'female' && partnerGender == 'female') {
      imgName = 'widget_couple_ff';
    } else if (myGender == 'male' && partnerGender == 'male') {
      imgName = 'widget_couple_mm';
    } else if (myGender == 'female' && partnerGender == 'male') {
      // User (female) on left → mirror the mf image horizontally
      flipCouple = true;
    }

    final years = totalDays ~/ 365;
    final yearsText = s.yearsAlready(years);

    final myAvatar = widget.userData.avatarUrl;
    final partnerAvatar = _pair.partnerAvatarUrl;
    final showPhotos =
        _daysPhotosEnabled && myAvatar.isNotEmpty && partnerAvatar.isNotEmpty;

    return Container(
      width: double.infinity,
      height: 200,
      decoration: BoxDecoration(
        color: _t.cardSurface,
        border: Border.all(color: _t.primary.withOpacity(0.15), width: 3),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Stack(
        children: [
          if (showPhotos)
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _daysPreviewAvatar(myAvatar),
                    Transform.translate(
                      offset: const Offset(-10, 0),
                      child: _daysPreviewAvatar(partnerAvatar),
                    ),
                  ],
                ),
              ),
            )
          else
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(21),
                ),
                child: Transform.scale(
                  scaleX: flipCouple ? -1.0 : 1.0,
                  child: Image.asset(
                    'assets/images/widget/$imgName.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                yearsText,
                style: GoogleFonts.rubik(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _t.primary.withOpacity(0.7),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$totalDays',
                  style: GoogleFonts.rubik(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: _t.primary,
                    height: 1.0,
                  ),
                ),
                Text(
                  LocaleService.current.daysCounterLabel,
                  style: GoogleFonts.rubik(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: _t.primary.withOpacity(0.8),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  startLabel,
                  style: GoogleFonts.rubik(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _t.primary.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Кружок-аватарка для превью счётчика дней.
  Widget _daysPreviewAvatar(String url) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _t.primary.withOpacity(0.1),
        border: Border.all(color: _t.cardSurface, width: 2),
      ),
      child: ClipOval(
        child: StorageImage(
          imageUrl: url,
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) =>
              Icon(Icons.person_rounded, color: _t.primary.withOpacity(0.5)),
        ),
      ),
    );
  }

  /// Карточка настройки «Наши фото на виджете Дни вместе» (за коины).
  Widget _buildDaysPhotosCard() {
    final ud = widget.userData;
    final owned = ud.ownsFeature(UserData.featureDaysWidgetPhotos);
    final hasMyPhoto = ud.avatarUrl.isNotEmpty;
    final hasPartnerPhoto = _pair.partnerAvatarUrl.isNotEmpty;
    final bothPhotos = hasMyPhoto && hasPartnerPhoto;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _t.primary.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.face_retouching_natural_rounded, color: _t.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  LocaleService.current.ourPhotosInsteadOfDrawing,
                  style: GoogleFonts.rubik(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _t.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            LocaleService.current.daysPhotosDescription,
            style: GoogleFonts.rubik(
              fontSize: 12,
              color: _t.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          if (!owned)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _daysPhotosBusy ? null : _buyDaysPhotos,
                icon: _daysPhotosBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.lock_open_rounded, size: 18),
                label: Text(
                  LocaleService.current.unlockForCoins(_daysPhotosPrice),
                ),
              ),
            )
          else ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _daysPhotosEnabled,
              onChanged:
                  (_daysPhotosBusy || !bothPhotos) ? null : _setDaysPhotos,
              title: Text(
                LocaleService.current.showOurPhotos,
                style: GoogleFonts.rubik(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _t.textPrimary,
                ),
              ),
            ),
            if (!bothPhotos)
              Text(
                hasMyPhoto
                    ? LocaleService.current.partnerNoProfilePhoto
                    : LocaleService.current.addYourProfilePhoto,
                style: GoogleFonts.rubik(fontSize: 11, color: Colors.red.shade400),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _buyDaysPhotos() async {
    final ud = widget.userData;
    if (_daysPhotosBusy || ud.ownsFeature(UserData.featureDaysWidgetPhotos)) {
      return;
    }
    if (ud.coins < _daysPhotosPrice) {
      _showDaysPhotosSnack(
        LocaleService.current.notEnoughCoinsNeed(_daysPhotosPrice),
      );
      return;
    }
    setState(() => _daysPhotosBusy = true);
    final ok = await ud.purchaseFeature(UserData.featureDaysWidgetPhotos);
    if (!mounted) return;
    setState(() => _daysPhotosBusy = false);
    if (ok) {
      await _setDaysPhotos(true); // сразу включаем после покупки
      if (mounted) _showDaysPhotosSnack(LocaleService.current.daysPhotosDone);
    } else {
      _showDaysPhotosSnack(LocaleService.current.purchaseFailedTryLater);
    }
  }

  Future<void> _setDaysPhotos(bool enabled) async {
    setState(() {
      _daysPhotosEnabled = enabled;
      _daysPhotosBusy = true;
    });
    await HomeWidgetService.instance.setDaysCounterPhotos(
      groupId: _pair.pairId,
      enabled: enabled,
      myAvatarUrl: widget.userData.avatarUrl,
      partnerAvatarUrl: _pair.partnerAvatarUrl,
    );
    if (!mounted) return;
    setState(() => _daysPhotosBusy = false);
  }

  void _showDaysPhotosSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ВИДЖЕТ-ПРЕВЬЮ: Таймер
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildTimerPreview() {
    final timer = _widgetTimer;

    if (timer == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        decoration: BoxDecoration(
          color: _t.primary.withOpacity(0.04),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _t.primary.withOpacity(0.08)),
        ),
        child: Column(
          children: [
            Icon(Icons.timer_off_rounded, size: 36, color: _t.textMuted),
            const SizedBox(height: 8),
            Text(
              LocaleService.current.noTimersWidget,
              style: GoogleFonts.rubik(fontSize: 13, color: _t.textMuted),
            ),
            const SizedBox(height: 4),
            Text(
              LocaleService.current.addTimerHint,
              style: GoogleFonts.rubik(fontSize: 11, color: _t.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final days = timer.daysElapsed.abs();
    final isCountdown = timer.isCountdown;
    final daysLabel = isCountdown
        ? LocaleService.current.daysLeft
        : LocaleService.current.daysElapsed;
    final date = timer.formattedStartDate;
    final isRomantic = _pair.relationshipType == RelationshipType.couple ||
        _pair.relationshipType == RelationshipType.married;

    final bgColors = isRomantic
        ? [const Color(0xFFFDF2F8), const Color(0xFFEDE9FE)]
        : [const Color(0xFFFFFBF0), const Color(0xFFFEF3C7)];
    final borderColor = isRomantic
        ? const Color(0xFFEDD5EA)
        : const Color(0xFFE8D5A3);
    final numberColor = isRomantic
        ? const Color(0xFFB5488A)
        : const Color(0xFFC2760A);
    final titleColor = isRomantic
        ? const Color(0xFFC084B8)
        : const Color(0xFF9C7A3A);
    final labelColor = isRomantic
        ? const Color(0xFF9B7AA8)
        : const Color(0xFFA8936A);
    final dateColor = isRomantic
        ? const Color(0xFFC4A8D4)
        : const Color(0xFFC4B080);
    final iconColor = isRomantic
        ? const Color(0xFFD4609A)
        : const Color(0xFFE8A020);
    final decoColor = isRomantic
        ? const Color(0xFFD4609A)
        : const Color(0xFFE8A020);

    return Container(
      width: double.infinity,
      height: 116,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: bgColors,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: borderColor),
      ),
      child: Stack(
        children: [
          // Декоративная иконка справа (полупрозрачная)
          Positioned(
            right: 8,
            top: 0,
            bottom: 0,
            child: Opacity(
              opacity: 0.12,
              child: Icon(
                isRomantic ? Icons.favorite_rounded : Icons.star_rounded,
                size: 90,
                color: decoColor,
              ),
            ),
          ),
          // Контент слева
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 100, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Иконка + заголовок
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isRomantic ? Icons.favorite_rounded : Icons.star_rounded,
                      size: 12,
                      color: iconColor,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        timer.title,
                        style: GoogleFonts.rubik(
                          fontSize: 10,
                          color: titleColor,
                          letterSpacing: 0.4,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                // Большое число
                Text(
                  '$days',
                  style: GoogleFonts.rubik(
                    fontSize: 42,
                    fontWeight: FontWeight.w900,
                    color: numberColor,
                    height: 1.05,
                    letterSpacing: -0.5,
                  ),
                ),
                // Подпись
                Text(
                  daysLabel,
                  style: GoogleFonts.rubik(fontSize: 11, color: labelColor),
                ),
                if (date.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    date,
                    style: GoogleFonts.rubik(
                      fontSize: 9,
                      color: dateColor,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ВИДЖЕТ-ПРЕВЬЮ: Лепестковый таймер
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildPetalTimerPreview() {
    final timer = _widgetTimer;

    if (timer == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        decoration: BoxDecoration(
          color: _t.primary.withOpacity(0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _t.primary.withOpacity(0.08)),
        ),
        child: Column(
          children: [
            Icon(
              Icons.timer_off_rounded,
              size: 36,
              color: _t.textMuted,
            ),
            const SizedBox(height: 8),
            Text(
              LocaleService.current.noTimersWidget,
              style: GoogleFonts.rubik(
                fontSize: 13,
                color: _t.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    return Center(
      child: RepaintBoundary(
        child: SizedBox(
          width: 200,
          height: 200,
          child: PetalTimerDial(
            theme: _t,
            startDate: timer.startDate,
            isCountdown: timer.isCountdown,
          ),
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ВЫБОР ТАЙМЕРА ДЛЯ ВИДЖЕТА
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildTimerSelector() {
    final timers = _timerService.timers;

    if (timers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          LocaleService.current.noTimersAddHint,
          style: GoogleFonts.rubik(fontSize: 12, color: _t.textMuted),
        ),
      );
    }

    final defaultId = (_widgetTimer ?? timers.first).id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          LocaleService.current.selectTimerForWidget,
          style: GoogleFonts.rubik(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: _t.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        ...timers.map((timer) {
          final isSelected = timer.id == (_widgetTimerId ?? defaultId);
          return GestureDetector(
            onTap: () => _selectWidgetTimer(timer),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF8B5CF6).withOpacity(0.1)
                    : _t.surfaceMuted,
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFF8B5CF6)
                      : _t.divider,
                  width: isSelected ? 1.5 : 1,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Text(timer.emoji, style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          timer.title,
                          style: GoogleFonts.rubik(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isSelected
                                ? _t.primary
                                : _t.primary.withOpacity(0.8),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${timer.daysElapsed.abs()} '
                          '${timer.isCountdown ? LocaleService.current.daysShortLeft : LocaleService.current.daysShortElapsed} • ${timer.formattedStartDate}',
                          style: GoogleFonts.rubik(
                            fontSize: 11,
                            color: _t.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isSelected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 20,
                      color: const Color(0xFF8B5CF6),
                    ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ВИДЖЕТ-ПРЕВЬЮ: Фото дня
  // ════════════════════════════════════════════════════════════════════════════

  // ════════════════════════════════════════════════════════════════════════════
  // НАСТРОЙКИ ФОТО ДНЯ
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildPhotoDayExpandedContent() {
    final s = LocaleService.current;
    final hasWidgets = _personalWidgetIds.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _t.primary.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _t.primary.withOpacity(0.18)),
          ),
          child: Row(
            children: [
              Icon(Icons.photo_library_rounded, size: 18, color: _t.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _pair.partnerName.isNotEmpty
                      ? LocaleService.current
                          .personalPhotosHelp(_pair.partnerName)
                      : LocaleService.current.personalPhotosHelpShort,
                  style: GoogleFonts.rubik(
                    fontSize: 11,
                    color: _t.textSecondary,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          s.widgetInstances,
          style: GoogleFonts.rubik(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: _t.primary.withOpacity(0.8),
          ),
        ),
        const SizedBox(height: 10),
        _buildPhotoDayWidgetSelector(
          ids: _personalWidgetIds,
          selectedId: _selectedPersonalWidgetId,
          isPartner: false,
        ),
        if (hasWidgets) ...[
          const SizedBox(height: 12),
          _buildGlassCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.saveToMemoryLane,
                        style: GoogleFonts.rubik(
                          fontSize: 12,
                          color: _t.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        LocaleService.current.uploadedPhotosToMemoryLane,
                        style: GoogleFonts.rubik(
                          fontSize: 11,
                          color: _t.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _savePhotoAsMemory,
                  activeColor: _t.primary,
                  onChanged: _toggleSavePhotoAsMemory,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPartnerPhotoExpandedContent() {
    final partnerName = _pair.partnerName.isNotEmpty
        ? _pair.partnerName
        : LocaleService.current.partnerFallback;
    final partnerSharedCount =
        _ws.firstPartnerData?.photoForPartnerUrls.length ??
        ((_ws.firstPartnerData?.photoForPartnerUrl?.isNotEmpty ?? false)
            ? 1
            : 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _t.primary.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _t.primary.withOpacity(0.18)),
          ),
          child: Row(
            children: [
              Icon(Icons.favorite_rounded, size: 18, color: _t.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  partnerSharedCount > 0
                      ? LocaleService.current.partnerSharesPhotosHelp(
                          partnerName, partnerSharedCount)
                      : LocaleService.current
                          .partnerNotSharedHelp(partnerName),
                  style: GoogleFonts.rubik(
                    fontSize: 11,
                    color: _t.textSecondary,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_t.primary.withOpacity(0.92), _t.primary],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: _t.primary.withOpacity(0.18),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ElevatedButton.icon(
              onPressed: _showPhotoForPartnerSourcePicker,
              icon: const Icon(Icons.favorite_rounded, size: 18),
              label: Text(
                LocaleService.current.selectPhotosForPartner,
                style: GoogleFonts.rubik(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          LocaleService.current.widgetInstances,
          style: GoogleFonts.rubik(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: _t.primary.withOpacity(0.8),
          ),
        ),
        const SizedBox(height: 10),
        _buildPhotoDayWidgetSelector(
          ids: _partnerWidgetIds,
          selectedId: _selectedPartnerWidgetId,
          isPartner: true,
        ),
      ],
    );
  }


  Widget _buildPhotoDayWidgetSelector({
    required List<int> ids,
    int? selectedId,
    required bool isPartner,
  }) {
    final s = LocaleService.current;
    if (ids.isEmpty) {
      return _buildGlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.widgetNotAddedYet,
              style: GoogleFonts.rubik(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _t.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              s.addedWidgetsWillAppearHere,
              style: GoogleFonts.rubik(
                fontSize: 12,
                color: _t.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: ids.asMap().entries.map((entry) {
        final index = entry.key;
        final widgetId = entry.value;
        final isSelected = widgetId == selectedId;
        final widgetName = _photoDayWidgetNames[widgetId]?.trim();
        final ownPhotoPath = _photoDayWidgetOwnPhotoPaths[widgetId];

        // Счёт фото в виджете
        final int photoCount = isPartner
            ? (_ws.firstPartnerData?.photoForPartnerUrls.length ??
                  ((_ws.firstPartnerData?.photoForPartnerUrl?.isNotEmpty ?? false)
                      ? 1
                      : 0))
            : (_photoDayWidgetUrls[widgetId]?.length ?? 0);

        final rotationType = _photoDayWidgetRotationType[widgetId] ?? 'unlock';
        final rotationInterval =
            _photoDayWidgetRotationInterval[widgetId] ?? 60;
        final hasCarousel = photoCount >= 2;
        final String summary = photoCount == 0
            ? (isPartner
                  ? LocaleService.current.noPhotosFromPartner
                  : LocaleService.current.noPhotosAdded)
            : !hasCarousel
            ? LocaleService.current.onePhotoNoCarousel
            : rotationType == 'unlock'
            ? LocaleService.current.photoCountOnUnlock(photoCount)
            : LocaleService.current.photoCountInterval(
                photoCount, _intervalLabel(rotationInterval));

        VoidCallback onTapThumb = isPartner
            ? () => _showPartnerWidgetRotationEditor(widgetId)
            : () => _showPhotoDayPhotoSourcePicker(widgetId);

        return GestureDetector(
          onTap: () => _selectPhotoDayWidget(widgetId),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: isSelected
                  ? _t.primary.withOpacity(0.08)
                  : _t.surfaceMuted,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected ? _t.primary : _t.divider,
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: onTapThumb,
                  child: Stack(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: _t.surfaceMuted,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isSelected
                                ? _t.primary.withOpacity(0.35)
                                : _t.divider,
                            width: isSelected ? 1.5 : 1,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ownPhotoPath != null && ownPhotoPath.isNotEmpty
                            ? (ownPhotoPath.startsWith('http') || ownPhotoPath.startsWith('gs://') || ownPhotoPath.startsWith('sb://') || ownPhotoPath.startsWith('pb://')
                                  ? StorageImage(
                                      imageUrl: ownPhotoPath,
                                      fit: BoxFit.cover,
                                      memCacheWidth: 160,
                                      memCacheHeight: 160,
                                      errorWidget: (_, __, ___) => Icon(
                                        Icons.photo_camera_back_rounded,
                                        color: _t.textMuted,
                                        size: 20,
                                      ),
                                    )
                                  : Image.file(
                                      File(ownPhotoPath),
                                      fit: BoxFit.cover,
                                    ))
                            : Icon(
                                isPartner
                                    ? Icons.favorite_rounded
                                    : Icons.photo_camera_back_rounded,
                                color: _t.textMuted,
                                size: 20,
                              ),
                      ),
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: _t.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: Icon(
                            isPartner
                                ? Icons.access_time_rounded
                                : Icons.edit_rounded,
                            size: 10,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (photoCount > 1)
                        Positioned(
                          top: 2,
                          left: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$photoCount',
                              style: GoogleFonts.rubik(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widgetName?.isNotEmpty == true
                                  ? widgetName!
                                  : s.widgetSlotTitle(index),
                              style: GoogleFonts.rubik(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isSelected
                                    ? _t.primary
                                    : _t.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () =>
                                _showPhotoDayWidgetNameEditor(widgetId, index),
                            child: Icon(
                              Icons.edit_rounded,
                              size: 16,
                              color: isSelected
                                  ? _t.primary
                                  : _t.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        summary,
                        style: GoogleFonts.rubik(
                          fontSize: 11,
                          color: _t.textMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Icon(Icons.check_circle_rounded, size: 20, color: _t.primary),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  String _intervalLabel(int minutes) =>
      LocaleService.current.intervalLabel(minutes);

  Future<void> _showPartnerWidgetRotationEditor(int widgetId) async {
    await _selectPhotoDayWidget(widgetId);
    if (!mounted) return;

    final hws = HomeWidgetService.instance;
    final partnerCount = _ws.firstPartnerData?.photoForPartnerUrls.length ?? 0;
    String rotationType = await hws.getPhotoDayWidgetRotationType(widgetId);
    int rotationInterval = await hws.getPhotoDayWidgetRotationInterval(
      widgetId,
    );

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            void update(VoidCallback fn) => setSheetState(fn);
            final canRotate = partnerCount >= 2;
            return Container(
              decoration: BoxDecoration(
                color: _t.cardSurface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).padding.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: _t.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    LocaleService.current.partnerPhotoTitle,
                    style: GoogleFonts.rubik(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: _t.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    canRotate
                        ? LocaleService.current
                            .partnerSharedCountHelp(partnerCount)
                        : partnerCount == 1
                        ? LocaleService.current.partnerSharedOnePhoto
                        : LocaleService.current.partnerNotSharedYet,
                    style: GoogleFonts.rubik(
                      fontSize: 12,
                      color: _t.textSecondary,
                    ),
                  ),
                  if (canRotate) ...[
                    const SizedBox(height: 20),
                    Text(
                      LocaleService.current.changePhotosLabel,
                      style: GoogleFonts.rubik(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _t.primary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _buildRotationRadio(
                            title: LocaleService.current.onUnlockOption,
                            value: 'unlock',
                            groupValue: rotationType,
                            onChanged: (v) =>
                                update(() => rotationType = v ?? 'unlock'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildRotationRadio(
                            title: LocaleService.current.byTimeOption,
                            value: 'time',
                            groupValue: rotationType,
                            onChanged: (v) =>
                                update(() => rotationType = v ?? 'time'),
                          ),
                        ),
                      ],
                    ),
                    if (rotationType == 'time') ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: _t.surfaceMuted,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: rotationInterval,
                            isExpanded: true,
                            items: [
                              DropdownMenuItem(
                                value: 15,
                                child: Text(LocaleService.current.every15Minutes),
                              ),
                              DropdownMenuItem(
                                value: 30,
                                child: Text(LocaleService.current.every30Minutes),
                              ),
                              DropdownMenuItem(
                                value: 60,
                                child: Text(LocaleService.current.everyHourOption),
                              ),
                              DropdownMenuItem(
                                value: 180,
                                child: Text(LocaleService.current.every3HoursOption),
                              ),
                            ],
                            onChanged: (v) {
                              if (v != null) {
                                update(() => rotationInterval = v);
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: () async {
                        await hws.setPhotoDayWidgetRotationType(
                          widgetId,
                          canRotate ? rotationType : 'none',
                        );
                        await hws.setPhotoDayWidgetRotationInterval(
                          widgetId,
                          rotationInterval,
                        );
                        await hws.refreshPhotoOfDay(
                          _pair.pairId,
                          widgetId: widgetId,
                        );
                        if (mounted) {
                          await _loadPhotoDayWidgets();
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _t.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        LocaleService.current.save,
                        style: GoogleFonts.rubik(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildRotationRadio({
    required String title,
    required String value,
    required String groupValue,
    required ValueChanged<String?> onChanged,
  }) {
    final isSelected = value == groupValue;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? _t.primary.withOpacity(0.1) : Colors.transparent,
          border: Border.all(
            color: isSelected ? _t.primary : _t.divider,
            width: isSelected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? _t.primary : _t.textMuted,
              size: 18,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                style: GoogleFonts.rubik(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected ? _t.primary : _t.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // КАРТОЧКА: Настроение на экране блокировки
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildLockScreenMoodCard() {
    final s = LocaleService.current;
    final today = DateTime.now();
    final myEntries = _moodService.myEntriesForDay(today);
    final myEntry = myEntries.isNotEmpty ? myEntries.first : null;
    final partnerUid = _pair.partners.isNotEmpty
        ? _pair.partners.first.uid
        : '';
    final partnerEntries = partnerUid.isNotEmpty
        ? _moodService.partnerEntriesForDay(partnerUid, today)
        : <MoodEntry>[];
    final partnerEntry = partnerEntries.isNotEmpty
        ? partnerEntries.first
        : null;
    final myName = _ws.myData?.displayName.isNotEmpty == true
        ? _ws.myData!.displayName
        : s.me;
    final partnerName = _pair.partnerName.isNotEmpty
        ? _pair.partnerName
        : s.partner;

    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Заголовок ──
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _t.primary.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.lock_clock_outlined,
                  size: 20,
                  color: _t.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.lockScreenMood,
                      style: GoogleFonts.rubik(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _t.textPrimary,
                      ),
                    ),
                    Text(
                      s.lockScreenMoodSubtitle,
                      style: GoogleFonts.rubik(
                        fontSize: 11,
                        color: _t.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              // Тумблер вкл/выкл
              Switch(
                value: _lockScreenMoodEnabled,
                onChanged: _toggleLockScreenMood,
                activeColor: _t.primary,
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── Превью: моё и партнёра ──
          AnimatedOpacity(
            opacity: _lockScreenMoodEnabled ? 1.0 : 0.4,
            duration: const Duration(milliseconds: 250),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _t.primary.withOpacity(0.05),
                    _t.primary.withOpacity(0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _t.primary.withOpacity(0.1)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _buildLockMoodHalf(
                      entry: myEntry,
                      name: myName,
                      isLeft: true,
                      noMoodLabel: s.lockScreenMoodNoMood,
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 80,
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          _t.divider.withOpacity(0),
                          _t.divider,
                          _t.divider.withOpacity(0),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: _buildLockMoodHalf(
                      entry: partnerEntry,
                      name: partnerName,
                      isLeft: false,
                      noMoodLabel: s.lockScreenMoodNoMood,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Подсказка ──
          if (!_lockScreenMoodEnabled) ...[
            const SizedBox(height: 10),
            Text(
              s.lockScreenMoodToggleSub,
              style: GoogleFonts.rubik(
                fontSize: 11,
                color: _t.textMuted,
              ),
              textAlign: TextAlign.center,
            ),
          ] else if (myEntry == null) ...[
            const SizedBox(height: 10),
            Text(
              s.lockScreenMoodSetHint,
              style: GoogleFonts.rubik(
                fontSize: 11,
                color: _t.textMuted,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLockMoodHalf({
    required MoodEntry? entry,
    required String name,
    required bool isLeft,
    required String noMoodLabel,
  }) {
    return Column(
      crossAxisAlignment: isLeft
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.end,
      children: [
        Text(
          name,
          style: GoogleFonts.rubik(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: _t.textMuted,
            letterSpacing: 0.3,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        if (entry != null) ...[
          ClipOval(
            child: MoodImage(
              entry.imagePath,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            entry.localizedLabel,
            style: GoogleFonts.rubik(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _t.primary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ] else ...[
          const Text('😶', style: TextStyle(fontSize: 36)),
          const SizedBox(height: 4),
          Text(
            noMoodLabel,
            style: GoogleFonts.rubik(fontSize: 12, color: _t.textMuted),
          ),
        ],
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ВИДЖЕТ-ПРЕВЬЮ: Настроение
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildMoodPreview() {
    final s = LocaleService.current;
    final today = DateTime.now();

    final myEntries = _moodService.myEntriesForDay(today);
    final partnerUid = _pair.partners.isNotEmpty
        ? _pair.partners.first.uid
        : '';
    final partnerEntries = partnerUid.isNotEmpty
        ? _moodService.partnerEntriesForDay(partnerUid, today)
        : <MoodEntry>[];

    final myName = _ws.myData?.displayName.isNotEmpty == true
        ? _ws.myData!.displayName
        : s.me;
    final partnerName = _pair.partnerName.isNotEmpty
        ? _pair.partnerName
        : s.partner;

    return MoodHeartsPreview(
      myEntries: myEntries,
      partnerEntries: partnerEntries,
      myName: myName,
      partnerName: partnerName,
      primaryColor: _t.primary,
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ВИДЖЕТ-ПРЕВЬЮ: Статистика отношений
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildRelationshipStatsPreview() {
    final s = LocaleService.current;
    final sysTimer = _timerService.systemTimer;
    final start = sysTimer?.startDate ?? _pair.startDate;
    final daysNum = start != null ? DateTime.now().difference(start).inDays : 0;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _t.cardSurface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _t.cardBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildSmallStatBox(
                  icon: Icons.calendar_today_rounded,
                  color: _t.iconCalendar,
                  value: '$daysNum',
                  label: s.daysTogetherStat,
                  bg: _t.iconCalendar.withOpacity(0.08),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildSmallStatBox(
                  icon: Icons.photo_library_rounded,
                  color: _t.iconPost,
                  value: '${_memoriesCount ?? 0}',
                  label: s.memoriesStat,
                  bg: _t.iconPost.withOpacity(0.08),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildSmallStatBox(
                  icon: Icons.brush_rounded,
                  color: _t.iconDraw,
                  value: '${_drawingsCount ?? 0}',
                  label: s.drawingsStat,
                  bg: _t.iconDraw.withOpacity(0.08),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildSmallStatBox(
                  icon: Icons.favorite_rounded,
                  color: _t.primary,
                  value: '${_missYouCount ?? 0}',
                  label: s.missYousStat,
                  bg: _t.primary.withOpacity(0.08),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSmallStatBox({
    required IconData icon,
    required Color color,
    required String value,
    required String label,
    required Color bg,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _t.cardSurface,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: GoogleFonts.rubik(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: _t.textPrimary,
            ),
          ),
          Text(
            label,
            style: GoogleFonts.rubik(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: _t.textMuted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PAIR WIDGET — раскрытые настройки
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildPairWidgetExpandedContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMyTile(),
        const SizedBox(height: 12),
        _buildPartnerTile(),
        const SizedBox(height: 12),
        _buildSettingsSection(),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // MY TILE (editable)
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildMyTile() {
    final data = _ws.myData ?? WidgetData(uid: '');

    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Title ──
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_t.primary, _t.primary.withOpacity(0.7)],
                  ),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _s.myWidget,
                    style: GoogleFonts.rubik(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: _t.textPrimary,
                    ),
                  ),
                  Text(
                    _s.tapToEdit,
                    style: GoogleFonts.rubik(
                      fontSize: 11,
                      color: _t.textMuted,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              _buildEditBadge(),
            ],
          ),
          const SizedBox(height: 16),

          // ── Слоты ──
          _buildSlotRow(
            icon: Icons.emoji_emotions_outlined,
            iconColor: _t.iconMood,
            label: _s.mood,
            value: data.hasMood ? data.localizedMoodLabel : null,
            valueColor: Colors.white,
            trailing: data.hasMood
                ? ClipOval(child: Image.asset(data.moodEmoji, width: 24, height: 24, fit: BoxFit.cover))
                : null,
            onTap: () => _showMoodPicker(),
            onClear: data.hasMood
                ? () async {
                    // Единая точка очистки — атомарно во всех источниках.
                    await _moodService.clearMoodForToday();
                  }
                : null,
          ),
          _slotDivider(),
          _buildSlotRow(
            icon: Icons.chat_bubble_outline_rounded,
            iconColor: _t.primary,
            label: _s.status,
            value: data.hasStatus ? data.status : null,
            onTap: () => _showTextEditor(
              title: _s.status,
              hint: _s.statusHint,
              initial: data.status,
              maxLength: 50,
              onSave: (v) => _ws.updateStatus(v),
            ),
            onClear: data.hasStatus ? () => _ws.clearStatus() : null,
          ),
          _slotDivider(),
          _buildSlotRow(
            icon: Icons.mail_outline_rounded,
            iconColor: _t.primary,
            label: _s.message,
            value: data.hasMessage ? '«${data.message}»' : null,
            onTap: () => _showTextEditor(
              title: _s.message,
              hint: _s.messageHint,
              initial: data.message,
              maxLength: 200,
              onSave: (v) => _ws.updateMessage(v),
            ),
            onClear: data.hasMessage ? () => _ws.clearMessage() : null,
          ),
          _slotDivider(),
          _buildSlotRow(
            icon: Icons.photo_camera_outlined,
            iconColor: _t.iconPost,
            label: _s.photo,
            value: data.hasPhoto ? _s.photoUploaded : null,
            trailing: data.hasPhoto
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: StorageImage(
                      imageUrl: data.photoUrl!,
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                      progressIndicatorBuilder:
                          (context, url, downloadProgress) {
                            return Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: _t.surfaceMuted,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _t.primary,
                                    value: downloadProgress.progress,
                                  ),
                                ),
                              ),
                            );
                          },
                      errorWidget: (context, url, error) => Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _t.surfaceMuted,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.broken_image_rounded,
                          size: 18,
                          color: _t.textMuted,
                        ),
                      ),
                    ),
                  )
                : null,
            onTap: () => _pickPhoto(),
            onClear: data.hasPhoto ? () => _ws.clearPhoto() : null,
          ),
          _slotDivider(),
          _buildSlotRow(
            icon: Icons.music_note_rounded,
            iconColor: _t.iconCalendar,
            label: _s.music,
            value: data.hasMusic
                ? '${data.musicTitle} — ${data.musicArtist}'
                : null,
            onTap: () => _showMusicEditor(data),
            onClear: data.hasMusic ? () => _ws.clearMusic() : null,
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PARTNER TILE (read-only)
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildPartnerTile() {
    final partner = _ws.firstPartnerData ?? WidgetData(uid: '');
    final partnerName = _pair.partnerName.isNotEmpty
        ? _pair.partnerName
        : _s.partner;

    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Title ──
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _t.surfaceMuted,
                  shape: BoxShape.circle,
                ),
                // pb://-аватар partner'а теперь protected → только через
                // StorageImage (резолвит file-токен). Сырой NetworkImage давал
                // 403 после миграции на PocketBase.
                child: _pair.partnerAvatarUrl.isNotEmpty
                    ? ClipOval(
                        child: StorageImage(
                          imageUrl: _pair.partnerAvatarUrl,
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Icon(
                            Icons.person_rounded,
                            color: _t.textMuted,
                            size: 22,
                          ),
                        ),
                      )
                    : Icon(
                        Icons.person_rounded,
                        color: _t.textMuted,
                        size: 22,
                      ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _s.widgetOfPartner(partnerName),
                    style: GoogleFonts.rubik(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: _t.textPrimary,
                    ),
                  ),
                  Text(
                    partner.isEmpty ? _s.emptyYet : _s.updated,
                    style: GoogleFonts.rubik(
                      fontSize: 11,
                      color: _t.textMuted,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              if (!partner.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.green.shade400,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Live',
                        style: GoogleFonts.rubik(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.green.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Слоты (read-only) ──
          _buildReadonlySlot(
            icon: Icons.emoji_emotions_outlined,
            iconColor: _t.iconMood,
            label: _s.mood,
            value: partner.hasMood ? partner.localizedMoodLabel : null,
            valueColor: Colors.white,
            trailing: partner.hasMood
                ? ClipOval(child: Image.asset(partner.moodEmoji, width: 24, height: 24, fit: BoxFit.cover))
                : null,
          ),
          _slotDivider(),
          _buildReadonlySlot(
            icon: Icons.chat_bubble_outline_rounded,
            iconColor: _t.primary,
            label: _s.status,
            value: partner.hasStatus ? partner.status : null,
          ),
          _slotDivider(),
          _buildReadonlySlot(
            icon: Icons.mail_outline_rounded,
            iconColor: _t.primary,
            label: _s.message,
            value: partner.hasMessage ? '«${partner.message}»' : null,
          ),
          _slotDivider(),
          _buildReadonlySlot(
            icon: Icons.photo_camera_outlined,
            iconColor: _t.iconPost,
            label: _s.photo,
            value: partner.hasPhoto ? _s.photo : null,
            trailing: partner.hasPhoto
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: StorageImage(
                      imageUrl: partner.photoUrl!,
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                      progressIndicatorBuilder:
                          (context, url, downloadProgress) {
                            return Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: _t.surfaceMuted,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _t.primary,
                                    value: downloadProgress.progress,
                                  ),
                                ),
                              ),
                            );
                          },
                      errorWidget: (context, url, error) => Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _t.surfaceMuted,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.broken_image_rounded,
                          size: 18,
                          color: _t.textMuted,
                        ),
                      ),
                    ),
                  )
                : null,
          ),
          _slotDivider(),
          _buildReadonlySlot(
            icon: Icons.music_note_rounded,
            iconColor: _t.iconCalendar,
            label: _s.music,
            value: partner.hasMusic
                ? '${partner.musicTitle} — ${partner.musicArtist}'
                : null,
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // SETTINGS SECTION
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildSettingsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              Icon(Icons.tune_rounded, size: 16, color: _t.textMuted),
              const SizedBox(width: 6),
              Text(
                _s.widgetSettings,
                style: GoogleFonts.rubik(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _t.textSecondary,
                ),
              ),
            ],
          ),
        ),
        _buildGlassCard(
          child: Column(
            children: [
              _buildSettingToggle(
                icon: Icons.photo_library_outlined,
                iconColor: _t.iconPost,
                title: _s.photoToMemoryLane,
                subtitle: _s.autoSavePhotoToMemories,
                value: _ws.autoSendPhotoToMemory,
                onChanged: (v) => _ws.setAutoSendPhotoToMemory(v),
              ),
              _settingDivider(),
              _buildSettingToggle(
                icon: Icons.chat_outlined,
                iconColor: _t.primary,
                title: _s.messagestoMemoryLane,
                subtitle: _s.autoSaveMessages,
                value: _ws.autoSendMessageToMemory,
                onChanged: (v) => _ws.setAutoSendMessageToMemory(v),
              ),
              _settingDivider(),
              _buildSettingToggle(
                icon: Icons.music_note_outlined,
                iconColor: _t.iconCalendar,
                title: _s.musicToMemoryLane,
                subtitle: _s.autoSaveTracks,
                value: _ws.autoSendMusicToMemory,
                onChanged: (v) => _ws.setAutoSendMusicToMemory(v),
              ),
              _settingDivider(),
              _buildSettingToggle(
                icon: Icons.calendar_month_outlined,
                iconColor: _t.iconMood,
                title: _s.moodToCalendar,
                subtitle: _s.autoMarkMoodCalendar,
                value: _ws.autoSendMoodToCalendar,
                onChanged: (v) => _ws.setAutoSendMoodToCalendar(v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // SLOT ROWS
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildSlotRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    String? value,
    Color? valueColor,
    Widget? trailing,
    String? subtitle,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    final hasValue = value != null;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 22, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.rubik(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _t.textMuted,
                      letterSpacing: 0.3,
                    ),
                  ),
                  if (hasValue) ...[
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: GoogleFonts.rubik(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: valueColor ?? _t.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: GoogleFonts.rubik(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: _t.textMuted,
                        height: 1.25,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
            if (onClear != null) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onClear,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: _t.surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: _t.textMuted,
                  ),
                ),
              ),
            ],
            if (!hasValue) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: _t.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, size: 14, color: _t.primary),
                    const SizedBox(width: 2),
                    Text(
                      _s.addBtn,
                      style: GoogleFonts.rubik(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _t.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReadonlySlot({
    required IconData icon,
    required Color iconColor,
    required String label,
    String? value,
    Color? valueColor,
    Widget? trailing,
  }) {
    final hasValue = value != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 22, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.rubik(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _t.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
                if (hasValue) ...[
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: GoogleFonts.rubik(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: valueColor ?? _t.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
          if (!hasValue)
            Text(
              '—',
              style: TextStyle(fontSize: 14, color: _t.textMuted),
            ),
        ],
      ),
    );
  }

  Widget _buildSettingToggle({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.rubik(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _t.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.rubik(
                    fontSize: 11,
                    color: _t.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 28,
            child: Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeColor: _t.primary,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ФОТО-СЕТКА
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildPhotoGridPreview() {
    return AspectRatio(
      aspectRatio: 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: _t.primary.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _t.primary.withOpacity(0.1)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: _buildPhotoGridMockup(),
        ),
      ),
    );
  }

  Widget _buildPhotoGridMockup() {
    // Превью показывает фото ПАРТНЁРА (то, что отображается на рабочем столе)
    final partnerUrls = _ws.firstPartnerData?.photoGridUrls ?? [];
    final partnerCount = _ws.firstPartnerData?.photoGridCount ?? 1;
    final slots = partnerUrls.isNotEmpty ? partnerCount : _photoGridCount;

    Widget cell(int index) {
      if (index < partnerUrls.length && partnerUrls[index].isNotEmpty) {
        return StorageImage(
          imageUrl: partnerUrls[index],
          fit: BoxFit.cover,
          placeholder: (_, __) => _photoGridPlaceholder('⏳'),
          errorWidget: (_, __, ___) => _photoGridPlaceholder('📷'),
        );
      }
      return _photoGridPlaceholder('📷');
    }

    if (slots == 1) return cell(0);
    if (slots == 2) {
      return Row(
        children: [
          Expanded(child: cell(0)),
          const SizedBox(width: 2),
          Expanded(child: cell(1)),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: cell(0)),
              const SizedBox(width: 2),
              Expanded(child: cell(1)),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Row(
            children: [
              Expanded(child: cell(2)),
              const SizedBox(width: 2),
              Expanded(child: cell(3)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _photoGridPlaceholder(String emoji) {
    return Container(
      color: _t.primary.withOpacity(0.07),
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 24))),
    );
  }

  Widget _buildPhotoGridExpandedContent() {
    final s = LocaleService.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Выбор количества фото
        Text(
          s.photoGridCount,
          style: GoogleFonts.rubik(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: _t.primary.withOpacity(0.8),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [1, 2, 4].map((count) {
            final selected = _photoGridCount == count;
            final label = count == 1
                ? '1 ${s.photoGridCountLabel}'
                : count == 2
                ? '2 ${s.photoGridCountLabel}'
                : '4 ${s.photoGridCountLabel}';
            return GestureDetector(
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _photoGridCount = count;
                    // Обрезаем список если нужно
                    if (_photoGridPaths.length > count) {
                      _photoGridPaths = _photoGridPaths.sublist(0, count);
                    }
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? _t.primary.withOpacity(0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? _t.primary : _t.cardBorder,
                      width: selected ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    label,
                    style: GoogleFonts.rubik(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? _t.primary : _t.textMuted,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),

        // Ячейки фото
        Text(
          s.photoGridSelectPhotos,
          style: GoogleFonts.rubik(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: _t.primary.withOpacity(0.8),
          ),
        ),
        const SizedBox(height: 10),
        _buildPhotoGridSlots(),
        const SizedBox(height: 16),

        // Кнопка «Обновить виджет»
        if (_isLoadingPhotoGrid)
          const Center(child: CircularProgressIndicator())
        else
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _photoGridPaths.isNotEmpty ? _syncPhotoGrid : null,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text(LocaleService.current.photoGridSelectPhotos),
              style: ElevatedButton.styleFrom(
                backgroundColor: _t.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPhotoGridSlots() {
    final s = LocaleService.current;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _photoGridCount == 1 ? 1 : 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: _photoGridCount,
      itemBuilder: (context, index) {
        final hasPhoto =
            index < _photoGridPaths.length && _photoGridPaths[index].isNotEmpty;
        return GestureDetector(
          onTap: () => _pickPhotoGridSlot(index),
          child: Container(
            decoration: BoxDecoration(
              color: _t.primary.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hasPhoto ? _t.primary.withOpacity(0.3) : _t.cardBorder,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: hasPhoto
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          File(_photoGridPaths[index]),
                          fit: BoxFit.cover,
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                final paths = List<String>.from(
                                  _photoGridPaths,
                                );
                                paths[index] = '';
                                _photoGridPaths = paths;
                              });
                            },
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_photo_alternate_rounded,
                          size: 28,
                          color: _t.primary.withOpacity(0.4),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          s.photoGridAddPhoto,
                          style: GoogleFonts.rubik(
                            fontSize: 10,
                            color: _t.primary.withOpacity(0.4),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickPhotoGridSlot(int index) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PhotoSourceSheet(theme: _t),
    );
    if (source == null) return;

    final picker = ImagePicker();
    final picked = await safePick(
      () => picker.pickImage(source: source, imageQuality: 85),
    );
    if (picked == null || !mounted) return;

    setState(() {
      final paths = List<String>.from(_photoGridPaths);
      while (paths.length <= index) {
        paths.add('');
      }
      paths[index] = picked.path;
      _photoGridPaths = paths;
    });
  }

  Future<void> _syncPhotoGrid() async {
    if (_isLoadingPhotoGrid) return;
    setState(() => _isLoadingPhotoGrid = true);
    try {
      final fb = MediaService();
      final uid = PocketBaseService().userId ?? '';
      final groupId = _pair.pairId;

      // 1. Загружаем каждое выбранное фото в Firebase Storage
      final List<String> uploadedUrls = [];
      for (int i = 0; i < _photoGridPaths.length; i++) {
        final path = _photoGridPaths[i];
        if (path.isEmpty) continue;
        final ts = DateTime.now().millisecondsSinceEpoch;
        final dest = 'widget/$groupId/${uid}_grid_${i}_$ts.jpg';
        final url = await fb.uploadFile(path, dest);
        if (url != null) uploadedUrls.add(url);
      }

      // 2. Сохраняем МОИ настройки в Firestore (партнёр увидит эти фото)
      await _ws.updatePhotoGrid(_photoGridCount, uploadedUrls);

      // 3. Обновляем виджет рабочего стола (показывает фото ПАРТНЁРА,
      //    т.е. для нас самих здесь ничего не изменится, но инициализируем)
      await HomeWidgetService.instance.refreshPhotoGrid(groupId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.widgetAddedToHome),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('_syncPhotoGrid failed: $e');
    } finally {
      if (mounted) setState(() => _isLoadingPhotoGrid = false);
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // HELPERS / BUILDERS
  // ════════════════════════════════════════════════════════════════════════════

  // ════════════════════════════════════════════════════════════════════════════
  // POSTCARD BANNER
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildPostcardBanner() {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PostcardEditorScreen(
            userData: widget.userData,
            pairData: _pair,
            theme: _t,
            timerStartDate: _widgetTimer?.startDate,
          ),
          settings: const RouteSettings(name: '/postcard_editor'),
        ),
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: _cs.primaryContainer,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: _cs.onPrimaryContainer.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(17),
              ),
              child: Center(
                child: Icon(Icons.mail_rounded,
                    color: _cs.onPrimaryContainer, size: 26),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    LocaleService.current.createPostcardTitle,
                    style: TextStyle(
                      fontFamily: 'Unbounded',
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: _cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    LocaleService.current.createPostcardSubtitle,
                    style: TextStyle(
                      fontFamily: 'Onest',
                      fontSize: 12.5,
                      color: _cs.onPrimaryContainer.withValues(alpha: 0.82),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _cs.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_forward_ios_rounded,
                color: _cs.onPrimary,
                size: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlassCard({required Widget child}) {
    // M3 Expressive как на Подключении: тональный контейнер, крупный радиус,
    // плоско (без рамки и тени) — глубина передаётся тоном.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
      ),
      child: child,
    );
  }

  Widget _buildEditBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _t.primaryLight,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_rounded, size: 12, color: _t.primary),
          const SizedBox(width: 4),
          Text(
            _s.editBtn,
            style: GoogleFonts.rubik(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _t.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _slotDivider() =>
      Divider(color: _t.divider, height: 1, thickness: 1);

  Widget _settingDivider() =>
      Divider(color: _t.divider, height: 8, thickness: 1);

  // ════════════════════════════════════════════════════════════════════════════
  // NOT PAIRED PLACEHOLDER
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildNotPairedBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _t.cardSurface.withOpacity(0.82),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _t.primary.withOpacity(0.12)),
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: _t.primary.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.timer_rounded,
              size: 30,
              color: _t.primary.withOpacity(0.75),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            LocaleService.current.soloTimerBannerTitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.rubik(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _t.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            LocaleService.current.soloTimerBannerSubtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.rubik(
              fontSize: 13,
              color: _t.textMuted,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // DIALOGS / EDITORS
  // ════════════════════════════════════════════════════════════════════════════

  void _showMoodPicker() {
    // Единый общий пикер (с вкладкой «Самочувствие»). setMoodForToday внутри
    // него атомарно обновляет календарь, group memberMoods и widgetData.
    showMoodPicker(
      context: context,
      pairData: _pair,
      moodService: _moodService,
      widgetService: _ws,
      primary: _t.primary,
      navActiveIcon: _t.navActiveIcon,
    );
  }

  void _showTextEditor({
    required String title,
    required String hint,
    required String initial,
    required int maxLength,
    required ValueChanged<String> onSave,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _TextEditorSheet(
        theme: _t,
        title: title,
        hint: hint,
        initial: initial,
        maxLength: maxLength,
        onSave: (value) {
          onSave(value);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PhotoSourceSheet(theme: _t),
    );
    if (source == null || !mounted) return;

    final picker = ImagePicker();
    final file = await safePick(
      () => picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      ),
    );
    if (file == null || !mounted) return;

    // Соло-режим: партнёра/воспоминаний нет — старое поведение (только мой виджет).
    if (_pair.pairId.isEmpty) {
      _showPhotoLoader();
      await _ws.updatePhoto(file.path);
      if (mounted) Navigator.of(context).pop(); // закрываем лоадер
      return;
    }

    // Куда отправить фото — три независимых тумблера (запоминаются).
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final dest = await showModalBottomSheet<_PhotoDestinations>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PhotoDestinationSheet(
        theme: _t,
        partnerName: _pair.partnerName,
        initialToPairWidget:
            prefs.getBool('widget_sendPhotoToPairWidget') ?? true,
        initialToPartnerWidget:
            prefs.getBool('widget_sendPhotoToPartnerWidget') ?? true,
        initialToMemories: _ws.autoSendPhotoToMemory,
      ),
    );
    if (dest == null || !mounted) return;
    if (!dest.toPairWidget && !dest.toPartnerWidget && !dest.toMemories) return;

    // Запоминаем выбор для следующего раза.
    await prefs.setBool('widget_sendPhotoToPairWidget', dest.toPairWidget);
    await prefs.setBool(
      'widget_sendPhotoToPartnerWidget',
      dest.toPartnerWidget,
    );
    await _ws.setAutoSendPhotoToMemory(dest.toMemories);

    if (!mounted) return;
    _showPhotoLoader();

    // Один аплоад → раздаём по выбранным направлениям.
    final fb = MediaService();
    final uid = PocketBaseService().userId ?? '';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final url = await fb.uploadFile(
      file.path,
      'widget/${_pair.pairId}/${uid}_$ts.jpg',
    );

    var memoryFailed = false;
    if (url != null) {
      // 1. Парный виджет (моя половина + у партнёра как фолбэк).
      if (dest.toPairWidget) {
        await _ws.updatePhotoUrl(url);
      }
      // 2. Виджет «Фото партнёра» — то, что осознанно показываем партнёру.
      if (dest.toPartnerWidget) {
        await _ws.updatePhotoForPartnerUrl(url);
        await HomeWidgetService.instance.refreshPhotoOfDay(_pair.pairId);
        await _loadPhotoDayWidgets();
      }
      // 3. Лента воспоминаний.
      if (dest.toMemories) {
        try {
          final me = PbAuthService().currentProfile();
          final created = await MemoryRepository().add(
            groupId: _pair.pairId,
            authorName: (me?['displayName'] as String?) ?? '',
            authorAvatar: (me?['avatarUrl'] as String?) ?? '',
            type: MemoryType.photo,
            imageUrl: url,
            caption: LocaleService.current.widgetPhotoCaption,
          );
          // add() == null → тихий дроп (нет сессии/пустой groupId): фото ушло в
          // виджет, но не в ленту. Раньше это молча терялось — теперь фиксируем и
          // сообщаем пользователю, а не делаем вид, что всё сохранилось.
          if (created == null && mounted) {
            unawaited(Sentry.captureMessage(
              'Widget photo: memory add returned null (не добавилось в ленту)',
              withScope: (s) {
                s.level = SentryLevel.error;
                s.setExtra('isLoggedIn', PocketBaseService().isLoggedIn);
                s.setExtra('userIdNull', PocketBaseService().userId == null);
                s.setExtra('pairIdEmpty', _pair.pairId.isEmpty);
              },
            ));
            memoryFailed = true;
          }
        } catch (e) {
          debugPrint('Widget → Memory (photo) failed: $e');
          memoryFailed = true;
        }
      }
    }

    if (mounted) Navigator.of(context).pop(); // закрываем лоадер
    if (mounted && url == null) {
      // Загрузка не удалась (сеть/сессия). Раньше лоадер просто исчезал без
      // объяснений — теперь честно сообщаем, как на главном экране.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(LocaleService.current.failedUploadPhoto),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } else if (mounted && memoryFailed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(LocaleService.current.memoryNotSaved),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
  }

  void _showPhotoLoader() {
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
                M3LoadingDots(color: _t.primaryLight),
                const SizedBox(height: 16),
                Text(_s.uploadingPhoto, style: GoogleFonts.rubik(fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showMusicEditor(WidgetData data) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _MusicEditorSheet(
        theme: _t,
        initialTitle: data.musicTitle ?? '',
        initialArtist: data.musicArtist ?? '',
        initialUrl: data.musicUrl ?? '',
        initialCoverUrl: data.musicCoverUrl ?? '',
        onSave: ({
          required String title,
          required String artist,
          String? url,
          String? coverUrl,
        }) {
          _ws.updateMusic(
            title: title,
            artist: artist,
            url: url,
            coverUrl: coverUrl,
          );
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          _s.resetWidget,
          style: GoogleFonts.rubik(fontWeight: FontWeight.w700),
        ),
        content: Text(_s.resetWidgetConfirm, style: GoogleFonts.rubik()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              _s.cancel,
              style: TextStyle(color: _t.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_s.resetBtn, style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _ws.clearAll();
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MD3 PHOTO LOADER — анимация загрузки фото
// ══════════════════════════════════════════════════════════════════════════════

class _MD3PhotoLoader extends StatefulWidget {
  final Color color;
  const _MD3PhotoLoader({required this.color});

  @override
  State<_MD3PhotoLoader> createState() => _MD3PhotoLoaderState();
}

class _MD3PhotoLoaderState extends State<_MD3PhotoLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _pulse;
  late final Animation<double> _ring;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
    _ring = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOutSine);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Stack(
          alignment: Alignment.center,
          children: [
            // Внешнее пульсирующее кольцо
            Transform.scale(
              scale: 1.0 + _pulse.value * 0.12,
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(0.08 + _pulse.value * 0.07),
                ),
              ),
            ),
            // Среднее кольцо — чуть в противофазе
            Transform.scale(
              scale: 1.0 + (1 - _ring.value) * 0.08,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(0.06 + (1 - _ring.value) * 0.06),
                ),
              ),
            ),
            // MD3 индикатор загрузки
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                color: color,
                strokeWidth: 3.5,
                strokeCap: StrokeCap.round,
                backgroundColor: color.withOpacity(0.12),
              ),
            ),
            // Иконка фото в центре
            Opacity(
              opacity: 0.25 + _pulse.value * 0.35,
              child: Icon(Icons.image_rounded, size: 18, color: color),
            ),
          ],
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TEXT EDITOR SHEET
// ══════════════════════════════════════════════════════════════════════════════

class _TextEditorSheet extends StatefulWidget {
  final AppTheme theme;
  final String title;
  final String hint;
  final String initial;
  final int maxLength;
  final ValueChanged<String> onSave;

  const _TextEditorSheet({
    required this.theme,
    required this.title,
    required this.hint,
    required this.initial,
    required this.maxLength,
    required this.onSave,
  });

  @override
  State<_TextEditorSheet> createState() => _TextEditorSheetState();
}

class _TextEditorSheetState extends State<_TextEditorSheet> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: widget.theme.cardSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
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
              widget.title,
              style: GoogleFonts.rubik(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: widget.theme.textPrimary,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _ctrl,
              autofocus: true,
              maxLength: widget.maxLength,
              maxLines: widget.maxLength > 100 ? 3 : 1,
              style: GoogleFonts.rubik(fontSize: 16),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: GoogleFonts.rubik(color: widget.theme.textMuted),
                filled: true,
                fillColor: widget.theme.surfaceMuted,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: widget.theme.primary,
                    width: 1.5,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () => widget.onSave(_ctrl.text.trim()),
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.theme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  LocaleService.current.save,
                  style: GoogleFonts.rubik(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// PHOTO SOURCE SHEET
// ══════════════════════════════════════════════════════════════════════════════

class _PhotoSourceSheet extends StatelessWidget {
  final AppTheme theme;

  const _PhotoSourceSheet({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: theme.cardSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            LocaleService.current.chooseSource,
            style: GoogleFonts.rubik(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: theme.textPrimary,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _sourceButton(
                  context,
                  icon: Icons.camera_alt_rounded,
                  label: LocaleService.current.camera,
                  source: ImageSource.camera,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _sourceButton(
                  context,
                  icon: Icons.photo_library_rounded,
                  label: LocaleService.current.gallery,
                  source: ImageSource.gallery,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sourceButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required ImageSource source,
  }) {
    return GestureDetector(
      onTap: () => Navigator.pop(context, source),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: BoxDecoration(
          color: theme.primary.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.primary.withOpacity(0.15)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: theme.primary),
            const SizedBox(height: 8),
            Text(
              label,
              style: GoogleFonts.rubik(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// PHOTO DESTINATION SHEET — куда отправить фото из парного виджета
// ══════════════════════════════════════════════════════════════════════════════

/// Результат выбора направлений для загруженного фото.
class _PhotoDestinations {
  final bool toPairWidget;
  final bool toPartnerWidget;
  final bool toMemories;
  const _PhotoDestinations({
    required this.toPairWidget,
    required this.toPartnerWidget,
    required this.toMemories,
  });
}

class _PhotoDestinationSheet extends StatefulWidget {
  final AppTheme theme;
  final String partnerName;
  final bool initialToPairWidget;
  final bool initialToPartnerWidget;
  final bool initialToMemories;

  const _PhotoDestinationSheet({
    required this.theme,
    required this.partnerName,
    required this.initialToPairWidget,
    required this.initialToPartnerWidget,
    required this.initialToMemories,
  });

  @override
  State<_PhotoDestinationSheet> createState() => _PhotoDestinationSheetState();
}

class _PhotoDestinationSheetState extends State<_PhotoDestinationSheet> {
  late bool _toPairWidget = widget.initialToPairWidget;
  late bool _toPartnerWidget = widget.initialToPartnerWidget;
  late bool _toMemories = widget.initialToMemories;

  AppTheme get _t => widget.theme;

  @override
  Widget build(BuildContext context) {
    final partner = widget.partnerName.isNotEmpty
        ? widget.partnerName
        : LocaleService.current.partnerFallback;
    final nothingSelected =
        !_toPairWidget && !_toPartnerWidget && !_toMemories;

    return Container(
      decoration: BoxDecoration(
        color: _t.cardSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _t.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            LocaleService.current.whereToSendPhoto,
            style: GoogleFonts.rubik(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: _t.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          _destTile(
            icon: Icons.dashboard_customize_rounded,
            title: LocaleService.current.captionDestPairWidget,
            subtitle: LocaleService.current.captionDestPairWidgetSub(partner),
            value: _toPairWidget,
            onChanged: (v) => setState(() => _toPairWidget = v),
          ),
          _destTile(
            icon: Icons.favorite_rounded,
            title: LocaleService.current.captionDestPartnerWidget,
            subtitle: LocaleService.current.captionDestPartnerWidgetSub(partner),
            value: _toPartnerWidget,
            onChanged: (v) => setState(() => _toPartnerWidget = v),
          ),
          _destTile(
            icon: Icons.photo_album_rounded,
            title: LocaleService.current.captionDestMemories,
            subtitle: LocaleService.current.captionDestMemoriesSub,
            value: _toMemories,
            onChanged: (v) => setState(() => _toMemories = v),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: nothingSelected
                  ? null
                  : () => Navigator.pop(
                      context,
                      _PhotoDestinations(
                        toPairWidget: _toPairWidget,
                        toPartnerWidget: _toPartnerWidget,
                        toMemories: _toMemories,
                      ),
                    ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _t.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _t.surfaceMuted,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
              child: Text(
                LocaleService.current.sendLabel,
                style: GoogleFonts.rubik(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _destTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _t.primary.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: _t.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.rubik(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _t.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: GoogleFonts.rubik(
                    fontSize: 11.5,
                    color: _t.textMuted,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: value,
            activeColor: _t.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MUSIC EDITOR SHEET
// ══════════════════════════════════════════════════════════════════════════════

/// Supported music services for the info dialog
const List<Map<String, dynamic>> _musicServicesList = [
  {
    'name': 'Spotify',
    'supported': true,
    'color': Color(0xFF1DB954),
    'icon': Icons.music_note_rounded,
  },
  {
    'name': 'YouTube Music',
    'supported': true,
    'color': Color(0xFFFF0000),
    'icon': Icons.play_circle_rounded,
  },
  {
    'name': 'Apple Music',
    'supported': true,
    'color': Color(0xFFFC3C44),
    'icon': Icons.apple_rounded,
  },
  {
    'name': 'Deezer',
    'supported': true,
    'color': Color(0xFFA238FF),
    'icon': Icons.album_rounded,
  },
  {
    'name': 'SoundCloud',
    'supported': true,
    'color': Color(0xFFFF5500),
    'icon': Icons.cloud_rounded,
  },
  {
    'name': 'Yandex Music',
    'supported': true,
    'color': Color(0xFFFFCC00),
    'icon': Icons.library_music_rounded,
  },
  {
    'name': 'Tidal',
    'supported': true,
    'color': Color(0xFF000000),
    'icon': Icons.waves_rounded,
  },
  {
    'name': 'VK Music',
    'supported': true,
    'color': Color(0xFF0077FF),
    'icon': Icons.music_video_rounded,
  },
  {
    'name': 'YouTube',
    'supported': true,
    'color': Color(0xFFFF0000),
    'icon': Icons.smart_display_rounded,
  },
  {
    'name': 'Audio file',
    'supported': true,
    'color': Color(0xFF8B5CF6),
    'icon': Icons.audio_file_rounded,
  },
  {
    'name': 'Amazon Music',
    'supported': false,
    'color': Color(0xFF25D1DA),
    'icon': Icons.shopping_bag_rounded,
  },
  {
    'name': 'Pandora',
    'supported': false,
    'color': Color(0xFF005483),
    'icon': Icons.radio_rounded,
  },
];

class _MusicEditorSheet extends StatefulWidget {
  final AppTheme theme;
  final String initialTitle;
  final String initialArtist;
  final String initialUrl;
  final String initialCoverUrl;
  final void Function({
    required String title,
    required String artist,
    String? url,
    String? coverUrl,
  }) onSave;

  const _MusicEditorSheet({
    required this.theme,
    required this.initialTitle,
    required this.initialArtist,
    required this.initialUrl,
    required this.initialCoverUrl,
    required this.onSave,
  });

  @override
  State<_MusicEditorSheet> createState() => _MusicEditorSheetState();
}

class _MusicEditorSheetState extends State<_MusicEditorSheet> {
  late TextEditingController _titleCtrl;
  late TextEditingController _artistCtrl;
  late TextEditingController _urlCtrl;
  late FocusNode _urlFocus;

  bool _isFetching = false;
  String? _coverUrl;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle);
    _artistCtrl = TextEditingController(text: widget.initialArtist);
    _urlCtrl = TextEditingController(text: widget.initialUrl);
    _coverUrl = widget.initialCoverUrl.isNotEmpty ? widget.initialCoverUrl : null;

    _urlFocus = FocusNode();
    _urlFocus.addListener(() {
      if (!_urlFocus.hasFocus) _triggerFetch();
    });
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _urlCtrl.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  Future<void> _triggerFetch() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty || !url.startsWith('http')) return;
    if (!mounted) return;
    setState(() => _isFetching = true);
    final meta = await _fetchMusicMeta(url);
    if (!mounted) return;
    setState(() {
      _isFetching = false;
      if ((meta['title']?.isNotEmpty ?? false) && _titleCtrl.text.isEmpty) {
        _titleCtrl.text = meta['title']!;
      }
      if ((meta['artist']?.isNotEmpty ?? false) && _artistCtrl.text.isEmpty) {
        _artistCtrl.text = meta['artist']!;
      }
      if (meta['cover']?.isNotEmpty ?? false) {
        _coverUrl = meta['cover'];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final primary = widget.theme.primary;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: widget.theme.cardSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
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
            // ── Header with info button ──
            Row(
              children: [
                Expanded(
                  child: Text(
                    LocaleService.current.music,
                    style: GoogleFonts.rubik(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: widget.theme.textPrimary,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => _showServicesInfo(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: primary.withOpacity(0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 20,
                      color: primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ─── Link Section (first — paste link to auto-fill below) ───
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: widget.theme.surfaceMuted,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: widget.theme.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF22C55E).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.link_rounded,
                          size: 16,
                          color: Color(0xFF22C55E),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        LocaleService.current.streamingLink,
                        style: GoogleFonts.rubik(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: widget.theme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // URL field with fetch button
                  TextField(
                    controller: _urlCtrl,
                    focusNode: _urlFocus,
                    keyboardType: TextInputType.url,
                    style: GoogleFonts.rubik(fontSize: 15),
                    onSubmitted: (_) => _triggerFetch(),
                    decoration: InputDecoration(
                      hintText: LocaleService.current.pasteLinkFromService,
                      hintStyle: GoogleFonts.rubik(
                        color: widget.theme.textMuted,
                      ),
                      prefixIcon: Icon(
                        Icons.link_rounded,
                        color: primary,
                        size: 20,
                      ),
                      suffixIcon: _isFetching
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.grey,
                                ),
                              ),
                            )
                          : IconButton(
                              icon: Icon(
                                Icons.manage_search_rounded,
                                color: primary,
                              ),
                              tooltip: LocaleService.current.autoFetchSongInfo,
                              onPressed: _triggerFetch,
                            ),
                      filled: true,
                      fillColor: widget.theme.cardSurface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: primary,
                          width: 1.5,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ─── Song Details Section ───
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    primary.withOpacity(0.04),
                    const Color(0xFFEC4899).withOpacity(0.03),
                  ],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: primary.withOpacity(0.12)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Album cover preview
                      if (_coverUrl != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: StorageImage(
                              imageUrl: _coverUrl!,
                              width: 44,
                              height: 44,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: primary.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.music_note_rounded,
                                  size: 22,
                                  color: primary,
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: primary.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.music_note_rounded,
                              size: 16,
                              color: primary,
                            ),
                          ),
                        ),
                      Text(
                        LocaleService.current.songDetails,
                        style: GoogleFonts.rubik(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: widget.theme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _buildField(
                    _titleCtrl,
                    LocaleService.current.trackName,
                    Icons.audiotrack_rounded,
                  ),
                  const SizedBox(height: 10),
                  _buildField(
                    _artistCtrl,
                    LocaleService.current.artist,
                    Icons.person_rounded,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () {
                  final title = _titleCtrl.text.trim();
                  final artist = _artistCtrl.text.trim();
                  if (title.isEmpty || artist.isEmpty) return;
                  final url = _urlCtrl.text.trim();
                  widget.onSave(
                    title: title,
                    artist: artist,
                    url: url.isNotEmpty ? url : null,
                    coverUrl: _coverUrl,
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  LocaleService.current.save,
                  style: GoogleFonts.rubik(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Music metadata fetching (same logic as Memory Lane) ──

  String _decodeHtmlEntities(String text) => text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&nbsp;', ' ');

  Future<Map<String, String?>> _fetchMusicMeta(String url) async {
    final lower = url.toLowerCase();

    // YouTube / YouTube Music
    if (lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('music.youtube.com')) {
      try {
        final resp = await http.get(Uri.parse(
          'https://www.youtube.com/oembed?url=${Uri.encodeComponent(url)}&format=json',
        ));
        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          return {
            'title': data['title'] as String?,
            'artist': data['author_name'] as String?,
            'cover': data['thumbnail_url'] as String?,
          };
        }
      } catch (e) {
        debugPrint('YouTube meta fetch error: $e');
      }
      return {};
    }

    // Spotify
    if (lower.contains('spotify.com')) {
      try {
        final oembedResp = await http.get(
          Uri.parse('https://open.spotify.com/oembed?url=${Uri.encodeComponent(url)}'),
          headers: {'User-Agent': 'Mozilla/5.0'},
        );
        String? parsedTitle;
        String? parsedArtist;
        String? cover;
        if (oembedResp.statusCode == 200) {
          final data = json.decode(oembedResp.body) as Map<String, dynamic>;
          parsedTitle = data['title'] as String?;
          cover = data['thumbnail_url'] as String?;
        }
        try {
          final pageResp = await http.get(
            Uri.parse(url),
            headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'},
          );
          if (pageResp.statusCode == 200) {
            final titleMatch = RegExp(r'<title[^>]*>(.+?)</title>', caseSensitive: false)
                .firstMatch(pageResp.body);
            if (titleMatch != null) {
              final byMatch = RegExp(r'(?:song and lyrics|[Aa]lbum|single)\s+by\s+(.+?)\s*\|\s*Spotify')
                  .firstMatch(titleMatch.group(1) ?? '');
              if (byMatch != null) parsedArtist = byMatch.group(1)?.trim();
            }
          }
        } catch (_) {}
        return {'title': parsedTitle, 'artist': parsedArtist, 'cover': cover};
      } catch (e) {
        debugPrint('Spotify meta fetch error: $e');
      }
    }

    // Deezer
    final isDeezer = lower.contains('deezer.com') ||
        lower.contains('deezer.page.link') ||
        lower.contains('link.deezer.com');
    if (isDeezer) {
      try {
        String resolvedUrl = url;
        if (lower.contains('deezer.page.link') || lower.contains('link.deezer.com')) {
          try {
            String current = url;
            for (int i = 0; i < 5; i++) {
              final httpClient = HttpClient()
                ..connectionTimeout = const Duration(seconds: 6);
              final req = await httpClient.getUrl(Uri.parse(current));
              req.followRedirects = false;
              final resp = await req.close();
              final location = resp.headers.value('location');
              httpClient.close();
              if (location == null || location.isEmpty) break;
              current = location;
              if (current.toLowerCase().contains('deezer.com/') &&
                  current.toLowerCase().contains('/track/')) {
                resolvedUrl = current;
                break;
              }
              resolvedUrl = current;
            }
          } catch (_) {}
        }
        final trackMatch =
            RegExp(r'deezer\.com/(?:[^/?#]+/)*track/(\d+)').firstMatch(resolvedUrl.toLowerCase());
        if (trackMatch != null) {
          final apiResp = await http.get(
            Uri.parse('https://api.deezer.com/track/${trackMatch.group(1)}'),
            headers: {'Accept': 'application/json'},
          );
          if (apiResp.statusCode == 200) {
            final data = json.decode(apiResp.body) as Map<String, dynamic>;
            if (data['error'] == null) {
              return {
                'title': data['title'] as String?,
                'artist': (data['artist'] as Map<String, dynamic>?)?['name'] as String?,
                'cover': (data['album'] as Map<String, dynamic>?)?['cover_big'] as String?,
              };
            }
          }
        }
        final oembedResp = await http.get(
          Uri.parse('https://noembed.com/embed?url=${Uri.encodeComponent(resolvedUrl)}'),
        );
        if (oembedResp.statusCode == 200) {
          final data = json.decode(oembedResp.body) as Map<String, dynamic>;
          if (data['error'] == null && data['title'] != null) {
            return {
              'title': data['title'] as String?,
              'artist': data['author_name'] as String?,
              'cover': data['thumbnail_url'] as String?,
            };
          }
        }
      } catch (e) {
        debugPrint('Deezer meta fetch error: $e');
      }
    }

    // SoundCloud
    if (lower.contains('soundcloud.com')) {
      try {
        final oembedResp = await http.get(Uri.parse(
          'https://soundcloud.com/oembed?url=${Uri.encodeComponent(url)}&format=json',
        ));
        if (oembedResp.statusCode == 200) {
          final data = json.decode(oembedResp.body) as Map<String, dynamic>;
          return {
            'title': data['title'] as String?,
            'artist': data['author_name'] as String?,
            'cover': data['thumbnail_url'] as String?,
          };
        }
      } catch (e) {
        debugPrint('SoundCloud meta fetch error: $e');
      }
    }

    // Яндекс Музыка
    if (lower.contains('music.yandex.')) {
      try {
        final pageResp = await http.get(
          Uri.parse(url),
          headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'},
        );
        if (pageResp.statusCode == 200) {
          final titleMatch = RegExp(r'<title[^>]*>(.+?)</title>', caseSensitive: false)
              .firstMatch(pageResp.body);
          if (titleMatch != null) {
            final parts = (titleMatch.group(1) ?? '').split('—');
            if (parts.length >= 2) {
              return {
                'title': parts[0].trim(),
                'artist': parts[1].split(RegExp(r'слушать|listen')).first.trim(),
                'cover': null,
              };
            }
          }
        }
      } catch (e) {
        debugPrint('Yandex Music meta fetch error: $e');
      }
    }

    // Apple Music
    if (lower.contains('music.apple.com')) {
      try {
        final trackIdMatch = RegExp(r'[?&]i=(\d+)').firstMatch(url);
        final pathIdMatch = RegExp(r'/(\d+)(?:[?#/]|$)').allMatches(url).lastOrNull;
        final lookupId = trackIdMatch?.group(1) ?? pathIdMatch?.group(1);
        if (lookupId != null) {
          final resp = await http.get(Uri.parse(
            'https://itunes.apple.com/lookup?id=$lookupId&entity=song',
          ));
          if (resp.statusCode == 200) {
            final data = json.decode(resp.body) as Map<String, dynamic>;
            final results = data['results'] as List?;
            if (results != null && results.isNotEmpty) {
              final track = results.firstWhere(
                    (r) => r['wrapperType'] == 'track',
                    orElse: () => results.first,
                  ) as Map<String, dynamic>;
              return {
                'title': track['trackName'] as String?,
                'artist': track['artistName'] as String?,
                'cover': track['artworkUrl100'] as String?,
              };
            }
          }
        }
      } catch (e) {
        debugPrint('Apple Music meta fetch error: $e');
      }
    }

    // Tidal
    if (lower.contains('tidal.com')) {
      try {
        final pageResp = await http.get(
          Uri.parse(url),
          headers: {'User-Agent': 'Twitterbot/1.0'},
        );
        if (pageResp.statusCode == 200) {
          final ogTitleMatch = RegExp(
            r'property="og:title"\s+content="([^"]+)"',
            caseSensitive: false,
          ).firstMatch(pageResp.body);
          final ogImageMatch = RegExp(
            r'property="og:image"\s+content="([^"]+)"',
            caseSensitive: false,
          ).firstMatch(pageResp.body);
          if (ogTitleMatch != null) {
            final raw = _decodeHtmlEntities(ogTitleMatch.group(1) ?? '');
            final sepIdx = raw.indexOf(' - ');
            if (sepIdx != -1) {
              return {
                'title': raw.substring(sepIdx + 3).trim(),
                'artist': raw.substring(0, sepIdx).trim(),
                'cover': ogImageMatch?.group(1),
              };
            }
            return {'title': raw.isNotEmpty ? raw : null, 'artist': null, 'cover': ogImageMatch?.group(1)};
          }
        }
      } catch (e) {
        debugPrint('Tidal meta fetch error: $e');
      }
    }

    // Generic fallback via noembed.com
    try {
      final oembedResp = await http.get(
        Uri.parse('https://noembed.com/embed?url=${Uri.encodeComponent(url)}'),
      );
      if (oembedResp.statusCode == 200) {
        final data = json.decode(oembedResp.body) as Map<String, dynamic>;
        if (data['error'] == null) {
          return {
            'title': data['title'] as String?,
            'artist': data['author_name'] as String?,
            'cover': data['thumbnail_url'] as String?,
          };
        }
      }
    } catch (_) {}

    return {};
  }

  void _showServicesInfo(BuildContext context) {
    final primary = widget.theme.primary;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: widget.theme.cardSurface,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      primary.withOpacity(0.15),
                      const Color(0xFFEC4899).withOpacity(0.1),
                    ],
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.music_note_rounded, color: primary, size: 28),
              ),
              const SizedBox(height: 14),
              Text(
                'Supported Services',
                style: GoogleFonts.rubik(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: widget.theme.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Paste a link from any supported service',
                style: GoogleFonts.rubik(
                  fontSize: 12,
                  color: widget.theme.textMuted,
                ),
              ),
              const SizedBox(height: 18),
              ..._musicServicesList.map(
                (svc) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: (svc['color'] as Color).withOpacity(0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: (svc['color'] as Color).withOpacity(0.12),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          svc['icon'] as IconData,
                          size: 20,
                          color: svc['color'] as Color,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            svc['name'] as String,
                            style: GoogleFonts.rubik(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: widget.theme.textPrimary,
                            ),
                          ),
                        ),
                        Icon(
                          svc['supported'] == true
                              ? Icons.check_circle_rounded
                              : Icons.cancel_rounded,
                          size: 20,
                          color: svc['supported'] == true
                              ? const Color(0xFF22C55E)
                              : const Color(0xFFEF4444),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(
                    foregroundColor: primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Got it',
                    style: GoogleFonts.rubik(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(TextEditingController ctrl, String hint, IconData icon) {
    return TextField(
      controller: ctrl,
      style: GoogleFonts.rubik(fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.rubik(color: widget.theme.textMuted),
        prefixIcon: Icon(icon, color: widget.theme.primary, size: 20),
        filled: true,
        fillColor: widget.theme.surfaceMuted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: widget.theme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }
}
