import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import '../widgets/storage_image.dart';
import '../utils/safe_text.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_map/flutter_map.dart';
// show LatLng: latlong2 также экспортирует класс Path<LatLng>, который перекрывал
// dart:ui Path в пейнтерах волны (media_widgets — part of этой библиотеки).
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/safe_launch.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';
import 'package:exif/exif.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import '../models/memory.dart';
import '../models/comment.dart';
import '../models/pair_data.dart';
import '../models/user_data.dart';
import '../widgets/common/coin_reward_toast.dart';
import '../widgets/common/ad_banner.dart';
import '../services/pb_media_service.dart';
import '../services/offline/media_cache.dart';
import '../services/media_service.dart';
import '../services/memory_repository.dart';
import '../services/secret_pin_service.dart';
import '../services/capsule_notification_service.dart';
import '../widgets/sealed_capsule_card.dart';
import 'time_capsule_screen.dart';
import '../services/pocketbase_service.dart';
import 'together/together_launcher.dart';
import '../services/home_widget_service.dart';
import '../services/rate_limiter_service.dart';
import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_scope.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/common/m3_loading.dart';
import 'home/home_bottom_nav.dart';
import 'map_picker_screen.dart';
import 'memories_map_screen.dart';
import 'memory_photo_form_screen.dart';
import 'memory_music_form_screen.dart';
import 'memory_location_form_screen.dart';
import 'memory_book_form_screen.dart';
import 'memory_movie_form_screen.dart';
import '../widgets/memory_date_field.dart';
import '../widgets/rating_widgets.dart';
import '../services/movie_search_service.dart';

// Экран разбит на части (один большой файл → читаемые модули). Все части —
// `part of` этой библиотеки: приватные классы остаются библиотечно-приватными,
// импорты общие (объявлены здесь). См. memory_lane/*.dart.
part 'memory_lane/players.dart';
part 'memory_lane/detail.dart';
part 'memory_lane/gallery.dart';
part 'memory_lane/media_widgets.dart';

/// Returns SVG asset path for a given memory type
String _svgAssetForType(MemoryType type) {
  switch (type) {
    case MemoryType.photo:
      return 'assets/icons/ic_photo.svg';
    case MemoryType.video:
      return 'assets/icons/ic_photo.svg';
    case MemoryType.videoLink:
      return 'assets/icons/ic_photo.svg';
    case MemoryType.location:
      return 'assets/icons/ic_location.svg';
    case MemoryType.music:
      return 'assets/icons/ic_music_note.svg';
    case MemoryType.text:
      return 'assets/icons/ic_edit.svg';
    case MemoryType.book:
      return 'assets/icons/ic_book.svg';
    case MemoryType.movie:
      return 'assets/icons/ic_movie.svg';
  }
}

/// Filter mode for Memory Lane pinned memories.
enum MemoryFilterMode { none, day, month }

/// Memory Lane — Google Calendar Schedule-style view
/// Grouped by date, pinned at top, full CRUD
class MemoryLaneScreen extends StatefulWidget {
  final PairData pairData;
  final AppTheme theme;
  final MemoryFilterMode filterMode;
  final UserData? userData;
  /// Авто-открыть лист создания пина сразу после входа (для кнопки «+» в навбаре).
  final bool openCreateOnStart;

  /// Авто-открыть деталь конкретного пина после загрузки (переход из чата).
  final String? initialMemoryId;

  /// Тап по вкладке общего навбара внутри Ленты (Главная/Виджеты/Пара/Профиль).
  /// Главный экран закрывает Ленту и переключает свою вкладку. null → навбар
  /// в Ленте не показывается (например, при входе из чата/лепестка).
  final void Function(int index)? onNavTab;

  const MemoryLaneScreen({
    super.key,
    required this.pairData,
    required this.theme,
    this.filterMode = MemoryFilterMode.none,
    this.userData,
    this.openCreateOnStart = false,
    this.initialMemoryId,
    this.onNavTab,
  });

  @override
  State<MemoryLaneScreen> createState() => _MemoryLaneScreenState();
}

class _MemoryLaneScreenState extends State<MemoryLaneScreen> {
  Color get primary => widget.theme.primary;

  final MemoryRepository _memRepo = MemoryRepository();

  /// Текущий uid = PocketBase (auth уже на PB). Firebase-сессии под PB-входом
  /// нет, поэтому проверки «это моё воспоминание» берём отсюда, а не из _myUid.
  String? get _myUid => PocketBaseService().userId;

  /// Свой аватар — из локального профиля (UserData), самый свежий источник.
  String get _myAvatar => widget.userData?.avatarUrl ?? '';

  /// Live avatar for a memory author — falls back to the stored snapshot.
  String _liveAvatar(Memory memory) {
    // Current user: in-memory cache is always the freshest source.
    if (memory.authorUid == _myUid) {
      final cached = _myAvatar;
      if (cached.isNotEmpty) return cached;
    }
    for (final m in pair.members) {
      if (m.uid == memory.authorUid && m.avatar.isNotEmpty) return m.avatar;
    }
    return memory.authorAvatar;
  }

  /// Live display name for a memory author — falls back to the stored snapshot.
  String _liveName(Memory memory) {
    for (final m in pair.members) {
      if (m.uid == memory.authorUid && m.name.isNotEmpty) return m.name;
    }
    return memory.authorName;
  }
  List<Memory> _memories = [];
  bool _loading = true;
  // Ленивая пагинация ленты: рендерим окно из последних N воспоминаний и растим
  // его по мере прокрутки. Данные все в кэше — это окно ПО UI, не по сети.
  static const int _feedPageSize = 30;
  int _visibleLimit = _feedPageSize;
  final ScrollController _feedScroll = ScrollController();
  // Пагинация мертва: на PB чтения бесплатны → лента целиком live (см.
  // _subscribeMemories). Поля сохранены, чтобы не трогать UI «загрузить ещё»:
  // _loadedAll=true → блок подгрузки не рендерится, _loadingMore всегда false.
  final bool _loadingMore = false;
  bool _loadedAll = true;
  StreamSubscription<List<Memory>>? _memSub;
  bool _firstMemLoad = true;

  // ── Фильтр-теги ленты (этап 2 редизайна) ───────────────────────────────────
  // «Моменты» = фото+видео (общий бейдж «Момент»); остальные категории —
  // один-в-один к [_typeBadgeMeta]. null = «Всё». [_favoritesOnly] —
  // независимый круглый тег слева: показывает только личные закладки (savedBy).
  String? _categoryKey;
  bool _favoritesOnly = false;

  /// Секретные воспоминания раскрыты в этой сессии экрана (после ввода PIN).
  /// Сбрасывается при выходе с экрана — секреты снова прячутся.
  bool _secretUnlocked = false;

  static final List<
      ({String key, String ru, String en, IconData icon, Set<MemoryType> types})>
      _feedCategories = [
    (key: 'moments', ru: 'Моменты', en: 'Moments', icon: Icons.favorite_rounded, types: {MemoryType.photo, MemoryType.video}),
    (key: 'places', ru: 'Локации', en: 'Locations', icon: Icons.place_rounded, types: {MemoryType.location}),
    (key: 'music', ru: 'Музыка', en: 'Music', icon: Icons.music_note_rounded, types: {MemoryType.music}),
    (key: 'video', ru: 'Видео', en: 'Video', icon: Icons.play_circle_fill_rounded, types: {MemoryType.videoLink}),
    (key: 'notes', ru: 'Заметки', en: 'Notes', icon: Icons.sticky_note_2_rounded, types: {MemoryType.text}),
    (key: 'books', ru: 'Книги', en: 'Books', icon: Icons.menu_book_rounded, types: {MemoryType.book}),
    (key: 'movies', ru: 'Фильмы', en: 'Movies', icon: Icons.movie_rounded, types: {MemoryType.movie}),
  ];

  /// Категории, реально присутствующие в ленте (чтобы не показывать пустые теги).
  List<({String key, String ru, String en, IconData icon, Set<MemoryType> types})>
      get _presentCategories {
    final present = _memories.map((m) => m.type).toSet();
    return _feedCategories
        .where((c) => c.types.any(present.contains))
        .toList();
  }

  bool get _feedFiltered => _favoritesOnly || _categoryKey != null;

  /// Проходит ли воспоминание текущий тег-фильтр (категория + «Избранное»).
  bool _passesFeedFilter(Memory m) {
    // Секретные скрыты из ленты, пока не введён PIN (см. [_secretUnlocked]).
    if (m.isSecret && !_secretUnlocked) return false;
    if (_favoritesOnly && !m.isSavedBy(_myUid ?? '')) return false;
    if (_categoryKey == null) return true;
    final cat = _feedCategories.firstWhere((c) => c.key == _categoryKey,
        orElse: () => _feedCategories.first);
    return cat.types.contains(m.type);
  }

  bool get _hasVisibleMemories =>
      _pinnedMemories.isNotEmpty || _groupedByDate.isNotEmpty;

  // User location for distance display
  double? _userLat;
  double? _userLng;

  PairData get pair => widget.pairData;
  String get _groupId => pair.pairId;

  @override
  void initState() {
    super.initState();
    _subscribeMemories();
    _feedScroll.addListener(_onFeedScroll); // ленивая пагинация по скроллу
    _fetchUserLocation();
    widget.pairData.addListener(_onPairChanged);
    if (widget.openCreateOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAddMemorySheet();
      });
    }
  }

  /// Открыть деталь пина, на который сослались из чата.
  Future<void> _openInitialMemory() async {
    final id = widget.initialMemoryId;
    if (id == null || !mounted) return;
    Memory? target;
    for (final m in _memories) {
      if (m.id == id) {
        target = m;
        break;
      }
    }
    // Live-лента целиком (без лимитов), так что пин обычно уже в _memories.
    // На всякий случай — точечное чтение из PocketBase.
    if (target == null && _groupId.isNotEmpty) {
      target = await _memRepo.getById(id);
    }
    if (target != null && mounted) _showMemoryDetail(target);
  }

  void _onPairChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _tryClaimMemoryReward() async {
    final ud = widget.userData;
    if (ud == null || !mounted) return;
    final amount = await ud.claimMemoryReward();
    if (amount <= 0 || !mounted) return;
    CoinRewardToast.show(context, amount: amount, label: LocaleService.current.memoryRewardTitle);
  }

  /// Живая подписка на ленту воспоминаний (PocketBase SSE). Заменяет
  /// пагинацию/cache-first: на self-hosted PB чтения бесплатны → вся лента
  /// приезжает разом и обновляется в реальном времени (свои и партнёрские
  /// добавления/правки/удаления — без кнопок «обновить»/«загрузить ещё»).
  void _subscribeMemories() {
    if (_groupId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _memSub?.cancel();
    _memSub = _memRepo.watch(_groupId).listen(
      (memories) {
        if (!mounted) return;
        setState(() {
          _memories = memories;
          _loading = false;
        });
        if (_firstMemLoad) {
          _firstMemLoad = false;
          if (widget.initialMemoryId != null) _openInitialMemory();
        }
        // Планируем «капсула открылась» на дату каждой ещё запечатанной капсулы
        // (и у автора, и у партнёра — капсула прилетает через realtime). Сервис
        // идемпотентен по id, так что повторные апдейты ленты безопасны.
        for (final m in memories) {
          if (m.sealedNow() && m.openAt != null) {
            unawaited(CapsuleNotificationService.instance
                .schedule(m.id, m.openAt!, capsuleTitle: m.title));
          }
        }
      },
      onError: (e) {
        debugPrint('memory_lane: watch error: $e');
        if (mounted) setState(() => _loading = false);
      },
    );
  }

  /// Бесконечная прокрутка больше не нужна (вся лента live). Оставлено как no-op,
  /// чтобы не трогать обработчики скролла.
  Future<void> _loadNextPage() async {}

  /// Подрастить окно ленты (ленивая пагинация по скроллу).
  void _growWindow() {
    if (!_canShowMore) return;
    setState(() => _visibleLimit += _feedPageSize);
  }

  void _onFeedScroll() {
    if (!_feedScroll.hasClients || !_canShowMore) return;
    final pos = _feedScroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) _growWindow();
  }

  @override
  void dispose() {
    _memSub?.cancel();
    _feedScroll.dispose();
    widget.pairData.removeListener(_onPairChanged);
    super.dispose();
  }

  // ── Organize memories ──
  List<Memory> get _pinnedMemories {
    if (widget.filterMode != MemoryFilterMode.none) return [];
    return _memories
        .where((m) => m.isPinned && _passesFeedFilter(m))
        .toList();
  }

  /// Memories filtered by current day/month across all years, grouped by year
  Map<String, List<Memory>> get _filteredByDateAcrossYears {
    final now = DateTime.now();
    List<Memory> filtered;
    if (widget.filterMode == MemoryFilterMode.day) {
      filtered = _memories
          .where(
            (m) => m.createdAt.month == now.month && m.createdAt.day == now.day,
          )
          .toList();
    } else if (widget.filterMode == MemoryFilterMode.month) {
      filtered = _memories
          .where((m) => m.createdAt.month == now.month)
          .toList();
    } else {
      return {};
    }
    filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final Map<String, List<Memory>> grouped = {};
    for (var m in filtered) {
      final key = '${m.createdAt.year}';
      grouped.putIfAbsent(key, () => []).add(m);
    }
    return grouped;
  }

  /// Все непин-воспоминания, прошедшие фильтр, новые первыми (без окна).
  List<Memory> get _nonPinnedSortedAll {
    if (widget.filterMode != MemoryFilterMode.none) return const [];
    return _memories
        .where((m) => !m.isPinned && _passesFeedFilter(m))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Есть ли воспоминания за пределами текущего окна (для подгрузки по скроллу).
  bool get _canShowMore =>
      widget.filterMode == MemoryFilterMode.none &&
      _nonPinnedSortedAll.length > _visibleLimit;

  /// Group non-pinned memories by date, newest first — ОКНО (_visibleLimit).
  Map<String, List<Memory>> get _groupedByDate {
    if (widget.filterMode != MemoryFilterMode.none) return {};
    final Map<String, List<Memory>> grouped = {};
    for (final m in _nonPinnedSortedAll.take(_visibleLimit)) {
      grouped.putIfAbsent(_dateKey(m.createdAt), () => []).add(m);
    }
    return grouped;
  }

  String _dateKey(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(date).inDays;

    final s = LocaleService.current;
    if (diff == 0) return s.todayDate;
    if (diff == 1) return s.yesterday;
    if (diff < 7) return s.shortWeekdays[dt.weekday - 1];

    final months = s.shortMonths;
    if (dt.year == now.year) {
      return '${months[dt.month - 1]} ${dt.day}';
    }
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  // ── In-feed реклама ────────────────────────────────────────────────────────
  // Баннер вставляется после каждого N-го воспоминания в основной ленте
  // (нормальный режим, без фильтра и без закреплённых). N — баланс
  // «доход / не раздражает»: на первой странице (20) выходит ~3 баннера.
  // Меньше ставить рискованно — AdMob/Яндекс штрафуют за слишком плотную
  // рекламу (invalid traffic), да и ленту пары не хочется превращать в спам.
  static const int _adEveryNMemories = 6;

  // Боевой баннерный блок (тот же, что в widget_screen). В debug AdBanner сам
  // подставляет тестовый юнит при пустом adUnitId.
  static const String _bannerAdUnit = 'ca-app-pub-1956369312643059/2560361524';

  /// Секции ленты (заголовок даты + тайлы) с full-width баннером после каждого
  /// N-го воспоминания. Счётчик ГЛОБАЛЬНЫЙ — не сбрасывается между днями.
  /// Если N-е воспоминание попадает в середину дня, день режется на чанки,
  /// чтобы баннер встал ровно между тайлами, а не ломал тайл.
  List<Widget> _buildDateGroupedSlivers() {
    final slivers = <Widget>[];
    var sinceAd = 0; // воспоминаний с момента последнего баннера
    var adIndex = 0; // порядковый номер баннера (для стабильного ключа)
    for (final entry in _groupedByDate.entries) {
      slivers.add(_sectionHeader(entry.key));
      final mems = entry.value;
      var chunkStart = 0;
      for (var i = 0; i < mems.length; i++) {
        sinceAd++;
        final adHere = sinceAd >= _adEveryNMemories;
        if (adHere || i == mems.length - 1) {
          // Сбрасываем накопленный чанк тайлов (он остаётся внутри своей даты).
          slivers.add(_memoryTilesSliver(mems.sublist(chunkStart, i + 1)));
          chunkStart = i + 1;
          if (adHere) {
            slivers.add(_inFeedBannerSliver(adIndex++));
            sinceAd = 0;
          }
        }
      }
    }
    return slivers;
  }

  Widget _memoryTilesSliver(List<Memory> mems) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (_, i) => _memoryTile(mems[i]),
          childCount: mems.length,
        ),
      ),
    );
  }

  Widget _inFeedBannerSliver(int adIndex) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        // Стабильный ключ по порядковому номеру баннера: лента пересоздаётся на
        // setState (refresh / «загрузить ещё» / лайки), и без ключа баннер
        // дёргал бы новый loadAd при каждом ребилде — лишние запросы и спам в
        // сеть. С ключом инстанс баннера переживает ребилды.
        child: AdBanner(
          key: ValueKey('memlane_ad_$adIndex'),
          adUnitId: kDebugMode ? '' : _bannerAdUnit,
        ),
      ),
    );
  }

  String _fmtToday() {
    final n = DateTime.now();
    final m = LocaleService.current.shortMonths;
    return '${m[n.month - 1]} ${n.day}';
  }

  String _fmtMonth() {
    return LocaleService.current.fullMonths[DateTime.now().month];
  }

  String _timeStr(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // ══════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: widget.theme.bgGradient[0],
      body: Stack(
        children: [
          // -- Background --
          Positioned.fill(
            child: RepaintBoundary(
              child: widget.theme.bgImageUrl != null
                  ? StorageImage(
                      imageUrl: widget.theme.bgImageUrl!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      placeholder: (_, __) => DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: widget.theme.bgGradient,
                          ),
                        ),
                      ),
                      errorWidget: (_, __, ___) => DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: widget.theme.bgGradient,
                          ),
                        ),
                      ),
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: widget.theme.bgGradient,
                        ),
                      ),
                    ),
            ),
          ),
          CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            controller: _feedScroll,
              slivers: [
                _buildAppBar(),
                if (_loading)
                  SliverFillRemaining(child: M3PageLoading(color: widget.theme.primaryLight))
                else if (_memories.isEmpty)
                  _buildEmpty()
                else if (_feedFiltered && !_hasVisibleMemories) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 6)),
                  _buildFilteredEmpty(),
                ]
                else ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 6)),
                  // Pinned section (only in normal mode)
                  if (_pinnedMemories.isNotEmpty) ...[
                    _sectionHeader('📌  ${LocaleService.current.pinned}'),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (_, i) => _memoryTile(_pinnedMemories[i]),
                          childCount: _pinnedMemories.length,
                        ),
                      ),
                    ),
                  ],
                  // Day/Month filter — grouped by year across all years
                  if (widget.filterMode != MemoryFilterMode.none) ...[
                    if (_filteredByDateAcrossYears.isEmpty)
                      _buildEmpty()
                    else
                      ..._filteredByDateAcrossYears.entries.expand((entry) {
                        return [
                          _sectionHeader(entry.key),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            sliver: SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (_, i) => _memoryTile(entry.value[i]),
                                childCount: entry.value.length,
                              ),
                            ),
                          ),
                        ];
                      }),
                  ],
                  // Date-grouped sections (normal mode) с in-feed баннерами
                  // «1 на N воспоминаний» (см. _buildDateGroupedSlivers).
                  ..._buildDateGroupedSlivers(),
                  // Кнопка "Загрузить ещё"
                  if (!_loadedAll)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 8),
                        child: TextButton(
                          onPressed: _loadingMore ? null : _loadNextPage,
                          style: TextButton.styleFrom(
                            foregroundColor: primary,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          child: _loadingMore
                              ? SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: primary),
                                )
                              : Text(
                                  LocaleService.current.loadMore,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                        ),
                      ),
                    ),
                ],
                SliverToBoxAdapter(
                    child: SizedBox(
                        height: (widget.onNavTab != null ? 116 : 90) +
                            bottomPad)),
              ],
            ),
            // Нижняя зона: общий навбар (вход из главной) либо пилюля «Добавить»
            // (вход из чата/лепестка, где навбар не нужен).
            if (widget.onNavTab != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: HomeBottomNav(
                  // Лента — не одна из 4 вкладок: -1 = ни одна не подсвечена.
                  selectedIndex: -1,
                  theme: widget.theme,
                  isPaired: pair.isPaired,
                  onTap: (i) => widget.onNavTab!(i),
                  // В Ленте боковая кнопка всегда «+» (создать пин).
                  onCreatePin: _showAddMemorySheet,
                ),
              )
            else
              Positioned(
                bottom: bottomPad + 24,
                left: 24,
                right: 24,
                child: Center(
                  child: GestureDetector(
                    onTap: _showAddMemorySheet,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: primary,
                        borderRadius: BorderRadius.circular(50),
                        boxShadow: widget.theme.accentGlow(
                          primary,
                          opacity: 0.35,
                          blurRadius: 20,
                          offset: const Offset(0, 6),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.add_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            LocaleService.current.addMemoryBtn,
                            style: GoogleFonts.rubik(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  // ── App Bar ──
  SliverAppBar _buildAppBar() {
    return SliverAppBar(
      pinned: true,
      backgroundColor: widget.theme.bgGradient[0].withOpacity(0.95),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      bottom: _filterBar(),
      leading: IconButton(
        onPressed: () => Navigator.pop(context),
        icon: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: widget.theme.cardSurface.withOpacity(0.8),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.arrow_back_rounded,
            color: widget.theme.textPrimary,
            size: 20,
          ),
        ),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            LocaleService.current.memoryLane,
            style: GoogleFonts.rubik(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: widget.theme.textPrimary,
            ),
          ),
          if (widget.filterMode != MemoryFilterMode.none)
            Text(
              widget.filterMode == MemoryFilterMode.day
                  ? '📌 ${LocaleService.current.pinned} • ${_fmtToday()}'
                  : '📌 ${LocaleService.current.pinned} • ${_fmtMonth()}',
              style: GoogleFonts.rubik(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: primary.withOpacity(0.8),
              ),
            ),
        ],
      ),
      actions: [
        if (_memories.any((m) => m.isSecret))
          IconButton(
            onPressed: _toggleSecretLock,
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: widget.theme.cardSurface.withOpacity(0.8),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _secretUnlocked
                    ? Icons.lock_open_rounded
                    : Icons.lock_rounded,
                color: primary,
                size: 18,
              ),
            ),
            tooltip: LocaleService.current.secretMemories,
          ),
        IconButton(
          onPressed: _openPhotoGalleryScreen,
          icon: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: widget.theme.cardSurface.withOpacity(0.8),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.photo_library_rounded, color: primary, size: 18),
          ),
          tooltip: LocaleService.current.openPhotoGallery,
        ),
        IconButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MemoriesMapScreen(
                memories: _memories
                    .where((m) =>
                        !m.sealedNow() && !(m.isSecret && !_secretUnlocked))
                    .toList(),
                theme: widget.theme,
                currentUserUid: _myUid,
              ),
              settings: const RouteSettings(name: '/memories_map'),
            ),
          ),
          icon: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: widget.theme.cardSurface.withOpacity(0.8),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.map_rounded, color: primary, size: 18),
          ),
          tooltip: LocaleService.current.memoriesMapTooltip,
        ),
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.group_rounded, size: 14, color: primary),
                  const SizedBox(width: 4),
                  Text(
                    '${pair.members.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: primary,
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

  // ── Empty state ──
  SliverFillRemaining _buildEmpty() {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 56,
              color: widget.theme.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              LocaleService.current.noMemoriesYet,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: widget.theme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              LocaleService.current.noMemoriesYetDesc,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: widget.theme.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  FILTER BAR (тег-фильтры + «Избранное»)
  // ═══════════════════════════════════════════════════
  /// Горизонтальная лента тегов под заголовком. Показывается только в обычном
  /// режиме (не day/month) и когда есть что фильтровать (>1 категории или есть
  /// личные закладки). Плоские теги: без тени/свечения/бордера; выбранный —
  /// залит активным цветом темы. Слева — круглый тег «Избранное».
  PreferredSizeWidget? _filterBar() {
    if (widget.filterMode != MemoryFilterMode.none) return null;
    if (_loading || _memories.isEmpty) return null;
    final cats = _presentCategories;
    final hasFavorites = _memories.any((m) => m.isSavedBy(_myUid ?? ''));
    // Нечего фильтровать (один тип контента и ни одной закладки) — прячем бар.
    if (cats.length < 2 && !hasFavorites) return null;
    return PreferredSize(
      preferredSize: const Size.fromHeight(50),
      child: SizedBox(
        height: 50,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          children: [
            _favCircle(),
            const SizedBox(width: 8),
            _filterTag(
              label: _ru ? 'Всё' : 'All',
              selected: _categoryKey == null,
              onTap: () => setState(() => _categoryKey = null),
            ),
            for (final c in cats) ...[
              const SizedBox(width: 8),
              _filterTag(
                label: _ru ? c.ru : c.en,
                icon: c.icon,
                selected: _categoryKey == c.key,
                onTap: () => setState(() => _categoryKey = c.key),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Круглый тег-значок «Избранное» (слева от «Всё»). Активен — залит цветом
  /// темы с белым сердцем; иначе — приглушённый фон, контурное сердце.
  Widget _favCircle() {
    final selected = _favoritesOnly;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _favoritesOnly = !selected),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? primary : widget.theme.cardSurface,
          shape: BoxShape.circle,
        ),
        child: Icon(
          selected ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          size: 18,
          color: selected ? Colors.white : widget.theme.textSecondary,
        ),
      ),
    );
  }

  /// Плоский тег-фильтр. Выбранный залит активным цветом темы (белый текст);
  /// невыбранный — приглушённый фон. Без тени, свечения и бордера.
  Widget _filterTag({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    final fg = selected ? Colors.white : widget.theme.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? primary : widget.theme.cardSurface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Пустое состояние при активном фильтре (тег не дал результатов).
  SliverToBoxAdapter _buildFilteredEmpty() {
    final favEmpty = _favoritesOnly;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 70, 24, 24),
        child: Column(
          children: [
            Icon(
              favEmpty
                  ? Icons.favorite_border_rounded
                  : Icons.search_off_rounded,
              size: 52,
              color: primary.withOpacity(0.35),
            ),
            const SizedBox(height: 14),
            Text(
              favEmpty
                  ? (_ru ? 'Пока нет избранного' : 'No favorites yet')
                  : (_ru
                      ? 'Нет воспоминаний в этой категории'
                      : 'No memories in this category'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: widget.theme.textSecondary,
              ),
            ),
            if (favEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _ru
                    ? 'Отмечайте воспоминания закладкой — они появятся здесь'
                    : 'Bookmark memories to find them here',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: widget.theme.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  SECTION HEADER
  // ═══════════════════════════════════════════════════
  SliverToBoxAdapter _sectionHeader(String title) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        child: Text(
          title,
          style: GoogleFonts.rubik(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: widget.theme.textMuted,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  MEMORY TILE (type-specific cards)
  // ═══════════════════════════════════════════════════
  Widget _memoryTile(Memory memory) {
    // Капсула времени: до даты открытия — запечатанная карточка вместо контента.
    if (memory.sealedNow()) {
      return KeyedSubtree(
        key: ValueKey('capsule_${memory.id}'),
        child: SealedCapsuleCard(
          theme: widget.theme,
          authorName: memory.authorName,
          authorAvatar: memory.authorAvatar,
          openAt: memory.openAt!,
          onTapTooEarly: () => _secretSnack(
            LocaleService.current.capsuleNotReady(_fmtCapsuleDate(memory.openAt!)),
          ),
        ),
      );
    }
    final tile = switch (memory.type) {
      MemoryType.photo => _photoTile(memory),
      MemoryType.video => _videoTile(memory),
      MemoryType.videoLink => _videoLinkTile(memory),
      MemoryType.location => _locationTile(memory),
      MemoryType.music => _musicTile(memory),
      MemoryType.text => _textTile(memory),
      MemoryType.book => _bookTile(memory),
      MemoryType.movie => _movieTile(memory),
    };
    // Ключ по id КРИТИЧЕН: лента отсортирована «новые сверху», при добавлении
    // воспоминания индексы всех плиток сдвигаются. Без ключа
    // SliverChildBuilderDelegate переиспользует элементы ПО ПОЗИЦИИ → плитка
    // получает чужой memory/imageUrl и на миг показывает (StorageImage внутри
    // через FutureBuilder) фото ПРЕДЫДУЩЕГО воспоминания. Ключ привязывает
    // элемент к конкретной записи — переиспользования между разными нет.
    return KeyedSubtree(key: ValueKey('mem_${memory.id}'), child: tile);
  }

  // ═══════════════════════════════════════════════════
  //  Helper: SVG icon path per memory type
  // ═══════════════════════════════════════════════════
  String _typeSvgAsset(MemoryType type) => _svgAssetForType(type);

  // ═══════════════════════════════════════════════════
  //  SHARED CARD HEADER (avatar · name · time · subtitle)
  // ═══════════════════════════════════════════════════
  Widget _cardHeader(
    Memory memory, {
    String? subtitle,
    Widget? trailing,
    Color? badgeColor,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Row(
        children: [
          // Avatar with accent ring + optional badge dot
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: primary.withOpacity(0.18),
                    width: 1.5,
                  ),
                ),
                child: ClipOval(
                  child: _liveAvatar(memory).isNotEmpty
                      ? StorageImage(
                          imageUrl: _liveAvatar(memory),
                          fit: BoxFit.cover,
                          memCacheWidth: 120,
                          memCacheHeight: 120,
                          errorWidget: (_, __, ___) =>
                              _avatarFallback(_liveName(memory)),
                        )
                      : _avatarFallback(_liveName(memory)),
                ),
              ),
              if (badgeColor != null)
                Positioned(
                  bottom: -2,
                  left: -2,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: badgeColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Center(
                      child: SvgPicture.asset(
                        _typeSvgAsset(memory.type),
                        width: 10,
                        height: 10,
                        colorFilter: const ColorFilter.mode(
                          Colors.white,
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _liveName(memory),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: widget.theme.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '  ·  ${_formatTimeAgo(memory.createdAt)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.theme.textMuted,
                      ),
                    ),
                  ],
                ),
                if (subtitle != null && subtitle.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: widget.theme.textMuted),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing,
          if (memory.isPinned && trailing == null)
            Icon(
              Icons.push_pin_rounded,
              size: 16,
              color: primary.withOpacity(0.45),
            ),
        ],
      ),
    );
  }

  bool get _ru => LocaleService.instance.isRussian;

  /// Бейдж типа воспоминания (напр. «❤️ Момент») справа в шапке. Плоский —
  /// без теней/бордера (требование), лёгкая подложка цветом темы.
  Widget _typeBadge(Memory memory) {
    final meta = _typeBadgeMeta(memory.type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(meta.$2, size: 13, color: primary),
          const SizedBox(width: 5),
          Text(
            meta.$1,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: primary,
            ),
          ),
        ],
      ),
    );
  }

  (String, IconData) _typeBadgeMeta(MemoryType type) {
    switch (type) {
      case MemoryType.photo:
      case MemoryType.video:
        return (_ru ? 'Момент' : 'Moment', Icons.favorite_rounded);
      case MemoryType.location:
        return (_ru ? 'Локация' : 'Location', Icons.place_rounded);
      case MemoryType.music:
        return (_ru ? 'Музыка' : 'Music', Icons.music_note_rounded);
      case MemoryType.videoLink:
        return (_ru ? 'Видео' : 'Video', Icons.play_circle_fill_rounded);
      case MemoryType.text:
        return (_ru ? 'Заметка' : 'Note', Icons.sticky_note_2_rounded);
      case MemoryType.book:
        return (_ru ? 'Книга' : 'Book', Icons.menu_book_rounded);
      case MemoryType.movie:
        return (_ru ? 'Фильм' : 'Movie', Icons.movie_rounded);
    }
  }

  /// Открыть полноэкранную галерею по тапу на коллаж.
  void _openCollage(Memory memory) async {
    final items = _allGalleryItems;
    final idx = items.indexWhere((it) => it.memoryId == memory.id);
    final result =
        await _openFullscreenGallery(context, items, idx >= 0 ? idx : 0);
    if (result != null && mounted) {
      final mem = _memories.firstWhere(
        (m) => m.id == result,
        orElse: () => memory,
      );
      _showMemoryDetail(mem);
    }
  }

  /// Мозаика-коллаж медиа (фото 17): 1 — крупно, 2 — в ряд, 3 — 1+2, 4+ — два
  /// сверху и до 3 снизу, последняя ячейка с «+N», если фото больше.
  Widget _mediaCollage(Memory memory, List<String> photos, bool hasVideo) {
    const r = 14.0;
    const gap = 4.0;
    final n = photos.length;

    Widget tile(int i, {bool overlay = false, int remaining = 0}) {
      Widget cell = Stack(
        fit: StackFit.expand,
        children: [
          // Фото заполняет ячейку и ОБРЕЗАЕТСЯ по её форме (cover), без
          // искажения пропорций — как в системной галерее. Positioned.fill +
          // ClipRRect снаружи гарантируют жёсткие границы и кроп.
          Positioned.fill(
            child: StorageImage(
              imageUrl: photos[i],
              fit: BoxFit.cover,
              // ВАЖНО: задаём ТОЛЬКО ширину кэша. Если задать и width, и height,
              // Flutter декодирует фото точно в 500×500 (квадрат), ИГНОРИРУЯ
              // пропорции → вертикальное фото сжимается ещё ДО cover. С одной
              // лишь шириной пропорции сохраняются, и cover честно обрезает.
              memCacheWidth: 700,
              errorWidget: (_, __, ___) => Container(
                color: widget.theme.surfaceMuted,
                child: Icon(Icons.broken_image_rounded,
                    color: widget.theme.textMuted, size: 26),
              ),
            ),
          ),
          if (hasVideo && i == 0)
            const Center(
              child: Icon(Icons.play_circle_fill_rounded,
                  color: Colors.white, size: 42),
            ),
          if (overlay)
            Container(
              color: Colors.black.withOpacity(0.45),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.add, color: Colors.white, size: 26),
                  Text('$remaining',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
        ],
      );
      if (memory.isAdult) cell = _BlurAfterTap(child: cell);
      return ClipRRect(borderRadius: BorderRadius.circular(r), child: cell);
    }

    if (n == 1) {
      return AspectRatio(aspectRatio: 4 / 3, child: tile(0));
    }
    if (n == 2) {
      return AspectRatio(
        aspectRatio: 2 / 1,
        child: Row(children: [
          Expanded(child: tile(0)),
          const SizedBox(width: gap),
          Expanded(child: tile(1)),
        ]),
      );
    }
    if (n == 3) {
      return AspectRatio(
        aspectRatio: 3 / 2,
        child: Row(children: [
          Expanded(flex: 2, child: tile(0)),
          const SizedBox(width: gap),
          Expanded(
            child: Column(children: [
              Expanded(child: tile(1)),
              const SizedBox(height: gap),
              Expanded(child: tile(2)),
            ]),
          ),
        ]),
      );
    }
    // n >= 4
    final bottomCount = n >= 5 ? 3 : 2;
    final shown = 2 + bottomCount;
    final remaining = n - shown;
    return Column(children: [
      AspectRatio(
        aspectRatio: 2 / 1,
        child: Row(children: [
          Expanded(child: tile(0)),
          const SizedBox(width: gap),
          Expanded(child: tile(1)),
        ]),
      ),
      const SizedBox(height: gap),
      AspectRatio(
        aspectRatio: bottomCount == 3 ? 3 / 1 : 2 / 1,
        child: Row(children: [
          for (int k = 0; k < bottomCount; k++) ...[
            if (k > 0) const SizedBox(width: gap),
            Expanded(
              child: tile(2 + k,
                  overlay: k == bottomCount - 1 && remaining > 0,
                  remaining: remaining),
            ),
          ],
        ]),
      ),
    ]);
  }

  /// Футер карточки: комментарии + закладка (лайков НЕТ — по требованию).
  Widget _cardFooter(Memory memory) {
    final saved = memory.isSavedBy(_myUid ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showMemoryDetail(memory),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chat_bubble_outline_rounded,
                    size: 19, color: widget.theme.textMuted),
                if (memory.commentsCount > 0) ...[
                  const SizedBox(width: 5),
                  Text('${memory.commentsCount}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: widget.theme.textSecondary)),
                ],
              ],
            ),
          ),
          const Spacer(),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                _memRepo.toggleSaved(groupId: _groupId, memoryId: memory.id),
            child: Icon(
              saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              size: 21,
              color: saved ? primary : widget.theme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  PHOTO TILE — social-style photo card (коллаж + футер)
  // ═══════════════════════════════════════════════════
  Widget _photoTile(Memory memory) {
    final allPhotos = <String>[
      if (memory.imageUrls?.isNotEmpty == true)
        ...memory.imageUrls!
      else if (memory.imageUrl?.isNotEmpty == true)
        memory.imageUrl!,
    ];
    final hasPhotos = allPhotos.isNotEmpty;
    final hasVideo = memory.videoUrl?.isNotEmpty == true;
    final caption = memory.caption?.isNotEmpty == true
        ? memory.caption!
        : (memory.title?.isNotEmpty == true ? memory.title! : '');

    return _baseTile(
      memory: memory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(memory, trailing: _typeBadge(memory)),
          const SizedBox(height: 12),
          if (hasPhotos)
            GestureDetector(
              onTap: () => _openCollage(memory),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: _mediaCollage(memory, allPhotos, hasVideo),
              ),
            )
          // Видео без отдельной обложки: всё равно показываем медиа-ячейку
          // с кнопкой play (карточка не должна остаться без превью).
          else if (hasVideo)
            GestureDetector(
              onTap: () => _openCollage(memory),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: _videoOnlyCell(memory),
              ),
            ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                caption,
                style: TextStyle(
                  fontSize: 15,
                  color: widget.theme.textPrimary,
                  height: 1.35,
                ),
              ),
            ),
          _locationDistancePill(memory),
          const SizedBox(height: 12),
          _cardFooter(memory),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  VIDEO TILE — идентична фото-карточке (фото и видео = «Момент»).
  //  Видео рендерится через _photoTile: коллаж показывает обложку с play,
  //  тап открывает полноэкранную галерею (она же проигрывает видео).
  // ═══════════════════════════════════════════════════
  Widget _videoTile(Memory memory) => _photoTile(memory);

  /// Медиа-ячейка для видео без обложки (тёмный фон + play), в стиле коллажа.
  Widget _videoOnlyCell(Memory memory) {
    Widget cell = Container(
      color: widget.theme.isDark
          ? widget.theme.surfaceMuted
          : Colors.grey.shade900,
      child: const Center(
        child: Icon(Icons.play_circle_fill_rounded,
            color: Colors.white, size: 48),
      ),
    );
    if (memory.isAdult) cell = _BlurAfterTap(child: cell);
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: cell,
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  LOCATION TILE — превью места на карте. Оболочка как у фото:
  //  та же шапка (бейдж «Локация») + подпись + футер (без лайков).
  // ═══════════════════════════════════════════════════
  Widget _locationTile(Memory memory) {
    final hasCoords = memory.latitude != null && memory.longitude != null;
    final caption = memory.caption?.isNotEmpty == true
        ? memory.caption!
        : (memory.title?.isNotEmpty == true ? memory.title! : '');

    return _baseTile(
      memory: memory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(memory, trailing: _typeBadge(memory)),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: hasCoords
                ? _locationMapPreview(memory)
                : _placeInfoCard(memory, floating: false),
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                caption,
                style: TextStyle(
                  fontSize: 15,
                  color: widget.theme.textPrimary,
                  height: 1.35,
                ),
              ),
            ),
          const SizedBox(height: 12),
          _cardFooter(memory),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// Превью места на карте (OSM-тайлы, как в LiveMapCard) с булавкой и плавающей
  /// карточкой места снизу. Карта не интерактивна; тап открывает деталь.
  Widget _locationMapPreview(Memory memory) {
    final center = LatLng(memory.latitude!, memory.longitude!);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FlutterMap(
              options: MapOptions(
                initialCenter: center,
                initialZoom: 15,
                interactionOptions:
                    const InteractionOptions(flags: InteractiveFlag.none),
                onTap: (_, _) => _showMemoryDetail(memory),
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.togetherly.love',
                  maxNativeZoom: 19,
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: center,
                      width: 46,
                      height: 46,
                      alignment: Alignment.bottomCenter,
                      child: Icon(
                        Icons.location_on_rounded,
                        color: primary,
                        size: 42,
                        shadows: const [
                          Shadow(
                            color: Colors.black38,
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            // Плавающая карточка места снизу.
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: _placeInfoCard(memory, floating: true),
            ),
          ],
        ),
      ),
    );
  }

  /// Карточка места: миниатюра/иконка-булавка + название + чип дистанции
  /// (тап → маршрут). [floating]=true — белая карточка с тенью поверх карты;
  /// false — лёгкая карточка с рамкой (когда координат нет, карты тоже нет).
  Widget _placeInfoCard(Memory memory, {required bool floating}) {
    final hasCoords = memory.latitude != null && memory.longitude != null;
    final name = memory.locationName?.isNotEmpty == true
        ? memory.locationName!
        : LocaleService.current.location;
    final thumbUrl = memory.imageUrl?.isNotEmpty == true
        ? memory.imageUrl!
        : (memory.imageUrls?.isNotEmpty == true
            ? memory.imageUrls!.first
            : '');

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: widget.theme.cardSurface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: floating
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
        border: floating ? null : Border.all(color: widget.theme.divider),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 46,
              height: 46,
              child: thumbUrl.isNotEmpty
                  ? StorageImage(
                      imageUrl: thumbUrl,
                      fit: BoxFit.cover,
                      memCacheWidth: 140,
                      errorWidget: (_, __, ___) => _pinIconBox(),
                    )
                  : _pinIconBox(),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: widget.theme.textPrimary,
                height: 1.2,
              ),
            ),
          ),
          if (hasCoords) ...[
            const SizedBox(width: 8),
            _routeChip(memory),
          ],
        ],
      ),
    );
  }

  Widget _pinIconBox() {
    return Container(
      color: primary.withOpacity(0.10),
      alignment: Alignment.center,
      child: Icon(Icons.location_on_rounded, color: primary, size: 22),
    );
  }

  /// Чип «маршрут»: показывает дистанцию (если есть GPS) или иконку; тап
  /// открывает место во внешних картах. Цвет — по дистанции (как пилюля фото).
  Widget _routeChip(Memory memory) {
    final dist = _distanceKm(memory.latitude!, memory.longitude!);
    final color =
        dist.isNotEmpty ? _distanceColor(memory.latitude!, memory.longitude!) : primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openLocationInMaps(
        memory.latitude!,
        memory.longitude!,
        memory.locationName,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_rounded, size: 14, color: color),
            if (dist.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(
                dist,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  MUSIC TILE — оболочка как у фото (шапка с бейджем + подпись + футер),
  //  внутри богатый плеер (только для файлов) / карточка-ссылка (для стримингов).
  // ═══════════════════════════════════════════════════
  Widget _musicTile(Memory memory) {
    final caption = memory.caption?.isNotEmpty == true ? memory.caption! : '';
    return _baseTile(
      memory: memory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(memory, trailing: _typeBadge(memory)),
          const SizedBox(height: 12),
          MemoryMusicPlayer(
            key: ValueKey('player_${memory.id}'),
            memory: memory,
            theme: widget.theme,
            bodyOnly: true,
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                caption,
                style: TextStyle(
                  fontSize: 15,
                  color: widget.theme.textPrimary,
                  height: 1.35,
                ),
              ),
            ),
          const SizedBox(height: 12),
          _cardFooter(memory),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  TEXT / NOTE TILE — thought bubble card
  // ═══════════════════════════════════════════════════
  Widget _textTile(Memory memory) {
    final hasTitle = memory.title?.isNotEmpty == true;
    final hasCaption = memory.caption?.isNotEmpty == true;
    final body = hasCaption
        ? memory.caption!
        : (hasTitle ? memory.title! : '');

    return _baseTile(
      memory: memory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Жёлтый стикер-листик (post-it). Без хедера сверху — автор
          // подписан внизу в стиле стикера. Плоский (без тени/бордера). ──
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 18, 16, 14),
              decoration: BoxDecoration(
                color: const Color(0xFFFCE08A),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasTitle && hasCaption) ...[
                    Text(
                      memory.title!,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF5A4A1E),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (body.isNotEmpty)
                    _SpoilerRichText(
                      text: body,
                      style: const TextStyle(
                        fontSize: 15.5,
                        color: Color(0xFF5A4A1E),
                        height: 1.42,
                      ),
                      maxLines: 14,
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    Text(
                      _ru ? 'Заметка' : 'Note',
                      style: const TextStyle(
                        fontSize: 15,
                        fontStyle: FontStyle.italic,
                        color: Color(0xFF8A7733),
                      ),
                    ),
                  const SizedBox(height: 14),
                  // Подпись автора в стиле стикера (внизу справа).
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          '— ${_liveName(memory)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            fontStyle: FontStyle.italic,
                            color: Color(0xFF7A6526),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ClipOval(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: _liveAvatar(memory).isNotEmpty
                              ? StorageImage(
                                  imageUrl: _liveAvatar(memory),
                                  fit: BoxFit.cover,
                                  memCacheWidth: 72,
                                  memCacheHeight: 72,
                                  errorWidget: (_, __, ___) =>
                                      _avatarFallback(_liveName(memory)),
                                )
                              : _avatarFallback(_liveName(memory)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          _locationDistancePill(memory),
          const SizedBox(height: 12),
          _cardFooter(memory),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  BOOK TILE — card with 3D book cover
  // ═══════════════════════════════════════════════════
  Widget _bookTile(Memory memory) {
    final s = LocaleService.current;
    final title = memory.title?.isNotEmpty == true
        ? memory.title!
        : LocaleService.current.books;
    final author = memory.bookAuthor ?? '';
    final hasAuthor = author.isNotEmpty;
    final hasYear =
        memory.bookYear != null && memory.bookYear!.isNotEmpty;
    final hasPublisher =
        memory.bookPublisher != null && memory.bookPublisher!.isNotEmpty;

    return _baseTile(
      memory: memory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(memory, subtitle: s.sharedABook, badgeColor: primary),
          const SizedBox(height: 10),
          // ── Book sub-card (3D cover + meta) ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: widget.theme.surfaceMuted,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: widget.theme.divider, width: 1),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Mini 3D book cover (no tap — outer tile handles it) ──
                  _MiniBookCover(
                    accent: primary,
                    coverUrl: memory.bookCoverUrl,
                    title: title,
                    author: author,
                  ),
                  const SizedBox(width: 12),
                  // ── Text content ──
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: widget.theme.textPrimary,
                                  height: 1.25,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (memory.rating != null) ...[
                              const SizedBox(width: 8),
                              RatingBadge(rating: memory.rating!, fontSize: 11),
                            ],
                          ],
                        ),
                        if (hasAuthor)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              author,
                              style: TextStyle(
                                fontSize: 12,
                                color: widget.theme.textMuted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const SizedBox(height: 6),
                        // ── Meta chips ──
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (hasYear)
                              _bookChip(
                                Icons.calendar_today_rounded,
                                memory.bookYear!,
                                primary,
                              ),
                            if (hasPublisher)
                              _bookChip(
                                Icons.business_rounded,
                                memory.bookPublisher!,
                                primary,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (memory.caption?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: _SpoilerRichText(
                text: memory.caption!,
                style: TextStyle(
                  fontSize: 13,
                  color: widget.theme.textSecondary,
                  height: 1.45,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          _locationDistancePill(memory),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _bookChip(IconData icon, String label, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: accent),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  MOVIE TILE — card with poster + rating
  // ═══════════════════════════════════════════════════
  Widget _movieTile(Memory memory) {
    final s = LocaleService.current;
    final isRu = LocaleService.instance.isRussian;
    final title = memory.title?.isNotEmpty == true
        ? memory.title!
        : s.movies;
    final original = memory.movieOriginalTitle ?? '';
    final hasOriginal = original.isNotEmpty && original != title;
    final hasYear = memory.movieYear?.isNotEmpty == true;
    final hasGenres = memory.movieGenres?.isNotEmpty == true;
    final hasKp = memory.movieRatingKp?.isNotEmpty == true;

    return _baseTile(
      memory: memory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(memory, subtitle: s.sharedAMovie, badgeColor: primary),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: widget.theme.surfaceMuted,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: widget.theme.divider, width: 1),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _MiniMoviePoster(
                    accent: primary,
                    posterUrl: memory.moviePosterUrl,
                    title: title,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: widget.theme.textPrimary,
                                  height: 1.25,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (memory.rating != null) ...[
                              const SizedBox(width: 8),
                              RatingBadge(rating: memory.rating!, fontSize: 11),
                            ],
                          ],
                        ),
                        if (hasOriginal)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              original,
                              style: TextStyle(
                                fontSize: 12,
                                color: widget.theme.textMuted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _movieKindChip(memory.movieKind, isRu),
                            if (hasYear)
                              _bookChip(
                                Icons.calendar_today_rounded,
                                memory.movieYear!,
                                primary,
                              ),
                            if (hasKp) _kpChip(memory.movieRatingKp!),
                            if (hasGenres)
                              _bookChip(
                                Icons.theaters_rounded,
                                memory.movieGenres!,
                                primary,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (memory.caption?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: _SpoilerRichText(
                text: memory.caption!,
                style: TextStyle(
                  fontSize: 13,
                  color: widget.theme.textSecondary,
                  height: 1.45,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          _locationDistancePill(memory),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _movieKindChip(String? kind, bool isRu) {
    final label = movieKindLabel(kind, isRu: isRu);
    final isSeries = kind != null && kind != 'movie' && kind != 'cartoon';
    final color = isSeries ? const Color(0xFF8B5CF6) : primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }

  Widget _kpChip(String rating) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 11, color: Colors.amber.shade700),
          const SizedBox(width: 4),
          Text(
            LocaleService.current.kpRating(rating),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.amber.shade800,
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  VIDEO LINK TILE — card for shared web video link
  // ═══════════════════════════════════════════════════
  Widget _videoLinkTile(Memory memory) {
    final platform = _detectVideoPlatform(memory.videoUrl ?? '');
    final platformColor = platform['color'] as Color;
    final platformName = platform['name'] as String;
    final hasThumb = memory.imageUrl?.isNotEmpty == true;

    Widget buildSubCard() => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.theme.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: widget.theme.divider, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Thumbnail with play overlay
              GestureDetector(
                onTap: () {
                  final url = memory.videoUrl;
                  if (url != null && url.isNotEmpty) {
                    launchUrl(
                      Uri.parse(url),
                      mode: LaunchMode.externalApplication,
                    );
                  }
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 80,
                    height: 56,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Thumbnail or platform-colored fallback
                        if (hasThumb)
                          StorageImage(
                            imageUrl: memory.imageUrl!,
                            fit: BoxFit.cover,
                            memCacheWidth: 160,
                            memCacheHeight: 112,
                            errorWidget: (_, __, ___) =>
                                _videoLinkThumbFallback(platformColor),
                          )
                        else
                          _videoLinkThumbFallback(platformColor),
                        // Dark overlay
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.transparent,
                                Colors.black.withOpacity(0.35),
                              ],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                          ),
                        ),
                        // Play button
                        Center(
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.92),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.20),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 18,
                              color: platformColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Title, author, platform badge
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      memory.title?.isNotEmpty == true
                          ? memory.title!
                          : LocaleService.current.video,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: widget.theme.textPrimary,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    // Platform badge — music-style chip (no border)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: platformColor.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _videoPlatformIcon(platformName),
                            size: 11,
                            color: platformColor,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              platformName,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: platformColor,
                                letterSpacing: 0.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Author/channel if in musicArtist field
                    if (memory.musicArtist?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          memory.musicArtist!,
                          style: TextStyle(
                            fontSize: 11,
                            color: widget.theme.textMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          // Caption
          if (memory.caption?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text(
              memory.caption!,
              style: TextStyle(
                fontSize: 12,
                color: widget.theme.textSecondary,
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),
          // Open button — solid platform color, no border, white text
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                final url = memory.videoUrl;
                if (url != null && url.isNotEmpty) {
                  launchUrl(
                    Uri.parse(url),
                    mode: LaunchMode.externalApplication,
                  );
                }
              },
              icon: const Icon(
                Icons.open_in_new_rounded,
                size: 14,
                color: Colors.white,
              ),
              label: Text(
                LocaleService.current.openIn(platformName),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: platformColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
    return _baseTile(
      memory: memory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Оболочка как везде: шапка с бейглом «Видео» справа + футер снизу.
          _cardHeader(memory, trailing: _typeBadge(memory)),
          const SizedBox(height: 12),
          // ── Превью видео + кнопки «Открыть в …» и «Смотреть вместе» ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: platformName == 'YouTube'
                ? _YouTubeInlineCard(
                    memory: memory,
                    platformColor: platformColor,
                    platformName: platformName,
                    pairId: pair.pairId,
                    partnerUid: pair.partnerUid,
                  )
                : buildSubCard(),
          ),
          const SizedBox(height: 12),
          _cardFooter(memory),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _videoLinkThumbFallback(Color platformColor) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            platformColor.withOpacity(0.85),
            platformColor.withOpacity(0.55),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(
        Icons.play_circle_outline_rounded,
        color: Colors.white,
        size: 28,
      ),
    );
  }

  // ── Platform detection for video URLs ──
  static Map<String, dynamic> _detectVideoPlatform(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
      return {'name': 'YouTube', 'color': const Color(0xFFFF0000)};
    } else if (lower.contains('vimeo.com')) {
      return {'name': 'Vimeo', 'color': const Color(0xFF1AB7EA)};
    } else if (lower.contains('dailymotion.com')) {
      return {'name': 'Dailymotion', 'color': const Color(0xFF0066DC)};
    } else if (lower.contains('twitch.tv')) {
      return {'name': 'Twitch', 'color': const Color(0xFF9146FF)};
    } else if (lower.contains('tiktok.com')) {
      return {'name': 'TikTok', 'color': const Color(0xFF010101)};
    } else if (lower.contains('instagram.com')) {
      return {'name': 'Instagram', 'color': const Color(0xFFE1306C)};
    } else if (lower.contains('facebook.com') || lower.contains('fb.watch')) {
      return {'name': 'Facebook', 'color': const Color(0xFF1877F2)};
    } else if (lower.contains('twitter.com') || lower.contains('x.com')) {
      return {'name': 'Twitter/X', 'color': const Color(0xFF000000)};
    } else if (lower.contains('rutube.ru')) {
      return {'name': 'Rutube', 'color': const Color(0xFF1482C8)};
    } else if (lower.contains('vk.com') || lower.contains('vkvideo.ru')) {
      return {'name': 'VK Video', 'color': const Color(0xFF0077FF)};
    } else {
      return {
        'name': LocaleService.current.video,
        'color': const Color(0xFF6B7280),
      };
    }
  }

  static IconData _videoPlatformIcon(String platformName) {
    switch (platformName) {
      case 'YouTube':
        return Icons.smart_display_rounded;
      case 'Twitch':
        return Icons.live_tv_rounded;
      case 'TikTok':
        return Icons.music_video_rounded;
      case 'Instagram':
        return Icons.camera_alt_rounded;
      case 'Facebook':
        return Icons.facebook_rounded;
      case 'Vimeo':
      case 'Dailymotion':
        return Icons.play_circle_rounded;
      case 'Rutube':
      case 'VK Video':
        return Icons.play_circle_outline_rounded;
      default:
        return Icons.videocam_rounded;
    }
  }

  /// Fetch video metadata (title, channel, thumbnail) from a URL
  Future<Map<String, String?>> _fetchVideoMeta(String url) async {
    final lower = url.toLowerCase();

    // ── YouTube (official oEmbed — no API key required) ──
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
      try {
        final resp = await http.get(
          Uri.parse(
            'https://www.youtube.com/oembed?url=${Uri.encodeComponent(url)}&format=json',
          ),
        );
        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          return {
            'title': data['title'] as String?,
            'author': data['author_name'] as String?,
            'cover': data['thumbnail_url'] as String?,
          };
        }
      } catch (e) {
        debugPrint('YouTube video meta error: $e');
      }
      return {};
    }

    // ── Vimeo via oEmbed ──
    if (lower.contains('vimeo.com')) {
      try {
        final resp = await http.get(
          Uri.parse(
            'https://vimeo.com/api/oembed.json?url=${Uri.encodeComponent(url)}',
          ),
        );
        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          return {
            'title': data['title'] as String?,
            'author': data['author_name'] as String?,
            'cover': data['thumbnail_url'] as String?,
          };
        }
      } catch (e) {
        debugPrint('Vimeo meta error: $e');
      }
    }

    // ── Dailymotion via oEmbed ──
    if (lower.contains('dailymotion.com')) {
      try {
        final resp = await http.get(
          Uri.parse(
            'https://www.dailymotion.com/services/oembed?url=${Uri.encodeComponent(url)}&format=json',
          ),
        );
        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          return {
            'title': data['title'] as String?,
            'author': data['author_name'] as String?,
            'cover': data['thumbnail_url'] as String?,
          };
        }
      } catch (e) {
        debugPrint('Dailymotion meta error: $e');
      }
    }

    // ── Generic noembed.com fallback ──
    try {
      final resp = await http.get(
        Uri.parse('https://noembed.com/embed?url=${Uri.encodeComponent(url)}'),
      );
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        if (data['error'] == null) {
          return {
            'title': data['title'] as String?,
            'author': data['author_name'] as String?,
            'cover': data['thumbnail_url'] as String?,
          };
        }
      }
    } catch (_) {}

    // ── OG tags fallback ──
    try {
      final resp = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Mozilla/5.0 (compatible; Twitterbot/1.0)'},
      );
      if (resp.statusCode == 200) {
        final body = resp.body;
        final titleMatch = RegExp(
          r'property="og:title"\s+content="([^"]+)"',
          caseSensitive: false,
        ).firstMatch(body);
        final imageMatch = RegExp(
          r'property="og:image"\s+content="([^"]+)"',
          caseSensitive: false,
        ).firstMatch(body);
        final authorMatch = RegExp(
          r'name="author"\s+content="([^"]+)"',
          caseSensitive: false,
        ).firstMatch(body);
        if (titleMatch != null) {
          return {
            'title': _decodeHtmlEntities(titleMatch.group(1) ?? ''),
            'author': authorMatch?.group(1),
            'cover': imageMatch?.group(1),
          };
        }
      }
    } catch (_) {}

    return {};
  }

  // ═══════════════════════════════════════════════════
  //  BASE TILE WRAPPER
  // ═══════════════════════════════════════════════════
  Widget _baseTile({
    required Memory memory,
    required Widget child,
    bool enableTap = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: enableTap ? () => _showMemoryDetail(memory) : null,
        onLongPress: () => _showMemoryActions(memory),
        child: Container(
          // Плоский стиль пинов: без тени, свечения и бордера (требование).
          decoration: BoxDecoration(
            color: widget.theme.cardSurface,
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ),
    );
  }

  Color _memoryTypeColor(MemoryType type) => primary;

  // ═══════════════════════════════════════════════════
  //  MEMORY DETAIL — full screen
  // ═══════════════════════════════════════════════════
  void _showMemoryDetail(Memory memory) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: widget.theme.cardSurface,
      builder: (_) => _MemoryDetailSheet(
        memory: memory,
        groupId: _groupId,
        primary: primary,
        isOwner: memory.authorUid == _myUid,
        canDownload: _canDownload(memory),
        typeColor: _memoryTypeColor(memory.type),
        userLat: _userLat,
        userLng: _userLng,
        liveAuthorAvatar: _liveAvatar(memory),
        onTogglePin: () => _togglePin(memory),
        onDownload: () => _downloadMemoryMedia(memory),
        onEdit: () => _editMemory(memory),
        onDelete: () => _confirmDelete(memory),
        onSetLocation: () => _setLocationOnMemory(memory),
      ),
    );
  }

  // ignore: unused_element
  void _showMemoryDetailLEGACY(Memory memory) {
    AudioPlayer? audioPlayer;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: widget.theme.cardSurface,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setState) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize:
                  memory.type == MemoryType.photo ||
                      memory.type == MemoryType.video
                  ? 0.85
                  : 0.7,
              maxChildSize: 0.95,
              builder: (_, scrollController) => SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: widget.theme.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Type badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _memoryTypeColor(memory.type).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SvgPicture.asset(
                            _typeSvgAsset(memory.type),
                            width: 14,
                            height: 14,
                            colorFilter: ColorFilter.mode(
                              _memoryTypeColor(memory.type),
                              BlendMode.srcIn,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            memory.typeLabel,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _memoryTypeColor(memory.type),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── PHOTO detail ──
                    if (memory.type == MemoryType.photo) ...[
                      if ((memory.imageUrls?.isNotEmpty == true) ||
                          (memory.imageUrl != null &&
                              memory.imageUrl!.isNotEmpty))
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: AspectRatio(
                            aspectRatio: 1.0,
                            child: StorageImage(
                              imageUrl: memory.imageUrls?.isNotEmpty == true
                                  ? memory.imageUrls!.first
                                  : memory.imageUrl!,
                              width: double.infinity,
                              height: double.infinity,
                              fit: BoxFit.cover,
                              errorWidget: (context, url, error) => Container(
                                color: widget.theme.surfaceMuted,
                                child: Center(
                                  child: Icon(
                                    Icons.broken_image_rounded,
                                    color: widget.theme.textMuted,
                                    size: 48,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        Container(
                          height: 200,
                          decoration: BoxDecoration(
                            color: widget.theme.surfaceMuted,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.image_not_supported_rounded,
                                  color: widget.theme.textMuted,
                                  size: 48,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  LocaleService.current.photoNotUploaded,
                                  style: TextStyle(color: widget.theme.textMuted),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],

                    // ── VIDEO detail ── (также для смешанного фото+видео пина)
                    if (memory.type == MemoryType.video ||
                        (memory.type == MemoryType.photo &&
                            memory.videoUrl?.isNotEmpty == true)) ...[
                      if (memory.type == MemoryType.photo)
                        const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Stack(
                          children: [
                            if (memory.imageUrl != null &&
                                memory.imageUrl!.isNotEmpty)
                              StorageImage(
                                imageUrl: memory.imageUrl!,
                                width: double.infinity,
                                height: 220,
                                fit: BoxFit.cover,
                                errorWidget: (context, url, error) => Container(
                                  height: 220,
                                  color: widget.theme.isDark
                                      ? widget.theme.surfaceMuted
                                      : Colors.grey.shade900,
                                ),
                              )
                            else
                              Container(
                                height: 220,
                                color: widget.theme.isDark
                                    ? widget.theme.surfaceMuted
                                    : Colors.grey.shade900,
                              ),
                            Container(
                              height: 220,
                              color: Colors.black.withOpacity(0.4),
                            ),
                            SizedBox(
                              height: 220,
                              width: double.infinity,
                              child: Center(
                                child: GestureDetector(
                                  onTap: () {
                                    final url = memory.videoUrl;
                                    if (url != null && url.isNotEmpty) {
                                      launchUrl(
                                        Uri.parse(url),
                                        mode: LaunchMode.externalApplication,
                                      );
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(18),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.9),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 40,
                                      color: Color(0xFFEC4899),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // ── LOCATION detail ──
                    if (memory.type == MemoryType.location) ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: widget.theme.isDark
                              ? widget.theme.surfaceMuted
                              : const Color(0xFFF0FAF4),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: widget.theme.isDark
                                  ? widget.theme.cardBorder
                                  : const Color(0xFFD1F0DE)),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF22C55E,
                                    ).withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.location_on_rounded,
                                    color: Color(0xFF22C55E),
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        memory.locationName ??
                                            LocaleService
                                                .current
                                                .unknownLocation,
                                        style: TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                          color: widget.theme.textPrimary,
                                        ),
                                      ),
                                      if (memory.latitude != null)
                                        Text(
                                          '${memory.latitude!.toStringAsFixed(5)}, ${memory.longitude?.toStringAsFixed(5) ?? ""}',
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
                            if (memory.latitude != null &&
                                memory.longitude != null) ...[
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    final url =
                                        'https://www.google.com/maps?q=${memory.latitude},${memory.longitude}';
                                    launchUrl(
                                      Uri.parse(url),
                                      mode: LaunchMode.externalApplication,
                                    );
                                  },
                                  icon: const Icon(Icons.map_rounded, size: 18),
                                  label: Text(
                                    LocaleService.current.openInGoogleMaps,
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF22C55E),
                                    side: const BorderSide(
                                      color: Color(0xFF22C55E),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],

                    // ── MUSIC detail with playback ──
                    if (memory.type == MemoryType.music) ...[
                      _buildMusicDetailWidget(memory, audioPlayer, (player) {
                        setState(() => audioPlayer = player);
                      }),
                    ],

                    // ── TEXT / NOTE detail ──
                    if (memory.type == MemoryType.text) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: widget.theme.isDark
                              ? widget.theme.surfaceMuted
                              : const Color(0xFFFFFBEB),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: widget.theme.isDark
                                  ? widget.theme.cardBorder
                                  : const Color(0xFFFEF3C7)),
                        ),
                        child: Text(
                          memory.caption ?? '',
                          style: TextStyle(
                            fontSize: 16,
                            color: widget.theme.textPrimary,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ],

                    // Caption (for non-text types)
                    if (memory.type != MemoryType.text &&
                        memory.caption != null &&
                        memory.caption!.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        memory.caption!,
                        style: TextStyle(
                          fontSize: 16,
                          color: widget.theme.textPrimary,
                          height: 1.5,
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),
                    // Author + time
                    Row(
                      children: [
                        AvatarWidget(
                          uid: memory.authorUid,
                          liveUrl: _liveAvatar(memory),
                          fallbackUrl: memory.authorAvatar,
                          name: _liveName(memory),
                          size: 28,
                          primary: primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _liveName(memory),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: widget.theme.textSecondary,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _formatFullDate(memory.createdAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: widget.theme.textMuted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Action buttons — две строки по 2 кнопки
                    Column(
                      children: [
                        // Строка 1: Pin + Save
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  audioPlayer?.dispose();
                                  Navigator.pop(context);
                                  _togglePin(memory);
                                },
                                icon: Icon(
                                  memory.isPinned
                                      ? Icons.push_pin_rounded
                                      : Icons.push_pin_outlined,
                                  size: 16,
                                ),
                                label: Text(
                                  memory.isPinned
                                      ? LocaleService.current.unpinMemory
                                      : LocaleService.current.pinMemory,
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: primary,
                                  side: BorderSide(
                                    color: primary.withOpacity(0.3),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                            if (_canDownload(memory)) ...[
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    audioPlayer?.dispose();
                                    Navigator.pop(context);
                                    _downloadMemoryMedia(memory);
                                  },
                                  icon: const Icon(
                                    Icons.download_rounded,
                                    size: 16,
                                  ),
                                  label: Text(
                                    LocaleService.current.saveToDevice,
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.blue.shade600,
                                    side: BorderSide(
                                      color: Colors.blue.shade200,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        // Строка 2: Edit + Delete (только для своих записей)
                        if (memory.authorUid == _myUid) ...[
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    audioPlayer?.dispose();
                                    Navigator.pop(context);
                                    _editMemory(memory);
                                  },
                                  icon: const Icon(
                                    Icons.edit_rounded,
                                    size: 16,
                                  ),
                                  label: Text(LocaleService.current.editMemory),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: widget.theme.textSecondary,
                                    side: BorderSide(
                                      color: widget.theme.divider,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    audioPlayer?.dispose();
                                    Navigator.pop(context);
                                    _confirmDelete(memory);
                                  },
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 16,
                                  ),
                                  label: Text(
                                    LocaleService.current.deleteMemory,
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.red.shade400,
                                    side: BorderSide(
                                      color: Colors.red.shade200,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),

                    // ── Comments section ──
                    const SizedBox(height: 24),
                    _CommentsSection(
                      groupId: _groupId,
                      memoryId: memory.id,
                      primary: primary,
                    ),

                    const _KeyboardPaddingBox(),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      audioPlayer?.dispose();
    });
  }

  // ── Music player widget for detail view ──
  Widget _buildMusicDetailWidget(
    Memory memory,
    AudioPlayer? player,
    void Function(AudioPlayer) onPlayer,
  ) {
    return _MusicPlayerWidget(
      memory: memory,
      player: player,
      onPlayerCreated: onPlayer,
      primary: primary,
      typeColor: _memoryTypeColor(MemoryType.music),
    );
  }

  String _formatFullDate(DateTime dt) {
    final s = LocaleService.current;
    return s.formatDateAt(
      s.shortMonths[dt.month],
      dt.day,
      dt.year,
      _timeStr(dt),
    );
  }

  // ═══════════════════════════════════════════════════
  //  MEMORY ACTIONS (long press)
  // ═══════════════════════════════════════════════════
  // ── Секретные воспоминания (PIN) ──────────────────────────────────────────
  /// Кнопка-замок в шапке: заблокировать снова (мгновенно) либо разблокировать
  /// вводом PIN.
  Future<void> _toggleSecretLock() async {
    if (_secretUnlocked) {
      setState(() => _secretUnlocked = false);
      return;
    }
    final pin = await _askPin(create: false);
    if (pin == null || !mounted) return;
    final ok = await SecretPinService.verify(pin);
    if (!mounted) return;
    if (ok) {
      setState(() => _secretUnlocked = true);
    } else {
      _secretSnack(LocaleService.current.wrongPin, error: true);
    }
  }

  /// Пометить/снять «секретное». При первой пометке (нет PIN) — просим задать.
  Future<void> _toggleSecret(Memory memory) async {
    final makeSecret = !memory.isSecret;
    if (makeSecret && !await SecretPinService.hasPin()) {
      final pin = await _askPin(create: true);
      if (pin == null) return;
      await SecretPinService.setPin(pin);
      if (mounted) setState(() => _secretUnlocked = true);
    }
    await _memRepo.update(
      groupId: _groupId,
      memoryId: memory.id,
      isSecret: makeSecret,
    );
    if (mounted) {
      _secretSnack(makeSecret
          ? LocaleService.current.markedSecret
          : LocaleService.current.unmarkedSecret);
    }
  }

  /// Диалог PIN. [create]=true — задать новый (≥4 цифр); иначе ввод для
  /// разблокировки. Возвращает PIN или null (отмена).
  Future<String?> _askPin({required bool create}) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String? err;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            backgroundColor: widget.theme.cardSurface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(create
                ? LocaleService.current.setPinTitle
                : LocaleService.current.enterPinTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  autofocus: true,
                  maxLength: 8,
                  decoration: InputDecoration(
                    hintText: '••••',
                    counterText: '',
                    errorText: err,
                  ),
                ),
                if (create)
                  Text(
                    LocaleService.current.setPinHint,
                    style:
                        TextStyle(fontSize: 12, color: widget.theme.textMuted),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(LocaleService.current.cancel),
              ),
              ElevatedButton(
                onPressed: () {
                  final v = ctrl.text.trim();
                  if (create && v.length < 4) {
                    setD(() => err = LocaleService.current.pinTooShort);
                    return;
                  }
                  if (v.isEmpty) return;
                  Navigator.pop(ctx, v);
                },
                child: Text(LocaleService.current.pinDone),
              ),
            ],
          ),
        );
      },
    );
  }

  void _secretSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? Colors.orange : primary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  // ── Капсула времени ───────────────────────────────────────────────────────
  Future<void> _openTimeCapsule() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => TimeCapsuleScreen(
          theme: widget.theme,
          pairId: _groupId,
          authorName: widget.userData?.displayName ?? '',
          authorAvatar: widget.userData?.avatarUrl ?? '',
        ),
        settings: const RouteSettings(name: '/time_capsule'),
      ),
    );
    if (created == true && mounted) {
      _secretSnack(LocaleService.current.capsuleCreated);
    }
  }

  String _fmtCapsuleDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  void _showMemoryActions(Memory memory) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      backgroundColor: widget.theme.cardSurface,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: widget.theme.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: Icon(
                memory.isPinned
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                color: primary,
              ),
              title: Text(
                memory.isPinned
                    ? LocaleService.current.unpinMemory
                    : LocaleService.current.pinMemory,
              ),
              onTap: () {
                Navigator.pop(context);
                _togglePin(memory);
              },
            ),
            ListTile(
              leading: Icon(
                memory.latitude != null
                    ? Icons.location_on_rounded
                    : Icons.add_location_alt_rounded,
                color: Colors.teal,
              ),
              title: Text(
                memory.latitude != null
                    ? LocaleService.current.editLocation
                    : LocaleService.current.addLocation,
              ),
              onTap: () {
                Navigator.pop(context);
                _setLocationOnMemory(memory);
              },
            ),
            ListTile(
              leading: Icon(
                memory.isSecret
                    ? Icons.lock_open_rounded
                    : Icons.lock_rounded,
                color: primary,
              ),
              title: Text(
                memory.isSecret
                    ? LocaleService.current.unmarkSecret
                    : LocaleService.current.markSecret,
              ),
              onTap: () {
                Navigator.pop(context);
                _toggleSecret(memory);
              },
            ),
            if (_canDownload(memory))
              ListTile(
                leading: Icon(
                  Icons.download_rounded,
                  color: Colors.blue.shade600,
                ),
                title: Text(LocaleService.current.saveToDevice),
                onTap: () {
                  Navigator.pop(context);
                  _downloadMemoryMedia(memory);
                },
              ),
            if (memory.authorUid == _myUid) ...[
              ListTile(
                leading: Icon(Icons.edit_rounded, color: widget.theme.textSecondary),
                title: Text(LocaleService.current.editMemory),
                onTap: () {
                  Navigator.pop(context);
                  _editMemory(memory);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.red.shade400,
                ),
                title: Text(
                  LocaleService.current.deleteMemory,
                  style: TextStyle(color: Colors.red.shade400),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(memory);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  DOWNLOAD
  // ═══════════════════════════════════════════════════

  bool _canDownload(Memory memory) {
    return memory.type == MemoryType.photo ||
        memory.type == MemoryType.video ||
        memory.type == MemoryType.music;
  }

  /// Extracts the file extension from a Firebase Storage URL.
  /// e.g. ".../memory_123.webp?alt=media&token=..." → "webp"
  String _extFromUrl(String url, String fallback) {
    try {
      final decoded = Uri.decodeFull(url);
      final path = Uri.parse(decoded).path;
      final name = path.split('/').last.split('?').first;
      final dot = name.lastIndexOf('.');
      if (dot != -1) return name.substring(dot + 1).toLowerCase();
    } catch (_) {}
    return fallback;
  }

  Future<void> _downloadMemoryMedia(Memory memory) async {
    String? url;
    String extension;
    String prefix;

    switch (memory.type) {
      case MemoryType.photo:
        url = memory.imageUrl;
        extension = url != null ? _extFromUrl(url, 'webp') : 'webp';
        prefix = 'photo';
        break;
      case MemoryType.video:
        url = memory.videoUrl;
        extension = url != null ? _extFromUrl(url, 'mp4') : 'mp4';
        prefix = 'video';
        break;
      case MemoryType.music:
        url = memory.musicUrl;
        extension = url != null ? _extFromUrl(url, 'mp3') : 'mp3';
        prefix = 'music';
        break;
      default:
        return;
    }

    if (url == null || url.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.noMediaUrl),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // pb:// → authed HTTPS (PocketBase protected media). Легаси gs:// больше
    // НЕ резолвим (Firebase убран) — такой url уйдёт в http.get и не скачается.
    final isGsPath = url.startsWith('gs://');
    url = await PbMediaService().resolvePlayable(url);

    // For external links (Spotify, YouTube etc.) just open them.
    // Signed URL (storage.googleapis.com) не содержит 'firebase' — поэтому
    // gs://-медиа пропускаем мимо этой проверки по флагу isGsPath.
    if (!isGsPath &&
        !url.contains('firebasestorage') &&
        !url.contains('firebase')) {
      if (await canLaunchUrl(Uri.parse(url))) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
      return;
    }

    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.downloading),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 1),
          ),
        );
      }

      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception('Download failed: ${response.statusCode}');
      }

      // Write to a temp file first, then hand off to gal (images/video)
      // or Downloads folder (audio). gal inserts into Android MediaStore so
      // the system Gallery app sees it immediately.
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = '${prefix}_$timestamp.$extension';
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(response.bodyBytes);

      if (memory.type == MemoryType.photo) {
        await Gal.putImage(tempFile.path, album: 'Togetherly');
      } else if (memory.type == MemoryType.video) {
        await Gal.putVideo(tempFile.path, album: 'Togetherly');
      } else {
        // Audio — save to Downloads (Files app sees it without MediaStore)
        Directory saveDir;
        if (Platform.isAndroid) {
          saveDir = Directory('/storage/emulated/0/Download');
          if (!saveDir.existsSync()) saveDir = await getApplicationDocumentsDirectory();
        } else {
          saveDir = await getApplicationDocumentsDirectory();
        }
        final destFile = File('${saveDir.path}/$fileName');
        await tempFile.copy(destFile.path);
      }

      await tempFile.delete().catchError((_) => tempFile);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.savedToGallery),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('Download error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.downloadFailed(e.toString())),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // ═══════════════════════════════════════════════════
  //  CRUD
  // ═══════════════════════════════════════════════════
  Future<void> _togglePin(Memory memory) async {
    await _memRepo.togglePin(
      groupId: _groupId,
      memoryId: memory.id,
      isPinned: !memory.isPinned,
    );
  }

  void _confirmDelete(Memory memory) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(LocaleService.current.deleteMemoryQuestion),
        content: Text(LocaleService.current.actionCannotBeUndone),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(LocaleService.current.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _memRepo.delete(
                groupId: _groupId,
                memoryId: memory.id,
                imageUrl: memory.imageUrl,
                videoUrl: memory.videoUrl,
                musicUrl: memory.musicUrl,
                musicCoverUrl: memory.musicCoverUrl,
              );

              // Обновляем виджет, если удалили фото дня
              if (memory.type == MemoryType.photo) {
                await HomeWidgetService.instance.handleMemoryDeleted(
                  _groupId,
                  memory.id,
                );
              }
            },
            child: Text(
              LocaleService.current.delete,
              style: TextStyle(color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );
  }

  void _editMemory(Memory memory) {
    final titleCtrl = TextEditingController(text: memory.title ?? '');
    final captionCtrl = TextEditingController(text: memory.caption ?? '');
    final locationCtrl = TextEditingController(text: memory.locationName ?? '');
    double? editLat = memory.latitude;
    double? editLng = memory.longitude;
    bool isAdultEdit = memory.isAdult;
    // Оценка 1–10 (для книг и фильмов) — можно изменить при редактировании.
    int? editRating = memory.rating;
    final bool isRatable =
        memory.type == MemoryType.book || memory.type == MemoryType.movie;
    // Дата воспоминания: инициализируем текущей createdAt — пользователь
    // может изменить её, и тогда пин переедет в нужную точку ленты.
    DateTime editDate = memory.createdAt;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: widget.theme.cardSurface,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          return SingleChildScrollView(
            child: Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              24,
              24,
              // Клавиатура + системная навигация снизу, чтобы кнопка
              // сохранения и оценка не уходили под кнопки телефона.
              MediaQuery.of(context).viewInsets.bottom +
                  MediaQuery.of(context).padding.bottom +
                  24,
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
                      color: widget.theme.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  LocaleService.current.editMemoryTitle,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: widget.theme.textPrimary,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: titleCtrl,
                  maxLines: 1,
                  decoration: InputDecoration(
                    hintText: LocaleService.current.titleOptional,
                    prefixIcon: const Icon(Icons.title_rounded, size: 20),
                    filled: true,
                    fillColor: widget.theme.surfaceMuted,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: widget.theme.divider),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: widget.theme.divider),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: captionCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: isRatable
                        ? LocaleService.current.reviewHint
                        : LocaleService.current.description,
                    filled: true,
                    fillColor: widget.theme.surfaceMuted,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: widget.theme.divider),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: widget.theme.divider),
                    ),
                  ),
                ),
                // Оценка 1–10 для книг/фильмов
                if (isRatable) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: widget.theme.surfaceMuted,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: widget.theme.divider),
                    ),
                    child: RatingPicker(
                      value: editRating,
                      accent: primary,
                      onChanged: (v) => setState(() => editRating = v),
                    ),
                  ),
                ],
                // Spoiler toolbar for text pins in edit form
                if (memory.type == MemoryType.text) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          final sel = captionCtrl.selection;
                          if (!sel.isValid) return;
                          final text = captionCtrl.text;
                          if (sel.isCollapsed) {
                            final pos = sel.start;
                            final newText =
                                '${text.substring(0, pos)}||||${text.substring(pos)}';
                            captionCtrl.value = TextEditingValue(
                              text: newText,
                              selection: TextSelection.collapsed(
                                offset: pos + 2,
                              ),
                            );
                          } else {
                            final selected = text.substring(sel.start, sel.end);
                            final newText = text.replaceRange(
                              sel.start,
                              sel.end,
                              '||$selected||',
                            );
                            captionCtrl.value = TextEditingValue(
                              text: newText,
                              selection: TextSelection.collapsed(
                                offset: sel.start + selected.length + 4,
                              ),
                            );
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: primary.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.visibility_off_rounded,
                                size: 14,
                                color: primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                LocaleService.current.spoiler,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        LocaleService.current.selectTextAndPress,
                        style: TextStyle(
                          fontSize: 11,
                          color: widget.theme.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (memory.type == MemoryType.location) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: locationCtrl,
                    decoration: InputDecoration(
                      hintText: LocaleService.current.locationNameHint,
                      prefixIcon: const Icon(Icons.location_on_rounded),
                      filled: true,
                      fillColor: widget.theme.surfaceMuted,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: widget.theme.divider),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: widget.theme.divider),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => MapPickerScreen(
                              initialLatitude: editLat,
                              initialLongitude: editLng,
                            ),
                            settings: const RouteSettings(name: '/map_picker'),
                          ),
                        );

                        if (result != null && mounted) {
                          setState(() {
                            editLat = result['latitude'];
                            editLng = result['longitude'];
                            locationCtrl.text = result['address'] ?? '';
                          });
                        }
                      },
                      icon: const Icon(Icons.map_rounded),
                      label: Text(
                        editLat != null && editLng != null
                            ? LocaleService.current.changeLocationOnMap
                            : LocaleService.current.pickLocationOnMap,
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF22C55E),
                        side: const BorderSide(color: Color(0xFF22C55E)),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                // 18+ toggle for photo edits
                if (memory.type == MemoryType.photo) ...[
                  GestureDetector(
                    onTap: () => setState(() => isAdultEdit = !isAdultEdit),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isAdultEdit
                            ? Colors.red.shade50
                            : widget.theme.surfaceMuted,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isAdultEdit
                              ? Colors.red.shade200
                              : widget.theme.divider,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isAdultEdit
                                ? Icons.lock_rounded
                                : Icons.lock_open_rounded,
                            size: 18,
                            color: isAdultEdit
                                ? Colors.red.shade400
                                : widget.theme.textMuted,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  LocaleService.current.adultContent,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: isAdultEdit
                                        ? Colors.red.shade600
                                        : widget.theme.textSecondary,
                                  ),
                                ),
                                Text(
                                  LocaleService.current.photoBlurred,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isAdultEdit
                                        ? Colors.red.shade400
                                        : widget.theme.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: isAdultEdit,
                            onChanged: (v) => setState(() => isAdultEdit = v),
                            activeColor: Colors.red.shade400,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                MemoryDateField(
                  value: editDate,
                  onChanged: (d) => setState(() => editDate = d ?? memory.createdAt),
                  accent: primary,
                  showReset: false,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      await _memRepo.update(
                        groupId: _groupId,
                        memoryId: memory.id,
                        title: titleCtrl.text.trim().isNotEmpty
                            ? titleCtrl.text.trim()
                            : '',
                        caption: captionCtrl.text.trim(),
                        locationName: memory.type == MemoryType.location
                            ? locationCtrl.text.trim()
                            : null,
                        latitude: editLat,
                        longitude: editLng,
                        rating: isRatable ? (editRating ?? 0) : null,
                        isAdult: memory.type == MemoryType.photo
                            ? isAdultEdit
                            : null,
                        customDate: editDate,
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      LocaleService.current.saveChanges,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          );
        },
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  ADD MEMORY
  // ═══════════════════════════════════════════════════
  void _showAddMemorySheet() {
    showModalBottomSheet(
      context: context,
      // Без этого лист ограничен ~половиной экрана и нижние пункты
      // (Фильмы/Сериалы) обрезаются под системными кнопками.
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: widget.theme.cardSurface,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
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
                LocaleService.current.addMemoryTitle,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: widget.theme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                LocaleService.current.chooseWhatToShare,
                style: TextStyle(fontSize: 13, color: widget.theme.textMuted),
              ),
              const SizedBox(height: 24),
              _addMemoryOption(
                icon: Icons.perm_media_rounded,
                label: LocaleService.current.photoVideoNote,
                color: const Color(0xFF3B82F6),
                type: MemoryType.photo,
              ),
              _addMemoryOption(
                icon: Icons.link_rounded,
                label: LocaleService.current.videoLink,
                color: const Color(0xFFEC4899),
                type: MemoryType.video,
              ),
              _addMemoryOption(
                icon: Icons.location_on_rounded,
                label: LocaleService.current.location,
                color: const Color(0xFF22C55E),
                type: MemoryType.location,
              ),
              _addMemoryOption(
                icon: Icons.music_note_rounded,
                label: LocaleService.current.music,
                color: const Color(0xFF8B5CF6),
                type: MemoryType.music,
              ),
              _addMemoryOption(
                icon: Icons.menu_book_rounded,
                label: LocaleService.current.books,
                color: const Color(0xFFA855F7),
                type: MemoryType.book,
              ),
              _addMemoryOption(
                icon: Icons.movie_rounded,
                label: LocaleService.current.movies,
                color: const Color(0xFFEF4444),
                type: MemoryType.movie,
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text('💌', style: TextStyle(fontSize: 20)),
                ),
                title: Text(
                  LocaleService.current.timeCapsule,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: widget.theme.textPrimary,
                  ),
                ),
                subtitle: Text(
                  LocaleService.current.capsuleAddSub,
                  style: TextStyle(fontSize: 12, color: widget.theme.textMuted),
                ),
                trailing: Icon(Icons.chevron_right_rounded,
                    color: widget.theme.textMuted),
                onTap: () {
                  Navigator.pop(context);
                  _openTimeCapsule();
                },
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  Widget _addMemoryOption({
    required IconData icon,
    required String label,
    required Color color,
    required MemoryType type,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: widget.theme.textPrimary,
        ),
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: widget.theme.textMuted),
      onTap: () {
        Navigator.pop(context);
        if (type == MemoryType.photo) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MemoryPhotoFormScreen(
                theme: widget.theme,
                onSave: ({
                  required type,
                  required title,
                  required caption,
                  mediaPaths,
                  mediaPath,
                  locationName,
                  latitude,
                  longitude,
                  required isAdult,
                  customDate,
                }) =>
                    _saveNewMemory(
                  type: type,
                  title: title,
                  caption: caption,
                  locationName: locationName ?? '',
                  latitude: latitude,
                  longitude: longitude,
                  mediaPaths: mediaPaths,
                  mediaPath: mediaPath,
                  isAdult: isAdult,
                  customDate: customDate,
                ),
              ),
              settings: const RouteSettings(name: '/memory_photo_form'),
            ),
          );
        } else if (type == MemoryType.music) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MemoryMusicFormScreen(
                theme: widget.theme,
                onFetchMeta: _fetchMusicMeta,
                onSave: ({
                  required musicTitle,
                  required musicArtist,
                  required musicUrl,
                  musicCoverUrl,
                  musicPath,
                  caption = '',
                  customDate,
                }) =>
                    _saveNewMemory(
                  type: MemoryType.music,
                  caption: caption,
                  musicTitle: musicTitle,
                  musicArtist: musicArtist,
                  musicUrl: musicUrl,
                  musicCoverUrl: musicCoverUrl,
                  musicPath: musicPath,
                  customDate: customDate,
                ),
              ),
              settings: const RouteSettings(name: '/memory_music_form'),
            ),
          );
        } else if (type == MemoryType.location) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MemoryLocationFormScreen(
                theme: widget.theme,
                onSave: ({
                  required locationName,
                  latitude,
                  longitude,
                  caption = '',
                  customDate,
                }) =>
                    _saveNewMemory(
                  type: MemoryType.location,
                  caption: caption,
                  locationName: locationName,
                  latitude: latitude,
                  longitude: longitude,
                  customDate: customDate,
                ),
              ),
              settings: const RouteSettings(name: '/memory_location_form'),
            ),
          );
        } else if (type == MemoryType.book) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MemoryBookFormScreen(
                theme: widget.theme,
                onSave: ({
                  required bookTitle,
                  required bookAuthor,
                  bookCoverUrl,
                  bookYear,
                  bookPublisher,
                  bookInfoUrl,
                  rating,
                  required caption,
                  customDate,
                }) =>
                    _saveNewMemory(
                  type: MemoryType.book,
                  title: bookTitle,
                  caption: caption,
                  bookAuthor: bookAuthor,
                  bookCoverUrl: bookCoverUrl,
                  bookYear: bookYear,
                  bookPublisher: bookPublisher,
                  bookInfoUrl: bookInfoUrl,
                  rating: rating,
                  customDate: customDate,
                ),
              ),
              settings: const RouteSettings(name: '/memory_book_form'),
            ),
          );
        } else if (type == MemoryType.movie) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MemoryMovieFormScreen(
                theme: widget.theme,
                onSave: ({
                  required movieTitle,
                  movieOriginalTitle,
                  moviePosterUrl,
                  movieYear,
                  movieKind,
                  movieGenres,
                  movieCountry,
                  movieRatingKp,
                  movieInfoUrl,
                  rating,
                  required caption,
                  customDate,
                }) =>
                    _saveNewMemory(
                  type: MemoryType.movie,
                  title: movieTitle,
                  caption: caption,
                  movieOriginalTitle: movieOriginalTitle,
                  moviePosterUrl: moviePosterUrl,
                  movieYear: movieYear,
                  movieKind: movieKind,
                  movieGenres: movieGenres,
                  movieCountry: movieCountry,
                  movieRatingKp: movieRatingKp,
                  movieInfoUrl: movieInfoUrl,
                  rating: rating,
                  customDate: customDate,
                ),
              ),
              settings: const RouteSettings(name: '/memory_movie_form'),
            ),
          );
        } else {
          // Видео по ссылке (и прочие легаси-типы) — открываем форму сразу
          // на вкладке «По ссылке».
          _showCreateMemoryForm(type, startWithUrl: type == MemoryType.video);
        }
      },
    );
  }

  /// Fetch track metadata from YouTube (stream-based) or Spotify (oEmbed).
  /// Supported music services list for the info dialog
  static const List<Map<String, dynamic>> _supportedMusicServices = [
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
      'name': 'Яндекс Музыка',
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
      'name': 'YouTube Music',

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



  static const List<Map<String, dynamic>> _supportedVideoServices = [
    {
      'name': 'YouTube',
      'supported': true,
      'color': Color(0xFFFF0000),
      'icon': Icons.smart_display_rounded,
    },
    {
      'name': 'Vimeo',
      'supported': true,
      'color': Color(0xFF1AB7EA),
      'icon': Icons.play_circle_rounded,
    },
    {
      'name': 'Dailymotion',
      'supported': true,
      'color': Color(0xFF0066DC),
      'icon': Icons.play_circle_outline_rounded,
    },
    {
      'name': 'Twitch',
      'supported': true,
      'color': Color(0xFF9146FF),
      'icon': Icons.live_tv_rounded,
    },
    {
      'name': 'TikTok',
      'supported': true,
      'color': Color(0xFF010101),
      'icon': Icons.music_video_rounded,
    },
    {
      'name': 'Instagram',
      'supported': true,
      'color': Color(0xFFE1306C),
      'icon': Icons.camera_alt_rounded,
    },
    {
      'name': 'Facebook',
      'supported': true,
      'color': Color(0xFF1877F2),
      'icon': Icons.facebook_rounded,
    },
    {
      'name': 'Twitter / X',
      'supported': true,
      'color': Color(0xFF000000),
      'icon': Icons.alternate_email_rounded,
    },
    {
      'name': 'Rutube',
      'supported': true,
      'color': Color(0xFF1482C8),
      'icon': Icons.play_circle_outline_rounded,
    },
    {
      'name': 'VK Video',
      'supported': true,
      'color': Color(0xFF0077FF),
      'icon': Icons.play_circle_outline_rounded,
    },
  ];

  void _showSupportedVideoServicesDialog() {
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
                      const Color(0xFFFF0000).withOpacity(0.1),
                    ],
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.smart_display_rounded,
                  color: primary,
                  size: 28,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                LocaleService.current.supportedPlatforms,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: widget.theme.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                LocaleService.current.pasteLinkSupported,
                style: TextStyle(fontSize: 12, color: widget.theme.textMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: SingleChildScrollView(
                  child: Column(
                    children: _supportedVideoServices.map((svc) {
                      final svcColor = svc['color'] as Color;
                      final row = Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: svcColor.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: svcColor.withOpacity(0.12),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                svc['icon'] as IconData,
                                size: 20,
                                color: svcColor,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  svc['name'] as String,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: widget.theme.textPrimary,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.check_circle_rounded,
                                size: 20,
                                color: const Color(0xFF22C55E),
                              ),
                            ],
                          ),
                        ),
                      );
                      return row;
                    }).toList(),
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
                    LocaleService.current.gotIt,
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSupportedServicesDialog() {
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
                LocaleService.current.supportedServices,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: widget.theme.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                LocaleService.current.pasteLinkFromService,
                style: TextStyle(fontSize: 12, color: widget.theme.textMuted),
              ),
              const SizedBox(height: 18),
              ..._supportedMusicServices.map(
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
                            style: TextStyle(
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
                    LocaleService.current.gotIt,
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&nbsp;', ' ');
  }

  Future<Map<String, String?>> _fetchMusicMeta(String url) async {
    final lower = url.toLowerCase();

    // ── YouTube / YouTube Music (official oEmbed — no API key required) ──
    if (lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('music.youtube.com')) {
      try {
        final resp = await http.get(
          Uri.parse(
            'https://www.youtube.com/oembed?url=${Uri.encodeComponent(url)}&format=json',
          ),
        );
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

    // ── Spotify ──
    if (lower.contains('spotify.com')) {
      try {
        final oembedResp = await http.get(
          Uri.parse(
            'https://open.spotify.com/oembed?url=${Uri.encodeComponent(url)}',
          ),
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
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            },
          );
          if (pageResp.statusCode == 200) {
            final body = pageResp.body;
            final titleMatch = RegExp(
              r'<title[^>]*>(.+?)</title>',
              caseSensitive: false,
            ).firstMatch(body);
            if (titleMatch != null) {
              final pageTitle = titleMatch.group(1) ?? '';
              final byMatch = RegExp(
                r'(?:song and lyrics|[Aa]lbum|single)\s+by\s+(.+?)\s*\|\s*Spotify',
              ).firstMatch(pageTitle);
              if (byMatch != null) {
                parsedArtist = byMatch.group(1)?.trim();
              }
            }
          }
        } catch (_) {}

        return {'title': parsedTitle, 'artist': parsedArtist, 'cover': cover};
      } catch (e) {
        debugPrint('Spotify meta fetch error: $e');
      }
    }

    // ── Deezer ──
    final isDeezer =
        lower.contains('deezer.com') ||
        lower.contains('deezer.page.link') ||
        lower.contains('link.deezer.com');
    if (isDeezer) {
      try {
        // Resolve short/dynamic links → actual deezer.com/track/ URL
        String resolvedUrl = url;
        final isShortLink =
            lower.contains('deezer.page.link') ||
            lower.contains('link.deezer.com');
        if (isShortLink) {
          try {
            String current = url;
            for (int i = 0; i < 5; i++) {
              final httpClient = HttpClient();
              httpClient.connectionTimeout = const Duration(seconds: 6);
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
        final resolvedLower = resolvedUrl.toLowerCase();

        final trackMatch = RegExp(
          r'deezer\.com/(?:[^/?#]+/)*track/(\d+)',
        ).firstMatch(resolvedLower);
        if (trackMatch != null) {
          final trackId = trackMatch.group(1);
          final apiResp = await http.get(
            Uri.parse('https://api.deezer.com/track/$trackId'),
            headers: {'Accept': 'application/json'},
          );
          if (apiResp.statusCode == 200) {
            final data = json.decode(apiResp.body) as Map<String, dynamic>;
            if (data['error'] == null) {
              return {
                'title': data['title'] as String?,
                'artist':
                    (data['artist'] as Map<String, dynamic>?)?['name']
                        as String?,
                'cover':
                    (data['album'] as Map<String, dynamic>?)?['cover_big']
                        as String?,
              };
            }
          }
        }
        // Fallback to oEmbed (works with both full and resolved URLs)
        final oembedResp = await http.get(
          Uri.parse(
            'https://noembed.com/embed?url=${Uri.encodeComponent(resolvedUrl)}',
          ),
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

    // ── SoundCloud ──
    if (lower.contains('soundcloud.com')) {
      try {
        final oembedResp = await http.get(
          Uri.parse(
            'https://soundcloud.com/oembed?url=${Uri.encodeComponent(url)}&format=json',
          ),
        );
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

    // ── Яндекс Музыка ──
    if (lower.contains('music.yandex.')) {
      try {
        final pageResp = await http.get(
          Uri.parse(url),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        );
        if (pageResp.statusCode == 200) {
          final body = pageResp.body;
          String? title;
          String? artist;
          String? cover;

          // 1. Самый надёжный источник — структурированные данные ld+json
          //    (MusicRecording: name, byArtist.name, thumbnailUrl).
          for (final m in RegExp(
            r'<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>',
            caseSensitive: false,
            dotAll: true,
          ).allMatches(body)) {
            try {
              final ld = json.decode(m.group(1)!.trim());
              if (ld is! Map<String, dynamic>) continue;
              if (ld['name'] is String) title = ld['name'] as String;
              final byArtist = ld['byArtist'];
              if (byArtist is Map && byArtist['name'] is String) {
                artist = byArtist['name'] as String;
              } else if (byArtist is List && byArtist.isNotEmpty) {
                artist = byArtist
                    .whereType<Map>()
                    .map((a) => a['name'])
                    .whereType<String>()
                    .join(', ');
              }
              if (ld['thumbnailUrl'] is String) {
                cover = ld['thumbnailUrl'] as String;
              }
              if (title != null) break;
            } catch (_) {}
          }

          // 2. Fallback на Open Graph / описание.
          String? ogContent(String prop) => RegExp(
                'property="$prop"\\s+content="([^"]*)"',
                caseSensitive: false,
              ).firstMatch(body)?.group(1);

          title ??= ogContent('og:title');
          // og:image отдаёт обложку нужного размера (m1000x1000).
          final ogImage = ogContent('og:image');
          if (ogImage != null && ogImage.isNotEmpty) cover = ogImage;
          // og:description формата "Artist • Трек • 2026" → берём исполнителя.
          if (artist == null || artist.isEmpty) {
            final desc = ogContent('og:description');
            if (desc != null && desc.contains('•')) {
              artist = desc.split('•').first.trim();
            }
          }

          if ((title != null && title.isNotEmpty) ||
              (cover != null && cover.isNotEmpty)) {
            return {
              'title': title != null ? _decodeHtmlEntities(title) : null,
              'artist': artist != null ? _decodeHtmlEntities(artist) : null,
              'cover': cover,
            };
          }
        }
      } catch (e) {
        debugPrint('Yandex Music meta fetch error: $e');
      }
    }

    // ── Apple Music ──
    if (lower.contains('music.apple.com')) {
      try {
        // Extract track ID from ?i= parameter (highest priority)
        final trackIdMatch = RegExp(r'[?&]i=(\d+)').firstMatch(url);
        // Fallback: last numeric segment in the path (album/song ID)
        final pathIdMatch = RegExp(
          r'/(\d+)(?:[?#/]|$)',
        ).allMatches(url).lastOrNull;
        final lookupId = trackIdMatch?.group(1) ?? pathIdMatch?.group(1);
        if (lookupId != null) {
          final resp = await http.get(
            Uri.parse(
              'https://itunes.apple.com/lookup?id=$lookupId&entity=song',
            ),
          );
          if (resp.statusCode == 200) {
            final data = json.decode(resp.body) as Map<String, dynamic>;
            final results = data['results'] as List?;
            if (results != null && results.isNotEmpty) {
              final track =
                  results.firstWhere(
                        (r) => r['wrapperType'] == 'track',
                        orElse: () => results.first,
                      )
                      as Map<String, dynamic>;
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

    // ── VK Музыка ──
    if (lower.contains('vk.com/music') ||
        lower.contains('vk.com/audio') ||
        lower.contains('vk.ru/music')) {
      try {
        final pageResp = await http.get(
          Uri.parse(url),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
          },
        );
        if (pageResp.statusCode == 200) {
          final body = pageResp.body;
          String? ogContent(String prop) => RegExp(
                'property="$prop"\\s+content="([^"]*)"',
                caseSensitive: false,
              ).firstMatch(body)?.group(1);

          final title = ogContent('og:title');
          final image = ogContent('og:image');
          final desc = ogContent('og:description');

          String? artist;
          if (desc != null && desc.contains(' — ')) {
            artist = desc.split(' — ').first.trim();
          }

          if (title != null && title.isNotEmpty) {
            return {
              'title': _decodeHtmlEntities(title),
              'artist': artist != null ? _decodeHtmlEntities(artist) : null,
              'cover': image,
            };
          }
        }
      } catch (e) {
        debugPrint('VK Music meta fetch error: $e');
      }
    }

    // ── Tidal ──
    if (lower.contains('tidal.com')) {
      try {
        // Tidal serves pre-rendered OG tags to social media bots
        final pageResp = await http.get(
          Uri.parse(url),
          headers: {'User-Agent': 'Twitterbot/1.0'},
        );
        if (pageResp.statusCode == 200) {
          final body = pageResp.body;
          final ogTitleMatch = RegExp(
            r'property="og:title"\s+content="([^"]+)"',
            caseSensitive: false,
          ).firstMatch(body);
          final ogImageMatch = RegExp(
            r'property="og:image"\s+content="([^"]+)"',
            caseSensitive: false,
          ).firstMatch(body);
          if (ogTitleMatch != null) {
            // Format: "Artist - Title"
            final raw = _decodeHtmlEntities(ogTitleMatch.group(1) ?? '');
            final sepIdx = raw.indexOf(' - ');
            if (sepIdx != -1) {
              return {
                'title': raw.substring(sepIdx + 3).trim(),
                'artist': raw.substring(0, sepIdx).trim(),
                'cover': ogImageMatch?.group(1),
              };
            }
            return {
              'title': raw.isNotEmpty ? raw : null,
              'artist': null,
              'cover': ogImageMatch?.group(1),
            };
          }
        }
      } catch (e) {
        debugPrint('Tidal meta fetch error: $e');
      }
    }

    // ── Generic fallback — noembed.com (works for many services) ──
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

  void _showCreateMemoryForm(MemoryType type, {bool startWithUrl = false}) {
    final titleCtrl = TextEditingController();
    final captionCtrl = TextEditingController();
    final locationCtrl = TextEditingController();
    final musicTitleCtrl = TextEditingController();
    final musicArtistCtrl = TextEditingController();
    final musicUrlCtrl = TextEditingController();
    final videoLinkCtrl = TextEditingController();

    // Local state for file selections
    List<XFile> selectedPhotos = [];
    XFile? selectedMedia; // video only
    Uint8List? videoThumbnailBytes;
    bool isGeneratingThumbnail = false;
    String? selectedMusicPath;
    double? lat;
    double? lng;
    bool isLoadingLocation = false;
    bool isFetchingMeta = false;
    String? fetchedCoverUrl;
    bool isFetchingVideoMeta = false;
    String? fetchedVideoThumb;
    String? fetchedVideoAuthor;
    bool useVideoUrl = startWithUrl;
    bool isAdultPhoto = false;
    // Дата воспоминания: если задана — пин уезжает в прошлое на ленте.
    DateTime? customDate;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: widget.theme.cardSurface,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              24,
              24,
              24,
              MediaQuery.of(context).viewInsets.bottom + 24,
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
                      color: widget.theme.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        LocaleService.current.newMemory(_typeName(type)),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: widget.theme.textPrimary,
                        ),
                      ),
                    ),
                    if (type == MemoryType.music)
                      GestureDetector(
                        onTap: _showSupportedServicesDialog,
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
                    if (type == MemoryType.video)
                      GestureDetector(
                        onTap: _showSupportedVideoServicesDialog,
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

                // ── Photo/Video picker ──
                if (type == MemoryType.photo) ...[
                  // Thumbnails of already selected photos
                  if (selectedPhotos.isNotEmpty) ...[
                    SizedBox(
                      height: 88,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: selectedPhotos.length + 1,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          if (i == selectedPhotos.length) {
                            return GestureDetector(
                              onTap: () async {
                                try {
                                  final picker = ImagePicker();
                                  final picked = await picker.pickMultiImage(
                                    maxWidth: 1920,
                                    maxHeight: 1920,
                                    imageQuality: 85,
                                  );
                                  if (picked.isNotEmpty) {
                                    if (!context.mounted) return;
                                    setState(() => selectedPhotos.addAll(picked));
                                    if (lat == null) {
                                      _extractExifGps(picked.first.path).then((coords) async {
                                        if (coords == null) return;
                                        String addr = '';
                                        try {
                                          final ps = await placemarkFromCoordinates(coords.$1, coords.$2);
                                          if (ps.isNotEmpty) {
                                            final place = ps.first;
                                            final name = place.name ?? place.subLocality ?? '';
                                            final locality = place.locality ?? '';
                                            addr = name.isNotEmpty ? '$name, $locality' : locality;
                                          }
                                        } catch (_) {}
                                        if (context.mounted) {
                                          setState(() {
                                            lat = coords.$1;
                                            lng = coords.$2;
                                            locationCtrl.text = addr;
                                          });
                                        }
                                      });
                                    }
                                  }
                                } catch (e) {
                                  debugPrint('Pick photos failed: $e');
                                }
                              },
                              child: Container(
                                width: 88,
                                height: 88,
                                decoration: BoxDecoration(
                                  color: widget.theme.surfaceMuted,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: primary.withOpacity(0.35),
                                  ),
                                ),
                                child: Icon(
                                  Icons.add_rounded,
                                  color: primary,
                                  size: 28,
                                ),
                              ),
                            );
                          }
                          return Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(
                                  File(selectedPhotos[i].path),
                                  width: 88,
                                  height: 88,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: GestureDetector(
                                  onTap: () => setState(
                                    () => selectedPhotos.removeAt(i),
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close_rounded,
                                      color: Colors.white,
                                      size: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Empty state — tap to pick photos
                  if (selectedPhotos.isEmpty)
                    GestureDetector(
                      onTap: () async {
                        try {
                          final picker = ImagePicker();
                          final picked = await picker.pickMultiImage(
                            maxWidth: 1920,
                            maxHeight: 1920,
                            imageQuality: 85,
                          );
                          if (picked.isNotEmpty) {
                            if (!context.mounted) return;
                            setState(() => selectedPhotos = picked);
                            if (lat == null) {
                              _extractExifGps(picked.first.path).then((coords) async {
                                if (coords == null) return;
                                String addr = '';
                                try {
                                  final ps = await placemarkFromCoordinates(coords.$1, coords.$2);
                                  if (ps.isNotEmpty) {
                                    final place = ps.first;
                                    final name = place.name ?? place.subLocality ?? '';
                                    final locality = place.locality ?? '';
                                    addr = name.isNotEmpty ? '$name, $locality' : locality;
                                  }
                                } catch (_) {}
                                if (context.mounted) {
                                  setState(() {
                                    lat = coords.$1;
                                    lng = coords.$2;
                                    locationCtrl.text = addr;
                                  });
                                }
                              });
                            }
                          }
                        } catch (e) {
                          debugPrint('Pick photos failed: $e');
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  LocaleService.current.failedSelectPhotos(
                                    e.toString(),
                                  ),
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        height: 100,
                        decoration: BoxDecoration(
                          color: widget.theme.surfaceMuted,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: widget.theme.divider),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.add_photo_alternate_rounded,
                                size: 28,
                                color: widget.theme.textMuted,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                LocaleService.current.tapToSelectPhotos,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: widget.theme.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  // 18+ toggle for photo pins
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => setState(() => isAdultPhoto = !isAdultPhoto),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isAdultPhoto
                            ? Colors.red.shade50
                            : widget.theme.surfaceMuted,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isAdultPhoto
                              ? Colors.red.shade200
                              : widget.theme.divider,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isAdultPhoto
                                ? Icons.lock_rounded
                                : Icons.lock_open_rounded,
                            size: 18,
                            color: isAdultPhoto
                                ? Colors.red.shade400
                                : widget.theme.textMuted,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  LocaleService.current.adultContent,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: isAdultPhoto
                                        ? Colors.red.shade600
                                        : widget.theme.textSecondary,
                                  ),
                                ),
                                Text(
                                  LocaleService.current.photoBlurred,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isAdultPhoto
                                        ? Colors.red.shade400
                                        : widget.theme.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: isAdultPhoto,
                            onChanged: (v) => setState(() => isAdultPhoto = v),
                            activeColor: Colors.red.shade400,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // ── Location for photo ──
                  const SizedBox(height: 8),
                  if (lat != null && lng != null) ...[
                    GestureDetector(
                      onTap: () => setState(() {
                        lat = null;
                        lng = null;
                        locationCtrl.clear();
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                        decoration: BoxDecoration(
                          color: const Color(0xFF22C55E).withOpacity(0.07),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(0xFF22C55E).withOpacity(0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.location_on_rounded,
                              size: 14,
                              color: Color(0xFF22C55E),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                locationCtrl.text.isNotEmpty
                                    ? locationCtrl.text
                                    : '${lat!.toStringAsFixed(5)}, ${lng!.toStringAsFixed(5)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF22C55E),
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Icon(Icons.close_rounded, size: 14, color: widget.theme.textMuted),
                          ],
                        ),
                      ),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: isLoadingLocation
                                ? null
                                : () async {
                                    setState(() => isLoadingLocation = true);
                                    try {
                                      if (!await Geolocator.isLocationServiceEnabled()) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text(LocaleService.current.locationServicesDisabled),
                                            ),
                                          );
                                        }
                                        if (context.mounted) setState(() => isLoadingLocation = false);
                                        return;
                                      }
                                      LocationPermission perm = await Geolocator.checkPermission();
                                      if (perm == LocationPermission.denied) {
                                        perm = await Geolocator.requestPermission();
                                      }
                                      if (perm == LocationPermission.denied ||
                                          perm == LocationPermission.deniedForever) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text(LocaleService.current.locationPermissionDenied),
                                            ),
                                          );
                                        }
                                        if (context.mounted) setState(() => isLoadingLocation = false);
                                        return;
                                      }
                                      final pos = await Geolocator.getCurrentPosition();
                                      lat = pos.latitude;
                                      lng = pos.longitude;
                                      try {
                                        final ps = await placemarkFromCoordinates(lat!, lng!);
                                        if (ps.isNotEmpty) {
                                          final place = ps.first;
                                          final name = place.name ?? place.subLocality ?? '';
                                          final locality = place.locality ?? '';
                                          locationCtrl.text = name.isNotEmpty
                                              ? '$name, $locality'
                                              : locality;
                                        }
                                      } catch (_) {}
                                    } catch (e) {
                                      debugPrint('Get location error: $e');
                                    }
                                    if (context.mounted) setState(() => isLoadingLocation = false);
                                  },
                            icon: isLoadingLocation
                                ? SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: primary,
                                    ),
                                  )
                                : const Icon(Icons.my_location_rounded),
                            label: Text(
                              LocaleService.current.useCurrent,
                              style: const TextStyle(fontSize: 12),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: primary,
                              side: BorderSide(color: primary),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final result = await Navigator.push<Map<String, dynamic>>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => MapPickerScreen(
                                    initialLatitude: lat,
                                    initialLongitude: lng,
                                  ),
                                  settings: const RouteSettings(name: '/map_picker'),
                                ),
                              );
                              if (result != null && context.mounted) {
                                setState(() {
                                  lat = result['latitude'] as double?;
                                  lng = result['longitude'] as double?;
                                  locationCtrl.text = result['address'] as String? ?? '';
                                });
                              }
                            },
                            icon: const Icon(Icons.map_rounded),
                            label: Text(
                              LocaleService.current.pickOnMap,
                              style: const TextStyle(fontSize: 12),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF22C55E),
                              side: const BorderSide(color: Color(0xFF22C55E)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                ] else if (type == MemoryType.video) ...[
                  // ── Toggle: Из галереи / По ссылке ──
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() {
                            useVideoUrl = false;
                            selectedMedia = null;
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: !useVideoUrl
                                  ? primary.withOpacity(0.10)
                                  : widget.theme.surfaceMuted,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: !useVideoUrl
                                    ? primary.withOpacity(0.30)
                                    : widget.theme.divider,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.video_library_rounded,
                                  size: 16,
                                  color: !useVideoUrl
                                      ? primary
                                      : widget.theme.textMuted,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  LocaleService.current.fromGallery,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: !useVideoUrl
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: !useVideoUrl
                                        ? primary
                                        : widget.theme.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() {
                            useVideoUrl = true;
                            selectedMedia = null;
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: useVideoUrl
                                  ? const Color(0xFFEC4899).withOpacity(0.10)
                                  : widget.theme.surfaceMuted,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: useVideoUrl
                                    ? const Color(0xFFEC4899).withOpacity(0.30)
                                    : widget.theme.divider,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.link_rounded,
                                  size: 16,
                                  color: useVideoUrl
                                      ? const Color(0xFFEC4899)
                                      : widget.theme.textMuted,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  LocaleService.current.byLink,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: useVideoUrl
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: useVideoUrl
                                        ? const Color(0xFFEC4899)
                                        : widget.theme.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!useVideoUrl) ...[
                    // ── File picker ──
                    GestureDetector(
                      onTap: () async {
                        try {
                          final picker = ImagePicker();
                          final picked = await picker.pickVideo(
                            source: ImageSource.gallery,
                          );
                          if (picked != null) {
                            if (!context.mounted) return;
                            setState(() {
                              selectedMedia = picked;
                              videoThumbnailBytes = null;
                              isGeneratingThumbnail = true;
                            });
                            try {
                              final thumb =
                                  await VideoCompress.getByteThumbnail(
                                picked.path,
                                quality: 60,
                                position: -1,
                              );
                              if (!context.mounted) return;
                              setState(() {
                                videoThumbnailBytes = thumb;
                                isGeneratingThumbnail = false;
                              });
                            } catch (e) {
                              debugPrint('Thumbnail preview failed: $e');
                              if (context.mounted) setState(() => isGeneratingThumbnail = false);
                            }
                          }
                        } catch (e) {
                          debugPrint('Pick video failed: $e');
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  LocaleService.current.failedSelectVideo(
                                    e.toString(),
                                  ),
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        height: selectedMedia != null ? 200 : 100,
                        clipBehavior: Clip.hardEdge,
                        decoration: BoxDecoration(
                          color: selectedMedia != null
                              ? (widget.theme.isDark
                                  ? widget.theme.surfaceMuted
                                  : Colors.grey.shade900)
                              : widget.theme.surfaceMuted,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: widget.theme.divider),
                          image: videoThumbnailBytes != null
                              ? DecorationImage(
                                  image: MemoryImage(videoThumbnailBytes!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: selectedMedia == null
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.videocam_rounded,
                                      size: 28,
                                      color: widget.theme.textMuted,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      LocaleService.current.tapToSelectVideo,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: widget.theme.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : isGeneratingThumbnail
                                ? const Center(
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      if (videoThumbnailBytes != null)
                                        Container(
                                          color: Colors.black38,
                                        ),
                                      const Center(
                                        child: Icon(
                                          Icons.play_circle_filled_rounded,
                                          color: Colors.white,
                                          size: 48,
                                        ),
                                      ),
                                      Positioned(
                                        top: 8,
                                        right: 8,
                                        child: CircleAvatar(
                                          backgroundColor: Colors.black54,
                                          radius: 16,
                                          child: const Icon(
                                            Icons.check,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ] else ...[
                    // ── URL input ──
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEC4899).withOpacity(0.04),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: const Color(0xFFEC4899).withOpacity(0.18),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFEC4899,
                                  ).withOpacity(0.10),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.link_rounded,
                                  size: 16,
                                  color: Color(0xFFEC4899),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                LocaleService.current.videoLink,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: widget.theme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: videoLinkCtrl,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            onChanged: (_) {},
                            decoration: InputDecoration(
                              hintText: 'YouTube, Vimeo, TikTok, Twitch...',
                              prefixIcon: const Icon(
                                Icons.play_circle_outline_rounded,
                                size: 20,
                              ),
                              suffixIcon: isFetchingVideoMeta
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      icon: const Icon(Icons.search_rounded),
                                      tooltip: LocaleService.current.fetchData,
                                      onPressed: () async {
                                        final url = videoLinkCtrl.text.trim();
                                        if (url.isEmpty) return;
                                        setState(
                                          () => isFetchingVideoMeta = true,
                                        );
                                        final meta = await _fetchVideoMeta(url);
                                        if (!context.mounted) return;
                                        setState(() {
                                          isFetchingVideoMeta = false;
                                          if (meta['title'] != null &&
                                              meta['title']!.isNotEmpty) {
                                            titleCtrl.text = meta['title']!;
                                          }
                                          fetchedVideoThumb = meta['cover'];
                                          fetchedVideoAuthor = meta['author'];
                                          if (meta['author'] != null) {
                                            musicArtistCtrl.text =
                                                meta['author']!;
                                          }
                                        });
                                      },
                                    ),
                              filled: true,
                              fillColor: widget.theme.surfaceMuted,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: widget.theme.divider,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: widget.theme.divider,
                                ),
                              ),
                            ),
                          ),
                          // Preview thumbnail if fetched
                          if (fetchedVideoThumb != null) ...[
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: StorageImage(
                                    imageUrl: fetchedVideoThumb!,
                                    width: 72,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    memCacheWidth: 144,
                                    memCacheHeight: 96,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (titleCtrl.text.isNotEmpty)
                                        Text(
                                          titleCtrl.text,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: widget.theme.textPrimary,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      if (fetchedVideoAuthor != null)
                                        Text(
                                          fetchedVideoAuthor!,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: widget.theme.textMuted,
                                          ),
                                          maxLines: 1,
                                        ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withOpacity(0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.check_circle_rounded,
                                    size: 18,
                                    color: Colors.green,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            LocaleService.current.supportedPlatformsHint,
                            style: TextStyle(
                              fontSize: 11,
                              color: widget.theme.textMuted,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ] else if (type == MemoryType.videoLink) ...[
                  // legacy — existing videoLink memories; form handled via video toggle
                  const SizedBox(height: 0),
                ],
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
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: primary.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.edit_note_rounded,
                              size: 16,
                              color: primary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            LocaleService.current.memoryDetails,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: widget.theme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: titleCtrl,
                        maxLines: 1,
                        style: const TextStyle(fontSize: 15),
                        decoration: InputDecoration(
                          hintText: LocaleService.current.titleOptional,
                          hintStyle: TextStyle(color: widget.theme.textMuted),
                          prefixIcon: Icon(
                            Icons.title_rounded,
                            color: primary,
                            size: 20,
                          ),
                          filled: true,
                          fillColor: widget.theme.cardSurface,
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
                      const SizedBox(height: 10),
                      TextField(
                        controller: captionCtrl,
                        maxLines: 3,
                        style: const TextStyle(fontSize: 15),
                        decoration: InputDecoration(
                          hintText: type == MemoryType.text
                              ? LocaleService.current.writeYourNote
                              : LocaleService.current.descriptionOptional,
                          hintStyle: TextStyle(color: widget.theme.textMuted),
                          prefixIcon: Padding(
                            padding: const EdgeInsets.only(bottom: 40),
                            child: Icon(
                              Icons.notes_rounded,
                              color: primary,
                              size: 20,
                            ),
                          ),
                          filled: true,
                          fillColor: widget.theme.cardSurface,
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
                      // Spoiler toolbar — shown only for text pins
                      if (type == MemoryType.text) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            GestureDetector(
                              onTap: () {
                                final sel = captionCtrl.selection;
                                if (!sel.isValid) return;
                                final text = captionCtrl.text;
                                if (sel.isCollapsed) {
                                  // Insert empty spoiler at cursor
                                  final pos = sel.start;
                                  final newText =
                                      '${text.substring(0, pos)}||||${text.substring(pos)}';
                                  captionCtrl.value = TextEditingValue(
                                    text: newText,
                                    selection: TextSelection.collapsed(
                                      offset: pos + 2,
                                    ),
                                  );
                                } else {
                                  final selected = text.substring(
                                    sel.start,
                                    sel.end,
                                  );
                                  final newText = text.replaceRange(
                                    sel.start,
                                    sel.end,
                                    '||$selected||',
                                  );
                                  captionCtrl.value = TextEditingValue(
                                    text: newText,
                                    selection: TextSelection.collapsed(
                                      offset: sel.start + selected.length + 4,
                                    ),
                                  );
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: primary.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.visibility_off_rounded,
                                      size: 14,
                                      color: primary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      LocaleService.current.spoiler,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              LocaleService.current.selectTextAndPress,
                              style: TextStyle(
                                fontSize: 11,
                                color: widget.theme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                // ── Location fields ──
                if (type == MemoryType.location) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: locationCtrl,
                    decoration: InputDecoration(
                      hintText: LocaleService.current.locationNameHint,
                      prefixIcon: const Icon(Icons.location_on_rounded),
                      filled: true,
                      fillColor: widget.theme.surfaceMuted,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: widget.theme.divider),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: widget.theme.divider),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: isLoadingLocation
                              ? null
                              : () async {
                                  setState(() => isLoadingLocation = true);
                                  try {
                                    bool serviceEnabled =
                                        await Geolocator.isLocationServiceEnabled();
                                    if (!serviceEnabled) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              LocaleService
                                                  .current
                                                  .locationServicesDisabled,
                                            ),
                                          ),
                                        );
                                      }
                                      if (context.mounted) setState(() => isLoadingLocation = false);
                                      return;
                                    }

                                    LocationPermission permission =
                                        await Geolocator.checkPermission();
                                    if (permission ==
                                        LocationPermission.denied) {
                                      permission =
                                          await Geolocator.requestPermission();
                                    }
                                    if (permission ==
                                            LocationPermission.denied ||
                                        permission ==
                                            LocationPermission.deniedForever) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              LocaleService
                                                  .current
                                                  .locationPermissionDenied,
                                            ),
                                          ),
                                        );
                                      }
                                      if (context.mounted) setState(() => isLoadingLocation = false);
                                      return;
                                    }

                                    final position =
                                        await Geolocator.getCurrentPosition();
                                    lat = position.latitude;
                                    lng = position.longitude;

                                    // Try to get address
                                    try {
                                      final placemarks =
                                          await placemarkFromCoordinates(
                                            lat!,
                                            lng!,
                                          );
                                      if (placemarks.isNotEmpty) {
                                        final place = placemarks.first;
                                        final name =
                                            place.name ??
                                            place.subLocality ??
                                            '';
                                        final locality = place.locality ?? '';
                                        locationCtrl.text = name.isNotEmpty
                                            ? '$name, $locality'
                                            : locality;
                                      }
                                    } catch (e) {
                                      debugPrint('Geocoding failed: $e');
                                    }
                                  } catch (e) {
                                    debugPrint('Get location failed: $e');
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            LocaleService
                                                .current
                                                .failedGetLocation,
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                  setState(() => isLoadingLocation = false);
                                },
                          icon: isLoadingLocation
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: primary,
                                  ),
                                )
                              : const Icon(Icons.my_location_rounded),
                          label: Text(
                            lat != null && lng != null
                                ? LocaleService.current.locationSet
                                : LocaleService.current.useCurrent,
                            style: const TextStyle(fontSize: 12),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: primary,
                            side: BorderSide(color: primary),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final result = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => MapPickerScreen(
                                  initialLatitude: lat,
                                  initialLongitude: lng,
                                ),
                                settings: const RouteSettings(name: '/map_picker'),
                              ),
                            );

                            if (result != null && mounted) {
                              setState(() {
                                lat = result['latitude'];
                                lng = result['longitude'];
                                locationCtrl.text = result['address'] ?? '';
                              });
                            }
                          },
                          icon: const Icon(Icons.map_rounded),
                          label: Text(
                            LocaleService.current.pickOnMap,
                            style: const TextStyle(fontSize: 12),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF22C55E),
                            side: const BorderSide(color: Color(0xFF22C55E)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],

                // ── Music fields ──
                if (type == MemoryType.music) ...[
                  // ─── Section: Song Details ───
                  const SizedBox(height: 8),
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
                            Container(
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
                            const SizedBox(width: 10),
                            Text(
                              LocaleService.current.songDetails,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: widget.theme.textPrimary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: musicTitleCtrl,
                          style: const TextStyle(fontSize: 15),
                          decoration: InputDecoration(
                            hintText: LocaleService.current.songName,
                            hintStyle: TextStyle(color: widget.theme.textMuted),
                            prefixIcon: Icon(
                              Icons.audiotrack_rounded,
                              color: primary,
                              size: 20,
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
                        const SizedBox(height: 10),
                        TextField(
                          controller: musicArtistCtrl,
                          style: const TextStyle(fontSize: 15),
                          decoration: InputDecoration(
                            hintText:
                                LocaleService.current.artistsCommaSeparated,
                            helperText: LocaleService.current.egArtists,
                            helperStyle: TextStyle(
                              fontSize: 11,
                              color: widget.theme.textMuted,
                            ),
                            hintStyle: TextStyle(color: widget.theme.textMuted),
                            prefixIcon: Icon(
                              Icons.person_rounded,
                              color: primary,
                              size: 20,
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

                  // ─── Divider ───
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Divider(
                            color: widget.theme.divider,
                            height: 1,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: primary.withOpacity(0.06),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.link_rounded,
                                  size: 14,
                                  color: primary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  LocaleService.current.source,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: Divider(
                            color: widget.theme.divider,
                            height: 1,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ─── Section: Link / Upload ───
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
                            Expanded(
                              child: Text(
                                LocaleService.current.streamingLink,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: widget.theme.textPrimary,
                                ),
                              ),
                            ),
                            if (fetchedCoverUrl != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF22C55E,
                                  ).withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      size: 12,
                                      color: Color(0xFF22C55E),
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      LocaleService.current.fetched,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF22C55E),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: musicUrlCtrl,
                          style: const TextStyle(fontSize: 14),
                          onSubmitted: (v) async {
                            final url = v.trim();
                            if (url.isEmpty) return;
                            setState(() => isFetchingMeta = true);
                            final meta = await _fetchMusicMeta(url);
                            if (!context.mounted) return;
                            setState(() {
                              isFetchingMeta = false;
                              if ((meta['title']?.isNotEmpty ?? false) &&
                                  musicTitleCtrl.text.isEmpty) {
                                musicTitleCtrl.text = meta['title']!;
                              }
                              if ((meta['artist']?.isNotEmpty ?? false) &&
                                  musicArtistCtrl.text.isEmpty) {
                                musicArtistCtrl.text = meta['artist']!;
                              }
                              if (meta['cover']?.isNotEmpty ?? false) {
                                fetchedCoverUrl = meta['cover'];
                              }
                            });
                          },
                          decoration: InputDecoration(
                            hintText:
                                LocaleService.current.pasteLinkFromService,
                            hintStyle: TextStyle(
                              color: widget.theme.textMuted,
                              fontSize: 13,
                            ),
                            prefixIcon: Icon(
                              Icons.link_rounded,
                              color: primary,
                              size: 20,
                            ),
                            suffixIcon: isFetchingMeta
                                ? Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: widget.theme.textMuted,
                                      ),
                                    ),
                                  )
                                : IconButton(
                                    icon: Icon(
                                      Icons.manage_search_rounded,
                                      color: primary,
                                    ),
                                    tooltip:
                                        LocaleService.current.autoFetchSongInfo,
                                    onPressed: () async {
                                      final url = musicUrlCtrl.text.trim();
                                      if (url.isEmpty) return;
                                      setState(() => isFetchingMeta = true);
                                      final meta = await _fetchMusicMeta(url);
                                      if (!context.mounted) return;
                                      setState(() {
                                        isFetchingMeta = false;
                                        if ((meta['title']?.isNotEmpty ??
                                                false) &&
                                            musicTitleCtrl.text.isEmpty) {
                                          musicTitleCtrl.text = meta['title']!;
                                        }
                                        if ((meta['artist']?.isNotEmpty ??
                                                false) &&
                                            musicArtistCtrl.text.isEmpty) {
                                          musicArtistCtrl.text =
                                              meta['artist']!;
                                        }
                                        if (meta['cover']?.isNotEmpty ??
                                            false) {
                                          fetchedCoverUrl = meta['cover'];
                                        }
                                      });
                                    },
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
                        const SizedBox(height: 12),
                        // ── OR divider ──
                        Row(
                          children: [
                            Expanded(
                              child: Divider(
                                color: widget.theme.divider,
                                height: 1,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Text(
                                LocaleService.current.orDivider,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: widget.theme.textMuted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(
                                color: widget.theme.divider,
                                height: 1,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // ── File picker ──
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final result = await FilePicker.platform
                                  .pickFiles(type: FileType.audio);
                              if (result != null && result.files.isNotEmpty) {
                                if (!context.mounted) return;
                                setState(
                                  () => selectedMusicPath =
                                      result.files.first.path,
                                );
                                if (musicTitleCtrl.text.isEmpty) {
                                  musicTitleCtrl.text = result.files.first.name
                                      .split('.')
                                      .first;
                                }
                              }
                            },
                            icon: Icon(
                              selectedMusicPath != null
                                  ? Icons.check_circle_rounded
                                  : Icons.upload_file_rounded,
                              size: 18,
                            ),
                            label: Text(
                              selectedMusicPath != null
                                  ? '${LocaleService.current.fileSelected} ✓'
                                  : LocaleService.current.pickAudioFromDevice,
                              style: const TextStyle(fontSize: 13),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: selectedMusicPath != null
                                  ? const Color(0xFF22C55E)
                                  : primary,
                              side: BorderSide(
                                color: selectedMusicPath != null
                                    ? const Color(0xFF22C55E)
                                    : primary,
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 16),
                MemoryDateField(
                  value: customDate,
                  onChanged: (d) => setState(() => customDate = d),
                  accent: primary,
                ),

                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      // When video form is in "by link" mode — treat as videoLink
                      final effectiveType =
                          (type == MemoryType.video && useVideoUrl)
                          ? MemoryType.videoLink
                          : type;
                      await _saveNewMemory(
                        type: effectiveType,
                        title: titleCtrl.text.trim(),
                        caption: captionCtrl.text.trim(),
                        locationName: locationCtrl.text.trim(),
                        latitude: lat,
                        longitude: lng,
                        musicTitle: musicTitleCtrl.text.trim(),
                        musicArtist: musicArtistCtrl.text.trim(),
                        musicUrl: musicUrlCtrl.text.trim(),
                        musicCoverUrl: fetchedCoverUrl,
                        mediaPaths: selectedPhotos.isNotEmpty
                            ? selectedPhotos.map((f) => f.path).toList()
                            : null,
                        mediaPath: selectedMedia?.path,
                        musicPath: selectedMusicPath,
                        // videoLink-specific
                        videoLinkUrl: effectiveType == MemoryType.videoLink
                            ? videoLinkCtrl.text.trim()
                            : null,
                        videoLinkThumb: fetchedVideoThumb,
                        videoLinkAuthor: musicArtistCtrl.text.trim(),
                        isAdult: isAdultPhoto,
                        customDate: customDate,
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 8,
                      shadowColor: primary.withOpacity(0.3),
                    ),
                    child: Text(
                      LocaleService.current.addMemoryTitle,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _typeName(MemoryType type) {
    final s = LocaleService.current;
    switch (type) {
      case MemoryType.photo:
        return s.photo;
      case MemoryType.video:
        return s.video;
      case MemoryType.videoLink:
        return s.video;
      case MemoryType.location:
        return s.location;
      case MemoryType.music:
        return s.music;
      case MemoryType.text:
        return s.note;
      case MemoryType.book:
        return s.books;
      case MemoryType.movie:
        return s.movies;
    }
  }

  Future<void> _saveNewMemory({
    required MemoryType type,
    String title = '',
    String caption = '',
    String locationName = '',
    double? latitude,
    double? longitude,
    String musicTitle = '',
    String musicArtist = '',
    String musicUrl = '',
    String? musicCoverUrl,
    List<String>? mediaPaths, // multiple photos
    String? mediaPath, // single video
    String? musicPath,
    // videoLink
    String? videoLinkUrl,
    String? videoLinkThumb,
    String? videoLinkAuthor,
    // book
    String? bookAuthor,
    String? bookCoverUrl,
    String? bookYear,
    String? bookPublisher,
    String? bookInfoUrl,
    // movie / series
    String? movieOriginalTitle,
    String? moviePosterUrl,
    String? movieYear,
    String? movieKind,
    String? movieGenres,
    String? movieCountry,
    String? movieRatingKp,
    String? movieInfoUrl,
    // личная оценка 1–10 (книги/фильмы)
    int? rating,
    bool isAdult = false,
    // Если задано — момент «в памяти» будет именно этой даты, а не «сейчас».
    DateTime? customDate,
  }) async {
    if (_myUid == null || _groupId.isEmpty) return;

    // Check rate limit before uploading to avoid wasting bandwidth
    try {
      await RateLimiterService().checkMemory();
    } on RateLimitException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
      }
      return;
    }

    // Show loading indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Text(LocaleService.current.uploadingMemory),
            ],
          ),
          duration: const Duration(seconds: 30),
        ),
      );
    }

    String? uploadedImageUrl;
    List<String> uploadedImageUrls = [];
    String? uploadedVideoUrl;
    String? uploadedMusicUrl;

    try {
      // Upload multiple photos if selected
      if (type == MemoryType.photo &&
          mediaPaths != null &&
          mediaPaths.isNotEmpty) {
        for (final path in mediaPaths) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final ext = path.split('.').last;
          final fileName = 'memory_$timestamp.$ext';
          final destination = 'memories/$_groupId/$fileName';
          final url = await MediaService().uploadFile(path, destination);
          if (url != null) uploadedImageUrls.add(url);
        }
        if (uploadedImageUrls.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(LocaleService.current.failedUploadPhotos),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return;
        }
        uploadedImageUrl = uploadedImageUrls.first;
      }

      // Upload video if selected (even when type==photo: unified picker may
      // return a photo+video mix, and we don't want to silently drop the video)
      if (mediaPath != null) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final ext = mediaPath.split('.').last;
        final fileName = 'memory_$timestamp.$ext';
        final destination = 'memories/$_groupId/$fileName';

        // Generate and upload thumbnail so the preview card has an image.
        // Таймаут обязателен: VideoCompress.getByteThumbnail на части устройств
        // виснет и future не возвращается → сохранение воспоминания крутится
        // вечно. По таймауту возвращаем null → создаём воспоминание без превью
        // (тайл покажет заглушку с кнопкой play), но НЕ блокируем сохранение.
        try {
          final thumbBytes = await VideoCompress.getByteThumbnail(
            mediaPath,
            quality: 80,
            position: -1,
          ).timeout(const Duration(seconds: 30), onTimeout: () => null);
          if (thumbBytes != null) {
            final tempDir = await getTemporaryDirectory();
            final thumbFile =
                File('${tempDir.path}/thumb_$timestamp.jpg');
            await thumbFile.writeAsBytes(thumbBytes);
            final thumbUrl = await MediaService().uploadFile(
              thumbFile.path,
              'memories/$_groupId/thumb_$timestamp.jpg',
            );
            thumbFile.delete().catchError((_) => thumbFile);
            if (thumbUrl != null) uploadedImageUrl = thumbUrl;
          }
        } catch (e) {
          debugPrint('Video thumbnail upload failed: $e');
          unawaited(
            Sentry.captureException(e, withScope: (s) {
              s.setExtra('reason', 'video thumbnail generation/upload failed');
              s.level = SentryLevel.warning;
            }),
          );
        }

        final url = await MediaService().uploadFile(mediaPath, destination);
        if (url != null) {
          uploadedVideoUrl = url;
        } else {
          // Загрузка видео не удалась (таймаут сети / отказ Storage / RLS).
          // Фиксируем в Crashlytics, чтобы видеть реальную причину по жалобам.
          unawaited(
            Sentry.captureException(
              'video upload returned null (memories/$_groupId)',
              withScope: (s) {
                s.setExtra('reason', 'memory video upload failed');
                s.level = SentryLevel.warning;
              },
            ),
          );
          if (mounted) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(LocaleService.current.failedUploadVideo),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return;
        }
      }

      // Upload music file if selected
      if (musicPath != null) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final ext = musicPath.split('.').last;
        final fileName = 'music_$timestamp.$ext';
        final destination = 'music/$_groupId/$fileName';

        uploadedMusicUrl = await MediaService().uploadFile(musicPath, destination);
      }

      // Use provided musicUrl if no file uploaded
      final finalMusicUrl =
          uploadedMusicUrl ?? (musicUrl.isNotEmpty ? musicUrl : null);

      // For videoLink type — resolve fields
      final finalVideoUrl = type == MemoryType.videoLink
          ? (videoLinkUrl?.isNotEmpty == true ? videoLinkUrl : null)
          : uploadedVideoUrl;
      final finalImageUrl = type == MemoryType.videoLink
          ? videoLinkThumb
          : uploadedImageUrl;
      final finalMusicArtist = type == MemoryType.videoLink
          ? (videoLinkAuthor?.isNotEmpty == true ? videoLinkAuthor : null)
          : (musicArtist.isNotEmpty ? musicArtist : null);

      await _memRepo.add(
        groupId: _groupId,
        authorName: widget.userData?.displayName ?? '',
        authorAvatar: widget.userData?.avatarUrl ?? '',
        type: type,
        title: title.isNotEmpty ? title : null,
        caption: caption.isNotEmpty ? caption : null,
        locationName: locationName.isNotEmpty ? locationName : null,
        latitude: latitude,
        longitude: longitude,
        musicTitle: musicTitle.isNotEmpty ? musicTitle : null,
        musicArtist: finalMusicArtist,
        musicUrl: finalMusicUrl,
        musicCoverUrl: musicCoverUrl,
        imageUrl: finalImageUrl,
        imageUrls: uploadedImageUrls.isNotEmpty ? uploadedImageUrls : null,
        videoUrl: finalVideoUrl,
        bookAuthor: bookAuthor,
        bookCoverUrl: bookCoverUrl,
        bookYear: bookYear,
        bookPublisher: bookPublisher,
        bookInfoUrl: bookInfoUrl,
        movieOriginalTitle: movieOriginalTitle,
        moviePosterUrl: moviePosterUrl,
        movieYear: movieYear,
        movieKind: movieKind,
        movieGenres: movieGenres,
        movieCountry: movieCountry,
        movieRatingKp: movieRatingKp,
        movieInfoUrl: movieInfoUrl,
        rating: rating,
        isAdult: isAdult,
        customDate: customDate,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.memoryAddedSuccess),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
        _tryClaimMemoryReward();
      }
    } catch (e) {
      debugPrint('Save memory failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LocaleService.current.failedAddMemory(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // =============================================
  // HELPER METHODS: Location, Distance, Time, Avatar
  // =============================================

  /// Fetch user location for distance display on photo cards
  /// Extract GPS (lat, lng) from a photo file's EXIF data.
  /// Returns null if no GPS tag found or parsing fails.
  static Future<(double, double)?> _extractExifGps(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final tags = await readExifFromBytes(bytes);
      if (!tags.containsKey('GPS GPSLatitude') ||
          !tags.containsKey('GPS GPSLongitude')) return null;
      final latRef = tags['GPS GPSLatitudeRef']?.printable.trim() ?? 'N';
      final lngRef = tags['GPS GPSLongitudeRef']?.printable.trim() ?? 'E';
      double? toDeg(String raw) {
        final clean = raw.replaceAll(RegExp(r'[\[\]\s]'), '');
        final parts = clean.split(',');
        if (parts.length < 3) return null;
        double p(String s) {
          if (s.contains('/')) {
            final f = s.split('/');
            final n = double.tryParse(f[0]);
            final d = double.tryParse(f[1]);
            if (n == null || d == null || d == 0) return 0;
            return n / d;
          }
          return double.tryParse(s) ?? 0;
        }
        return p(parts[0]) + p(parts[1]) / 60.0 + p(parts[2]) / 3600.0;
      }
      final latVal = toDeg(tags['GPS GPSLatitude']!.printable);
      final lngVal = toDeg(tags['GPS GPSLongitude']!.printable);
      if (latVal == null || lngVal == null || (latVal == 0.0 && lngVal == 0.0)) {
        return null;
      }
      return (latRef == 'S' ? -latVal : latVal, lngRef == 'W' ? -lngVal : lngVal);
    } catch (e) {
      debugPrint('EXIF GPS extraction failed: $e');
      return null;
    }
  }

  Future<void> _fetchUserLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) return;
      if (perm != LocationPermission.always &&
          perm != LocationPermission.whileInUse) { return; }

      // Use last known position instantly so pills show right away
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted) {
        setState(() {
          _userLat = last.latitude;
          _userLng = last.longitude;
        });
      }

      // Then get a fresh fix and update
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (mounted) {
        setState(() {
          _userLat = pos.latitude;
          _userLng = pos.longitude;
        });
      }
    } catch (e) {
      debugPrint('Failed to get user location: $e');
    }
  }

  /// Calculate distance in km between user and a point
  String _distanceKm(double lat, double lng) {
    if (_userLat == null || _userLng == null) return '';
    final d = Geolocator.distanceBetween(_userLat!, _userLng!, lat, lng);
    if (d < 1000) return '${d.round()}m';
    return '${(d / 1000).toStringAsFixed(1)}km';
  }

  /// Color for distance pill based on proximity
  Color _distanceColor(double lat, double lng) {
    if (_userLat == null || _userLng == null) return widget.theme.textMuted;
    final km = Geolocator.distanceBetween(_userLat!, _userLng!, lat, lng) / 1000;
    if (km < 1) return const Color(0xFF22C55E);
    if (km < 10) return const Color(0xFF16A34A);
    if (km < 50) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  /// Colored location distance pill shown on photo/video tiles.
  /// Shows distance + color when user GPS is known; falls back to
  /// location name (grey) when user GPS is unavailable.
  Widget _locationDistancePill(Memory memory) {
    final hasCoords = memory.latitude != null && memory.longitude != null;
    final hasName = memory.locationName?.isNotEmpty == true;
    if (!hasCoords && !hasName) return const SizedBox.shrink();

    Widget pill;
    if (hasCoords) {
      final dist = _distanceKm(memory.latitude!, memory.longitude!);
      if (dist.isNotEmpty) {
        // User GPS known → colored distance pill
        final color = _distanceColor(memory.latitude!, memory.longitude!);
        pill = Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.35), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.location_on_rounded, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                dist,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        );
      } else {
        // No user GPS → grey pin icon only (no name on closed tiles)
        pill = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: widget.theme.surfaceMuted,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: widget.theme.divider, width: 1),
          ),
          child: Icon(Icons.location_on_rounded, size: 12, color: widget.theme.textMuted),
        );
      }
    } else {
      // locationName only, no coords — grey pin icon
      pill = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: widget.theme.surfaceMuted,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: widget.theme.divider, width: 1),
        ),
        child: Icon(Icons.location_on_rounded, size: 12, color: widget.theme.textMuted),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: Row(children: [pill]),
    );
  }

  /// Open MapPickerScreen to set/change location on any memory type
  Future<void> _setLocationOnMemory(Memory memory) async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => MapPickerScreen(
          initialLatitude: memory.latitude,
          initialLongitude: memory.longitude,
        ),
        settings: const RouteSettings(name: '/map_picker'),
      ),
    );
    if (result == null) return;
    final lat = result['latitude'] as double?;
    final lng = result['longitude'] as double?;
    final address = result['address'] as String?;
    if (lat == null || lng == null) return;
    await _memRepo.update(
      groupId: _groupId,
      memoryId: memory.id,
      latitude: lat,
      longitude: lng,
      locationName: memory.locationName?.isNotEmpty == true
          ? memory.locationName
          : address,
    );
  }

  // ── Global gallery helpers ─────────────────────────────────────────────────

  /// Flattens all photo/video memories into a single ordered list for cross-pin swiping.
  List<GalleryItem> get _allGalleryItems {
    final items = <GalleryItem>[];
    final sorted = [..._memories]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final m in sorted) {
      // Не светим фото запечатанной капсулы (до открытия) и секретных до PIN.
      if (m.sealedNow()) continue;
      if (m.isSecret && !_secretUnlocked) continue;
      if (m.type == MemoryType.photo) {
        final urls = <String>[
          if (m.imageUrls?.isNotEmpty == true)
            ...m.imageUrls!
          else if (m.imageUrl?.isNotEmpty == true)
            m.imageUrl!,
        ];
        for (final url in urls) {
          items.add(GalleryItem(url: url, memoryId: m.id, caption: m.caption));
        }
        // Смешанный пин: фото + видео — показываем видео отдельным
        // воспроизводимым элементом (превью = thumbnail видео в imageUrl).
        if (m.videoUrl?.isNotEmpty == true) {
          items.add(GalleryItem(
            url: m.imageUrl?.isNotEmpty == true ? m.imageUrl! : m.videoUrl!,
            videoUrl: m.videoUrl,
            memoryId: m.id,
            caption: m.caption,
          ));
        }
      } else if (m.type == MemoryType.video &&
          m.videoUrl?.isNotEmpty == true) {
        items.add(GalleryItem(
          url: m.imageUrl?.isNotEmpty == true ? m.imageUrl! : m.videoUrl!,
          videoUrl: m.videoUrl,
          memoryId: m.id,
          caption: m.caption,
        ));
      }
    }
    return items;
  }

  void _openPhotoGalleryScreen() async {
    final items = _allGalleryItems;
    if (items.isEmpty) return;
    final memoryId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _PhotoGalleryScreen(items: items, primary: primary),
        settings: const RouteSettings(name: '/photo_gallery'),
      ),
    );
    if (memoryId != null && mounted) {
      final mem = _memories.firstWhere(
        (m) => m.id == memoryId,
        orElse: () => _memories.first,
      );
      _showMemoryDetail(mem);
    }
  }

  /// Format time ago from DateTime using localized strings
  String _formatTimeAgo(DateTime dt) {
    final s = LocaleService.current;
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return s.justNow;
    if (diff.inMinutes < 60) return s.minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return s.hoursAgo(diff.inHours);
    if (diff.inDays < 30) return s.daysAgo(diff.inDays);
    return '${dt.day}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
  }

  /// Open fullscreen cross-pin gallery, returns memoryId if "go to pin" tapped.
  Future<String?> _openFullscreenGallery(
    BuildContext ctx,
    List<GalleryItem> items,
    int initialIndex,
  ) {
    return Navigator.of(ctx).push<String>(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) =>
            FullscreenGallery(items: items, initialIndex: initialIndex),
      ),
    );
  }

  /// Open location in external maps app
  Future<void> _openLocationInMaps(
    double lat,
    double lng,
    String? label,
  ) async {
    final query = label != null ? Uri.encodeComponent(label) : '$lat,$lng';
    final geoUri = Uri.parse('geo:$lat,$lng?q=$lat,$lng($query)');
    final appleMapsUri = Uri.parse(
      'https://maps.apple.com/?q=$query&ll=$lat,$lng',
    );

    if (await canLaunchUrl(geoUri)) {
      await launchUrl(geoUri);
    } else if (await canLaunchUrl(appleMapsUri)) {
      await launchUrl(appleMapsUri, mode: LaunchMode.externalApplication);
    } else {
      final webUri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
      );
      await launchUrl(webUri, mode: LaunchMode.externalApplication);
    }
  }

  /// Avatar fallback with initial letter
  Widget _avatarFallback(String? name) {
    final initial = (name ?? '').firstGraphemeUpper('?');
    return Container(
      color: primary.withOpacity(0.15),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: primary,
          ),
        ),
      ),
    );
  }
}

