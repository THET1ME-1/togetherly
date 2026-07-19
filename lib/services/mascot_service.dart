import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/mascot.dart';
import 'catalog_service.dart';
import 'media_service.dart';
import 'home_widget_service.dart';
import 'level_service.dart';
import 'mascot_repository.dart';

/// Manages the mascot gallery and group streak for one group.
/// Bind to a group via [bindToGroup] when the user is paired.
///
/// Миграция Firebase→PocketBase (§3): галерея и состояние маскота читаются/пишутся
/// через [MascotRepository] (live SSE PB, чтения бесплатны). `FirebaseService`
/// остаётся ТОЛЬКО под загрузку картинок маскотов в Storage — медиа переезжает в
/// §4 (как и медиа воспоминаний); удаление старых файлов тоже отложено на §4.
class MascotService extends ChangeNotifier {
  MascotService() {
    // Каталожные маскоты приезжают асинхронно — обновляем галерею/виджет, когда
    // удалённый каталог загрузился.
    CatalogService.instance.addListener(_onCatalogChanged);
  }

  final MascotRepository _repo = MascotRepository();

  /// Только для загрузки картинок маскотов (PocketBase media) через [MediaService].
  /// Данные/состояние уже на PB через [_repo].
  final MediaService _fb = MediaService();

  void _onCatalogChanged() => notifyListeners();

  String _groupId = '';
  int _bindGeneration = 0;
  StreamSubscription? _mascotsSub;
  StreamSubscription? _groupStateSub;
  // Откладывает «галерея пуста → засеять дефолты», чтобы не сработать на холодной
  // пустой эмиссии кэша до сетевой загрузки (иначе затирали бы активного маскота).
  Timer? _emptySeedTimer;

  List<Mascot> _mascots = [];
  GroupMascotState _state = const GroupMascotState();
  bool _isLoading = false;

  /// Галерея группы (PB) + каталожные маскоты (рендер-онли, поверх).
  /// Дедуп по id: собственная копия группы побеждает (если id совпал).
  List<Mascot> get mascots {
    final catalog = CatalogService.instance.mascots;
    if (catalog.isEmpty) return _mascots;
    final ids = _mascots.map((m) => m.id).toSet();
    return [..._mascots, ...catalog.where((c) => !ids.contains(c.id))];
  }

  GroupMascotState get state => _state;
  bool get isLoading => _isLoading;

  bool get hasActiveMascot => _state.activeMascotId != null;

  /// Лимит 20 — только на СВОИ (рисованные) маскоты; каталог не считается.
  int get mascotCount => _mascots.length;
  static const int maxMascots = 20;
  bool get isGalleryFull => mascotCount >= maxMascots;

  Mascot? get activeMascot {
    final id = _state.activeMascotId;
    if (id == null) return null;
    for (final m in mascots) {
      if (m.id == id) return m;
    }
    return null;
  }

  // ── Bind / unbind ──────────────────────────────────────────────────────────

  void bindToGroup(String groupId) {
    if (_groupId == groupId) return;
    _bindGeneration++;
    _groupId = groupId;
    _mascotsSub?.cancel();
    _groupStateSub?.cancel();
    _mascots = [];
    _state = const GroupMascotState();
    _isLoading = true;
    notifyListeners();

    LevelService.instance.bind(groupId);

    _groupStateSub = _repo.watchState(groupId).listen((state) {
      _state = state;
      LevelService.instance.setXp(state.xp);
      _syncStreakWidget();
      notifyListeners();
    }, onError: (e) => debugPrint('[MascotService] group state error: $e'));

    _mascotsSub = _repo.watchGallery(groupId).listen(
          _onMascotsUpdate,
          onError: (e) => debugPrint('[MascotService] mascots error: $e'),
        );
  }

  void unbind() {
    _bindGeneration++;
    _mascotsSub?.cancel();
    _groupStateSub?.cancel();
    _emptySeedTimer?.cancel();
    _emptySeedTimer = null;
    LevelService.instance.unbind();
    _groupId = '';
    _mascots = [];
    _state = const GroupMascotState();
    _isLoading = false;
    notifyListeners();
  }

  // IDs of the old SVG system mascots that need to be replaced.
  static const _kOldDefaultIds = {
    'default_boy_happy',
    'default_boy_sad',
    'default_boy_very_sad',
    'default_girl_happy',
    'default_girl_sad',
    'default_girl_very_sad',
  };

  void _onMascotsUpdate(List<Mascot> mascots) {
    _mascots = mascots;

    // Засеваем дефолты ТОЛЬКО если галерея РЕАЛЬНО пуста — но НЕ по первой
    // пустой эмиссии. `_watchCached` на onListen сразу отдаёт локальный кэш
    // (часто пустой []) ДО сетевой загрузки галереи. Если среагировать сразу —
    // `_seedDefaults` → `setActive(defaults.first)` ЗАТИРАЕТ выбранного
    // пользователем маскота дефолтным (баг «активный маскот сбрасывается на
    // default_boy на каждом старте»). Поэтому откладываем: если за паузу
    // подгрузится непустая галерея — отложенный seed отменяется.
    if (_mascots.isEmpty && _groupId.isNotEmpty) {
      final boundGroupId = _groupId;
      final gen = _bindGeneration;
      _emptySeedTimer?.cancel();
      _emptySeedTimer = Timer(const Duration(seconds: 5), () {
        if (_groupId != boundGroupId || gen != _bindGeneration) return;
        if (_mascots.isEmpty) _seedDefaults(); // всё ещё пусто после загрузки
      });
      return;
    }
    // Галерея непуста — отменяем отложенный seed (данные подгрузились).
    _emptySeedTimer?.cancel();
    _emptySeedTimer = null;

    // One-time migration: replace the old 6 SVG defaults with the new 2.
    final oldOnes = _mascots
        .where((m) => _kOldDefaultIds.contains(m.id))
        .toList();
    if (oldOnes.isNotEmpty) {
      _migrateOldDefaults(oldOnes);
      return; // wait for the PB stream to re-fire after writes
    }

    _isLoading = false;
    // Record streak (stored per active mascot) may have just loaded — refresh
    // the home-screen «Огонёк» widget so its «Рекорд: N» подпись is correct.
    _syncStreakWidget();
    notifyListeners();
  }

  /// Текущая серия активного маскота (для UI — превью виджета и т.п.).
  int get activeStreak => _state.activeStreak;

  /// Принудительно пере-синхронизировать «Огонёк» с актуальной серией.
  /// Нужно, например, при открытии экрана виджетов, чтобы нативный виджет на
  /// рабочем столе не показывал застрявшее старое значение.
  void resyncStreakWidget() => _syncStreakWidget();

  /// Pushes the ACTIVE mascot's streak to the native «Огонёк» home widget
  /// (серия теперь per-mascot, а не общая парная).
  void _syncStreakWidget() {
    final streak = _state.activeStreak;
    final record = activeMascot?.recordStreak ?? 0;
    HomeWidgetService.instance.syncStreak(
      streakDays: streak,
      recordStreak: record > streak ? record : streak,
      lastOpenedDate: _state.streakLastOpenedDate ?? '',
    );
  }

  Future<void> _migrateOldDefaults(List<Mascot> oldOnes) async {
    final boundGroupId = _groupId;
    final bindGeneration = _bindGeneration;
    debugPrint('[MascotService] Migrating ${oldOnes.length} old defaults…');
    // Clear active if it was an old default.
    if (_kOldDefaultIds.contains(_state.activeMascotId)) {
      await setActive(null);
    }
    // Delete every old default from PB.
    for (final m in oldOnes) {
      if (_groupId != boundGroupId || bindGeneration != _bindGeneration) return;
      await _repo.delete(boundGroupId, m.id);
    }
    // Write new defaults — stream will re-fire and gallery updates.
    final newDefaults = DefaultMascots.asMascots();
    if (_groupId != boundGroupId || bindGeneration != _bindGeneration) return;
    await _repo.saveBatch(boundGroupId, newDefaults);
    // Auto-activate the first new default so the mascot stays visible.
    if (newDefaults.isNotEmpty) {
      if (_groupId != boundGroupId || bindGeneration != _bindGeneration) return;
      await setActive(newDefaults.first.id);
    }
  }

  Future<void> _seedDefaults() async {
    final boundGroupId = _groupId;
    final bindGeneration = _bindGeneration;
    final defaults = DefaultMascots.asMascots();
    await _repo.saveBatch(boundGroupId, defaults);
    // Активируем первого дефолтного ТОЛЬКО если активного ещё нет — иначе затёрли
    // бы выбор пользователя (доп. защита к отложенному seed выше).
    final hasActive = (_state.activeMascotId ?? '').isNotEmpty;
    if (defaults.isNotEmpty && !hasActive) {
      if (_groupId != boundGroupId || bindGeneration != _bindGeneration) return;
      await setActive(defaults.first.id);
    }
    if (_groupId == boundGroupId &&
        bindGeneration == _bindGeneration &&
        _mascots.isEmpty) {
      _mascots = List.from(defaults);
      _isLoading = false;
      notifyListeners();
    }
  }

  // ── Streak ─────────────────────────────────────────────────────────────────

  Future<void> recordDailyActivity() async {
    if (_groupId.isEmpty) return;
    await _repo.recordActivity(_groupId);
    unawaited(LevelService.instance.award(XpAction.dailyStreak));
    _syncStreakWidget();
  }

  // ── Active mascot ──────────────────────────────────────────────────────────

  Future<void> setActive(String? mascotId) async {
    if (_groupId.isEmpty) return;
    _state = _state.copyWith(
      activeMascotId: mascotId,
      clearActiveMascot: mascotId == null,
    );
    notifyListeners();
    await _repo.setActive(_groupId, mascotId);
  }

  Future<void> updatePosition({
    required double x,
    required double y,
    required double scale,
  }) async {
    if (_groupId.isEmpty) return;
    _state = _state.copyWith(positionX: x, positionY: y, scale: scale);
    notifyListeners();
    await _repo.updatePosition(_groupId, x: x, y: y, scale: scale);
  }

  // ── CRUD ───────────────────────────────────────────────────────────────────

  Future<void> addMascot(Mascot mascot) async {
    if (_groupId.isEmpty) return;
    await _repo.save(_groupId, mascot);
  }

  Future<void> deleteMascot(Mascot mascot) async {
    if (_groupId.isEmpty) return;
    // If it was active, clear it.
    if (_state.activeMascotId == mascot.id) {
      await setActive(null);
    }
    // Чистка файла картинки (Storage) отложена на §4 (как медиа воспоминаний).
    await _repo.delete(_groupId, mascot.id);
  }

  Future<void> renameMascot(Mascot mascot, String newName) async {
    if (_groupId.isEmpty) return;
    mascot.name = newName;
    notifyListeners();
    await _repo.rename(_groupId, mascot.id, newName);
  }

  /// Upload PNG bytes → Storage, create Mascot, save to PB.
  /// Загрузка файла пока на Firebase Storage (медиа §4); данные — на PB.
  Future<Mascot?> uploadAndSaveMascot({
    required List<int> pngBytes,
    required String name,
    required String creatorUid,
  }) async {
    if (_groupId.isEmpty) return null;
    final boundGroupId = _groupId;
    final bindGeneration = _bindGeneration;

    final url = await _fb.uploadMascotImage(
      groupId: boundGroupId,
      pngBytes: pngBytes,
    );
    if (url == null ||
        _groupId != boundGroupId ||
        bindGeneration != _bindGeneration) {
      return null;
    }

    final mascot = Mascot(
      id: 'mascot_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      imageUrl: url,
      createdBy: creatorUid,
      createdAt: DateTime.now(),
      isDefault: false,
    );
    await _repo.save(boundGroupId, mascot);
    // Optimistically add to local list so the gallery updates immediately
    // without waiting for the PB stream to echo back.
    if (!_mascots.any((m) => m.id == mascot.id)) {
      _mascots = [..._mascots, mascot];
      notifyListeners();
    }
    return mascot;
  }

  /// Update the image of an existing mascot (re-draw flow).
  Future<void> updateMascotImage({
    required Mascot mascot,
    required List<int> pngBytes,
  }) async {
    if (_groupId.isEmpty) return;
    final boundGroupId = _groupId;
    final bindGeneration = _bindGeneration;
    final url = await _fb.uploadMascotImage(
      groupId: boundGroupId,
      pngBytes: pngBytes,
    );
    if (url == null ||
        _groupId != boundGroupId ||
        bindGeneration != _bindGeneration) {
      return;
    }
    // Удаление старого файла из Storage отложено на §4 (медиа).
    final updated = mascot.copyWith(imageUrl: url);
    await _repo.save(boundGroupId, updated);
    // Optimistically update local list.
    final idx = _mascots.indexWhere((m) => m.id == mascot.id);
    if (idx != -1) {
      final list = List<Mascot>.from(_mascots);
      list[idx] = updated;
      _mascots = list;
      notifyListeners();
    }
  }

  // ── Mood state helper for display ─────────────────────────────────────────

  /// Returns the asset path for [mascot], or null for user-drawn (URL-based) ones.
  String? resolvedAssetForMood(Mascot mascot) => mascot.defaultAsset;

  @override
  void dispose() {
    CatalogService.instance.removeListener(_onCatalogChanged);
    _mascotsSub?.cancel();
    _groupStateSub?.cancel();
    super.dispose();
  }
}
