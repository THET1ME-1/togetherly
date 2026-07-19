import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/timer_item.dart';
import 'media_service.dart';
import 'home_widget_service.dart';
import 'pocketbase_service.dart';
import 'timer_repository.dart';

/// Сервис для управления пользовательскими таймерами.
/// Хранит данные локально (SharedPreferences) и синхронизирует с PocketBase
/// когда пользователь состоит в группе (миграция §3): групповые таймеры —
/// `groups.timers`, соло — `users.solo_timers`. Фоны таймеров (загрузка/
/// удаление) — целиком PocketBase media через [MediaService].
class TimerService extends ChangeNotifier {
  static const _localStorageKey = 'user_timers_local';

  /// Детерминированный id системного таймера. Благодаря фиксированному id
  /// upsert обоих партнёров пишет в одну и ту же запись массива (RMW удаляет
  /// по id перед добавлением), поэтому одновременное создание пары не
  /// порождает два системных таймера.
  static const systemTimerId = 'system';
  final TimerRepository _repo = TimerRepository();

  List<TimerItem> _timers = [];
  String _groupId = '';
  StreamSubscription? _firestoreSub;
  bool _hasReceivedRemoteSync = false; // флаг первой синхронизации с Firestore

  // Параметры ожидающего создания системного таймера
  Map<String, dynamic>? _pendingSystemTimer;

  List<TimerItem> get timers {
    // System timer always at position 0, others follow in creation order.
    // Do NOT sort by isDefault — it changes on every swipe and would
    // cause the carousel to re-order while the user is navigating.
    final sorted = [..._timers]..sort((a, b) {
        if (a.isSystem && !b.isSystem) return -1;
        if (!a.isSystem && b.isSystem) return 1;
        return 0;
      });
    return List.unmodifiable(sorted);
  }
  int get count => _timers.length;

  String get _storageKey {
    final uid = PocketBaseService().userId ?? 'guest';
    return _groupId.isNotEmpty
        ? 'user_timers_${uid}_$_groupId'
        : '${_localStorageKey}_$uid';
  }

  /// Таймер, отображаемый по умолчанию в свёрнутом виде.
  TimerItem? get defaultTimer {
    try {
      return _timers.firstWhere((t) => t.isDefault);
    } catch (_) {
      return _timers.isNotEmpty ? _timers.first : null;
    }
  }

  /// Системный таймер (неудаляемый, создаётся при создании группы)
  TimerItem? get systemTimer {
    try {
      return _timers.firstWhere((t) => t.isSystem);
    } catch (_) {
      return null;
    }
  }

  // ── Инициализация ──

  Future<void> init() async {
    await _loadLocal();
    if (_groupId.isEmpty) {
      if (_timers.isEmpty) {
        // После переустановки: восстанавливаем из облака
        await _loadFromCloud();
      } else {
        // Есть локальные данные: обновляем облако (миграция + актуализация)
        unawaited(_saveSoloCloud());
      }
    }
    await _syncWidgetTimer();
    notifyListeners();
  }

  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _timers = TimerItem.decodeList(raw);
        return;
      } catch (_) {}
    }
    _timers = [];
  }

  /// Восстанавливает соло-таймеры из облака (PB) — вызывается после переустановки.
  Future<void> _loadFromCloud() async {
    try {
      final remote = await _repo.loadSoloTimers();
      if (remote != null && remote.isNotEmpty) {
        _timers = remote.map(TimerItem.fromJson).toList();
        await _saveLocal();
        debugPrint('TimerService: восстановлено ${_timers.length} соло-таймеров из облака');
      }
    } catch (e) {
      debugPrint('TimerService: _loadFromCloud error: $e');
    }
  }

  /// Сохраняет соло-таймеры в облако (PB, fire-and-forget).
  Future<void> _saveSoloCloud() async {
    try {
      await _repo.saveSoloTimers(_timers);
    } catch (e) {
      debugPrint('TimerService: _saveSoloCloud error: $e');
    }
  }

  /// Привязать к группе — начинает синхронизацию с Firestore.
  /// Вызывается когда пользователь входит в группу.
  Future<void> bindToGroup(String groupId) async {
    if (_groupId == groupId && groupId.isNotEmpty) return;
    _firestoreSub?.cancel();
    _groupId = groupId;
    _hasReceivedRemoteSync = false;
    _pendingSystemTimer = null;
    _timers = [];
    await _loadLocal();
    notifyListeners();
    if (groupId.isEmpty) return;

    // Слушаем изменения групповых таймеров (PB group.timers, live).
    _firestoreSub = _repo.watchGroupTimers(groupId).listen(
      _mergeRemoteTimers,
      onError: (e) => debugPrint('TimerService: watchGroupTimers error: $e'),
    );
  }

  /// Отвязать от группы (при unpair или переключении на соло)
  Future<void> unbindFromGroup() async {
    _firestoreSub?.cancel();
    _firestoreSub = null;
    _groupId = '';
    _hasReceivedRemoteSync = false;
    _pendingSystemTimer = null;
    await _loadLocal();
    // Sync widget for solo mode after unbind
    await _syncWidgetTimer();
    notifyListeners();
  }

  /// Слияние remote таймеров с локальными.
  /// Remote таймеры имеют приоритет, но локальные изменения isCountdown
  /// сохраняются если они не успели синхронизироваться до закрытия приложения.
  void _mergeRemoteTimers(List<TimerItem> remote) {
    // Снимок локального состояния до перезаписи (загружен из SharedPreferences)
    final localById = Map.fromEntries(_timers.map((t) => MapEntry(t.id, t)));

    // Очищаем устаревшие локальные пути (не URL) — они не синхронизируются
    bool hadStalePaths = false;
    bool hadUnsyncedIsCountdown = false;
    _timers = remote.map((t) {
      TimerItem result = t;
      final path = t.backgroundImagePath;
      if (path != null &&
          !path.startsWith('http') &&
          !path.startsWith('gs://') &&
          !path.startsWith('sb://') &&
          !path.startsWith('pb://')) {
        // Локальный путь от другого устройства — удаляем
        debugPrint(
          'TimerService: очищаю устаревший локальный путь у таймера ${t.id}',
        );
        hadStalePaths = true;
        result = result.copyWith()..backgroundImagePath = null;
      }
      // Если локальный isCountdown отличается от Firestore — значит изменение
      // не успело сохраниться до закрытия приложения. Восстанавливаем его.
      final local = localById[t.id];
      if (local != null && local.isCountdown != t.isCountdown) {
        debugPrint(
          'TimerService: восстанавливаю локальный isCountdown=${local.isCountdown} для таймера ${t.id}',
        );
        result = result.copyWith(isCountdown: local.isCountdown);
        hadUnsyncedIsCountdown = true;
      }
      return result;
    }).toList();

    // Дедупликация системных таймеров: при race condition может появиться
    // несколько таймеров с isSystem=true. Оставляем только первый.
    bool hadDuplicateSystem = false;
    bool foundSystem = false;
    _timers = _timers.where((t) {
      if (t.isSystem) {
        if (!foundSystem) {
          foundSystem = true;
          return true;
        }
        hadDuplicateSystem = true;
        debugPrint(
          'TimerService: удаляю дублирующийся системный таймер ${t.id} (${t.title})',
        );
        return false;
      }
      return true;
    }).toList();

    debugPrint(
      'TimerService: _mergeRemoteTimers: получено ${_timers.length} таймеров, '
      'backgroundImagePaths: ${_timers.map((t) => t.backgroundImagePath ?? "null").join(", ")}',
    );

    // Гарантируем ровно один default (не ноль, не два)
    bool hadDuplicateDefault = false;
    final defaultTimers = _timers.where((t) => t.isDefault).toList();
    if (defaultTimers.length > 1) {
      hadDuplicateDefault = true;
      final keep = defaultTimers.firstWhere((t) => t.isSystem, orElse: () => defaultTimers.first);
      for (final t in _timers) {
        t.isDefault = t.id == keep.id;
      }
      debugPrint('TimerService: исправляю дублирующийся default флаг, оставляю ${keep.id}');
    } else if (defaultTimers.isEmpty && _timers.isNotEmpty) {
      final sys = systemTimer;
      if (sys != null) {
        sys.isDefault = true;
      } else {
        _timers.first.isDefault = true;
      }
    }

    _hasReceivedRemoteSync = true;

    // Если были устаревшие пути, дублирующиеся таймеры или восстановленный
    // isCountdown — сохраняем актуальное состояние обратно в Firestore
    if (hadStalePaths || hadDuplicateSystem || hadDuplicateDefault || hadUnsyncedIsCountdown) {
      _saveToFirestore();
    }

    // Если был ожидающий системный таймер — создаём его сейчас (если ещё нет)
    if (_pendingSystemTimer != null && systemTimer == null) {
      final p = _pendingSystemTimer!;
      _pendingSystemTimer = null;
      debugPrint('TimerService: создаю отложенный системный таймер');
      addTimer(
        id: systemTimerId,
        title: p['title'] as String,
        startDate: p['startDate'] as DateTime,
        emoji: p['emoji'] as String,
        isDefault: true,
        isSystem: true,
      );
      return; // addTimer вызовет notifyListeners сам
    }

    _saveLocal();
    unawaited(_syncWidgetTimer());
    notifyListeners();
  }

  void _ensureDefaultFlag() {
    final defaults = _timers.where((t) => t.isDefault).toList();
    if (defaults.length > 1) {
      // Оставляем только один default: предпочитаем системный, иначе первый.
      final keep = defaults.firstWhere((t) => t.isSystem, orElse: () => defaults.first);
      for (final t in _timers) {
        t.isDefault = t.id == keep.id;
      }
    } else if (defaults.isEmpty && _timers.isNotEmpty) {
      final sys = systemTimer;
      if (sys != null) {
        sys.isDefault = true;
      } else {
        _timers.first.isDefault = true;
      }
    }
  }

  Future<void> _saveLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, TimerItem.encodeList(_timers));
    if (_groupId.isEmpty) {
      unawaited(_saveSoloCloud());
    }
  }

  Future<void> _saveToFirestore() async {
    if (_groupId.isEmpty) {
      debugPrint('TimerService: не могу сохранить в облако - groupId пуст');
      return;
    }
    await _repo.saveGroupTimers(_groupId, _timers);
    debugPrint('TimerService: таймеры успешно сохранены (${_timers.length})');
  }

  // ── CRUD ──

  /// Создать новый таймер.
  /// [id] позволяет задать детерминированный идентификатор (используется для
  /// системного таймера, чтобы upsert обоих партнёров схлопывался в одну запись
  /// и не плодил дубликаты при одновременном создании пары).
  Future<void> addTimer({
    required String title,
    required DateTime startDate,
    String emoji = '❤️',
    bool isDefault = false,
    bool isSystem = false,
    bool isCountdown = false,
    String? id,
  }) async {
    // Если таймер с таким id уже есть (детерминированный системный id) —
    // не дублируем локально.
    if (id != null && _timers.any((t) => t.id == id)) return;
    id ??= DateTime.now().millisecondsSinceEpoch.toString();
    if (isDefault) {
      for (final t in _timers) {
        t.isDefault = false;
      }
    }
    _timers.add(
      TimerItem(
        id: id,
        title: title,
        startDate: startDate,
        isDefault: isDefault || _timers.isEmpty,
        emoji: emoji,
        isSystem: isSystem,
        isCountdown: isCountdown,
      ),
    );
    _ensureDefaultFlag();
    await _saveLocal();
    if (_groupId.isNotEmpty) {
      final added = _timers.last;
      if (added.isDefault && !added.isSystem) {
        // Новый таймер сразу делают основным: пишем весь согласованный массив,
        // чтобы на сервере остался ровно один дефолтный (иначе системный
        // остался бы дефолтным и realtime-merge откатил бы выбор — см.
        // updateTimer). Для СИСТЕМНОГО таймера так делать нельзя: upsert по
        // детерминированному id схлопывает дубли при одновременном создании пары.
        await _saveToFirestore();
      } else {
        await _repo.upsertGroupTimer(_groupId, added);
      }
    }
    // Sync widget immediately after creating timer (single user mode)
    await _syncWidgetTimer();
    notifyListeners();
  }

  Future<void> _syncWidgetTimer() async {
    if (_timers.isEmpty) {
      debugPrint('TimerService._syncWidgetTimer: нет таймеров, очищаю виджет');
      await HomeWidgetService.instance.clearTimerWidget();
      return;
    }
    final timer = defaultTimer ?? _timers.first;
    debugPrint('TimerService._syncWidgetTimer: syncing timer ${timer.id} title=${timer.title} days=${timer.daysElapsed} groupId=$_groupId');
    await HomeWidgetService.instance.syncTimerAndDays(timer, groupId: _groupId);
  }

  /// Обновить существующий таймер.
  Future<void> updateTimer(TimerItem updated) async {
    final idx = _timers.indexWhere((t) => t.id == updated.id);
    if (idx == -1) return;
    if (updated.isDefault) {
      for (final t in _timers) {
        t.isDefault = false;
      }
    }
    _timers[idx] = updated;
    _ensureDefaultFlag();
    await _saveLocal();
    if (_groupId.isNotEmpty) {
      if (updated.isDefault) {
        // Таймер сделали основным: пишем ВЕСЬ согласованный массив одним RMW,
        // чтобы на сервере остался ровно один дефолтный. Иначе upsert только
        // этого таймера оставил бы системный с isDefault=true → realtime-merge
        // увидел бы два дефолтных и откатил выбор к системному (firstWhere
        // isSystem в _mergeRemoteTimers) — кнопка «Сделать основным» «не
        // срабатывала».
        await _saveToFirestore();
      } else {
        await _repo.upsertGroupTimer(_groupId, updated);
      }
    }
    await _syncWidgetTimer();
    notifyListeners();
  }

  /// Удалить таймер по id. Системные таймеры удалить нельзя.
  Future<void> deleteTimer(String id) async {
    final timer = _timers.firstWhere(
      (t) => t.id == id,
      orElse: () => TimerItem(id: '', title: '', startDate: DateTime.now()),
    );
    if (timer.isSystem) return; // нельзя удалить системный таймер

    debugPrint('TimerService.deleteTimer: удаляю таймер $id (${timer.title}), groupId=$_groupId');
    
    _timers.removeWhere((t) => t.id == id);
    // Если удалили дефолтный — ставим первый
    if (_timers.isNotEmpty && !_timers.any((t) => t.isDefault)) {
      _timers.first.isDefault = true;
    }
    await _saveLocal();
    debugPrint('TimerService.deleteTimer: сохранено в local, таймеров: ${_timers.length}');
    
    if (_groupId.isNotEmpty) {
      await _repo.deleteGroupTimer(_groupId, id);
      debugPrint('TimerService.deleteTimer: удалено из облака');
    }
    
    await _syncWidgetTimer();
    notifyListeners();
    debugPrint('TimerService.deleteTimer: завершено, синхронизировано с виджетом');
  }

  /// Назначить таймер «показываемым по умолчанию».
  Future<void> setDefault(String id) async {
    for (final t in _timers) {
      t.isDefault = t.id == id;
    }
    _ensureDefaultFlag();
    await _saveLocal();
    if (_groupId.isNotEmpty) {
      await _repo.setDefaultGroupTimer(_groupId, id);
    }
    await _syncWidgetTimer();
    notifyListeners();
  }

  /// Создать системный таймер при создании группы.
  /// Если системный уже есть — не создаёт повторно.
  /// Если Firestore ещё не синхронизировался — откладывает создание.
  Future<void> createSystemTimer({
    required DateTime startDate,
    required String relationshipLabel,
    required String relationshipEmoji,
    required String partnerName,
  }) async {
    final title = '$relationshipLabel with $partnerName';

    // Если группа привязана, но remote-таймеры ещё не пришли — откладываем.
    // ВАЖНО: проверку `systemTimer != null` НЕЛЬЗЯ делать раньше этого, т.к. при
    // переключении пар bindToGroup → _loadLocal грузит таймеры ПРЕДЫДУЩЕЙ группы
    // из глобального ключа prefs. Этот «фантомный» системный таймер заставлял
    // createSystemTimer выйти раньше, не отложив создание → у новой пары timers
    // оставались пустыми (0 0 0 на экране). _mergeRemoteTimers перезапишет _timers
    // remote-данными и создаст отложенный таймер, если системного там нет.
    if (_groupId.isNotEmpty && !_hasReceivedRemoteSync) {
      debugPrint(
        'TimerService: createSystemTimer — ждём первую синхронизацию remote',
      );
      _pendingSystemTimer = {
        'title': title,
        'startDate': startDate,
        'emoji': relationshipEmoji,
      };
      return;
    }

    // Remote синхронизирован — создаём только если системного таймера реально нет.
    if (systemTimer != null) return;

    await addTimer(
      id: systemTimerId,
      title: title,
      startDate: startDate,
      emoji: relationshipEmoji,
      isDefault: true,
      isSystem: true,
    );
  }

  /// Обновить название системного таймера при смене статуса/типа отношений.
  Future<void> updateSystemTimerTitle({
    required String relationshipLabel,
    required String relationshipEmoji,
    required String partnerName,
  }) async {
    final sys = systemTimer;
    if (sys == null) return;

    final newTitle = '$relationshipLabel with $partnerName';
    if (sys.title == newTitle && sys.emoji == relationshipEmoji) return;

    sys.title = newTitle;
    sys.emoji = relationshipEmoji;
    _ensureDefaultFlag();
    await _saveLocal();
    if (_groupId.isNotEmpty) {
      await _repo.upsertGroupTimer(_groupId, sys);
    }
    await _syncWidgetTimer();
    notifyListeners();
  }

  /// Создать «стартовый» таймер из PairData, если таймеров ещё нет.
  Future<void> ensureDefaultFromPair({
    required DateTime startDate,
    required String partnerName,
    required String relationshipLabel,
  }) async {
    if (_timers.isNotEmpty) return;
    await addTimer(
      title: '$relationshipLabel with $partnerName',
      startDate: startDate,
      emoji: '❤️',
      isDefault: true,
    );
  }

  /// Загружает изображение в Firebase Storage и устанавливает его фоном таймера.
  /// Возвращает true при успехе. Старый фон (если был URL) удаляется из Storage.
  Future<bool> uploadTimerBackground(
    TimerItem timer,
    String localFilePath,
  ) async {
    if (_groupId.isEmpty) {
      debugPrint('TimerService: uploadTimerBackground — groupId пуст');
      return false;
    }
    try {
      // Удаляем старый фон из PocketBase Storage (pb://). Legacy-ссылки и
      // локальные пути deleteByUrl игнорирует — Firebase тут не используется.
      await MediaService().deleteByUrl(timer.backgroundImagePath);

      final ext = localFilePath.split('.').last.toLowerCase();
      final storagePath = 'timer_backgrounds/$_groupId/${timer.id}.$ext';
      final url = await MediaService().uploadFile(localFilePath, storagePath);
      if (url == null) return false;

      // Удаляем локальную копию — больше не нужна
      try {
        final f = File(localFilePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}

      await updateTimer(timer.copyWith(backgroundImagePath: url));
      return true;
    } catch (e) {
      debugPrint('TimerService: uploadTimerBackground error: $e');
      return false;
    }
  }

  /// Удаляет фоновое изображение таймера (из Storage и локально).
  Future<void> removeTimerBackground(TimerItem timer) async {
    final path = timer.backgroundImagePath;
    if (path == null) return;
    if (path.startsWith('http') ||
        path.startsWith('gs://') ||
        path.startsWith('sb://') ||
        path.startsWith('pb://')) {
      // Облачный файл: pb:// удаляется из PocketBase; legacy-ссылки — no-op.
      await MediaService().deleteByUrl(path);
    } else {
      // Локальный файл (legacy)
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await updateTimer(timer.copyWith()..backgroundImagePath = null);
  }

  /// Полная очистка всех таймеров — при выходе или новой регистрации.
  Future<void> clearAll() async {
    _timers.clear();
    _firestoreSub?.cancel();
    _firestoreSub = null;
    _groupId = '';
    _hasReceivedRemoteSync = false;
    _pendingSystemTimer = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    notifyListeners();
  }

  @override
  void dispose() {
    _firestoreSub?.cancel();
    super.dispose();
  }
}
