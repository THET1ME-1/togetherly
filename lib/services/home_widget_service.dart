import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pb_data_service.dart';
import 'pb_media_service.dart';
import 'pocketbase_service.dart';
import '../theme/app_theme.dart';
import 'pb_auth_service.dart';
import '../models/timer_item.dart';
import '../models/mood_entry.dart';
import '../models/widget_data.dart';
import 'locale_service.dart';

/// Сервис для синхронизации данных всех виджетов рабочего стола
/// (кроме основного парного виджета [LoveWidgetProvider],
///  который обновляется в [WidgetService]).
///
/// Каждый тип виджета привязан к конкретной группе (groupId).
/// При синхронизации виджет ВСЕГДА обновляется данными **своей** группы,
/// даже если сейчас активна другая группа.
///
/// Виджеты:
/// 1. DaysCounterWidgetProvider — счётчик дней вместе
/// 2. TimerWidgetProvider       — таймер / обратный отсчёт
/// 3. PhotoDayWidgetProvider    — фото дня из Memory Lane
/// 4. MoodWidgetProvider        — крупный виджет настроения
class HomeWidgetService {
  HomeWidgetService._();
  static final HomeWidgetService instance = HomeWidgetService._();

  /// Виджеты Android-only; refreshPhotoOfDay/_readWidgetData идут в ОСНОВНОМ
  /// изоляте (нативный фоновый рефреш — отдельный путь в main.dart). PB-чтения
  /// здесь работают на инициализированном в main клиенте.

  /// Читает widget_data одного участника из PocketBase (коллекция widget_data) →
  /// модель WidgetData. null если строки нет.
  Future<WidgetData?> _readWidgetData(
    String groupId,
    String userUid,
  ) async {
    if (groupId.isEmpty || userUid.isEmpty) return null;
    final rec = await PbDataService().loadWidget(groupId, userUid);
    return rec == null ? null : WidgetData.fromPb(rec);
  }

  /// Резолвит (uid, name) партнёра из участников группы (PocketBase pair-map).
  /// Возвращает null при ошибке/отсутствии группы; uid='' если партнёр не
  /// найден (одиночная группа).
  Future<({String uid, String name})?> _resolvePartnerFromGroup(
    String groupId,
    String currentUserUid,
  ) async {
    try {
      final pair =
          await PbDataService().loadPairMapById(groupId, currentUserUid);
      if (pair == null) return null;
      final members = (pair['members'] as List?) ?? const [];
      for (final m in members) {
        if (m is Map && m['uid'] != null && m['uid'] != currentUserUid) {
          return (uid: m['uid'].toString(), name: (m['name'] ?? '').toString());
        }
      }
      return (uid: '', name: '');
    } catch (e) {
      debugPrint('HomeWidgetService._resolvePartnerFromGroup failed: $e');
      return null;
    }
  }

  // TTL-кэш для _getPartnerWidgetData / _getMyWidgetData.
  // refreshPhotoOfDay вызывается для каждого photo-day виджета в цикле
  // (syncAllBoundWidgets) + на каждое реальное изменение photo полей —
  // без кэша это N×collection .get() + N×doc .get() на каждый sync.
  // 30s — фото меняются заметно реже, а карусель/виджет всё равно перерисуется
  // при следующем listener-event на widgetData.
  static const Duration _widgetDataCacheTtl = Duration(seconds: 30);
  final Map<String, _CachedWidgetData> _partnerDataCache = {};
  final Map<String, _CachedWidgetData> _myDataCache = {};

  // Последние известные гендерные данные — используются в syncTimerAndDays,
  // чтобы Days Counter всегда показывал правильную картинку пары даже когда
  // полный syncAllBoundWidgets ещё не вызывался.
  String _cachedMyGender = '';
  String _cachedPartnerGender = '';

  /// Сбросить кэш widget-данных (вызывать когда заведомо знаем, что фото поменялось).
  void invalidateWidgetDataCache() {
    _partnerDataCache.clear();
    _myDataCache.clear();
  }

  // ════════════════════════════════════════════════════════════════════════
  //  ФОНОВОЕ ОБНОВЛЕНИЕ ВИДЖЕТОВ (изолят foreground-сервиса, БЕЗ FCM)
  // ════════════════════════════════════════════════════════════════════════

  /// Серверо-управляемое обновление виджетов из ФОНОВОГО изолята
  /// (foreground-сервис PushBackgroundService), когда приложение свёрнуто/
  /// выгружено. Здесь НЕТ in-memory состояния главного изолята (TimerService/
  /// MoodService/PairData), поэтому всё читается напрямую из PocketBase. Делает
  /// мгновенным обновление парного Love-виджета (статус/настроение/сообщение/
  /// музыка я+партнёр), фото-виджетов и крупного mood-виджета при изменении
  /// партнёром данных — без открытия приложения.
  ///
  /// Идемпотентно и устойчиво к сбоям: каждая часть в своём try, чтобы падение
  /// одного виджета не срывало остальные. Android-only.
  /// [refreshPhotos] — перекачивать ли фото-виджеты. Фото в `_cachePhotoFromUrl`
  /// скачиваются заново на КАЖДЫЙ вызов, поэтому периодический watchdog зовёт с
  /// false (дёшево: только парный/mood-виджет из PB), а событие об изменении
  /// widget_data и стартовая синхронизация — с true.
  Future<void> backgroundRefreshAll({
    required String groupId,
    required String myUid,
    required String partnerUid,
    bool refreshPhotos = true,
  }) async {
    if (!Platform.isAndroid) return;
    if (groupId.isEmpty || myUid.isEmpty) return;
    // Фоновый изолят (WorkManager / foreground-сервис) НЕ инициализирует
    // LocaleService — это делает только главный изолят в main.dart. Без этого
    // MoodOption.localizedLabel в _refreshMoodWidgetFromServer падает в дефолт
    // EN и mood-виджет обновлялся с английскими метками, пока приложение не
    // откроют. Инициализируем локаль здесь (идемпотентно), чтобы фон писал
    // метки настроения на языке пользователя.
    await LocaleService.instance.init();
    // В фоне нужны СВЕЖИЕ данные на каждое событие — сбрасываем TTL-кэш.
    invalidateWidgetDataCache();
    try {
      await refreshLoveWidgetFromServer(groupId, myUid, partnerUid);
    } catch (e) {
      debugPrint('HomeWidgetService.backgroundRefreshAll love failed: $e');
    }
    if (refreshPhotos) {
      try {
        await refreshPhotoOfDay(groupId);
      } catch (e) {
        debugPrint('HomeWidgetService.backgroundRefreshAll photo failed: $e');
      }
    }
    try {
      await _refreshMoodWidgetFromServer(groupId, myUid, partnerUid);
    } catch (e) {
      debugPrint('HomeWidgetService.backgroundRefreshAll mood failed: $e');
    }
  }

  /// Парный Love-виджет (LoveWidgetProvider): мои и партнёрские статус/
  /// настроение/сообщение/музыка из коллекции `widget_data`. Та же логика, что
  /// в нативном фоновом колбэке [_homeWidgetBackgroundCallback] (main.dart) —
  /// вынесена сюда, чтобы переиспользоваться и из изолята foreground-сервиса.
  Future<void> refreshLoveWidgetFromServer(
    String groupId,
    String myUid,
    String partnerUid,
  ) async {
    final myRec = await PbDataService().loadWidget(groupId, myUid);
    if (myRec != null) {
      final d = WidgetData.fromPb(myRec);
      await Future.wait([
        HomeWidget.saveWidgetData<String>('my_status', d.status),
        HomeWidget.saveWidgetData<String>('my_mood', d.moodLabel),
        HomeWidget.saveWidgetData<String>('my_message', d.message),
        HomeWidget.saveWidgetData<String>('my_music_title', d.musicTitle ?? ''),
        HomeWidget.saveWidgetData<String>(
            'my_music_artist', d.musicArtist ?? ''),
      ]);
    }
    if (partnerUid.isNotEmpty) {
      final partnerRec = await PbDataService().loadWidget(groupId, partnerUid);
      if (partnerRec != null) {
        final d = WidgetData.fromPb(partnerRec);
        await Future.wait([
          HomeWidget.saveWidgetData<String>('partner_status', d.status),
          HomeWidget.saveWidgetData<String>('partner_mood', d.moodLabel),
          HomeWidget.saveWidgetData<String>('partner_message', d.message),
          HomeWidget.saveWidgetData<String>(
              'partner_music_title', d.musicTitle ?? ''),
          HomeWidget.saveWidgetData<String>(
              'partner_music_artist', d.musicArtist ?? ''),
        ]);
      }
    }
    await HomeWidget.updateWidget(
      name: 'LoveWidgetProvider',
      androidName: 'LoveWidgetProvider',
    );
  }

  /// Крупный mood-виджет (MoodWidgetProvider) из фона: эмодзи/метку/тир/цвет
  /// настроения восстанавливаем по `widget_data.mood_emoji` через MoodOption —
  /// без MoodService главного изолята. syncMood сам no-op, если настроений нет.
  Future<void> _refreshMoodWidgetFromServer(
    String groupId,
    String myUid,
    String partnerUid,
  ) async {
    final myWd = await _readWidgetData(groupId, myUid);
    final partnerWd =
        partnerUid.isEmpty ? null : await _readWidgetData(groupId, partnerUid);
    MoodOption? optOf(WidgetData? wd) =>
        (wd != null && wd.moodEmoji.isNotEmpty)
            ? MoodOption.byImagePath(wd.moodEmoji)
            : null;
    final myOpt = optOf(myWd);
    final pOpt = optOf(partnerWd);
    String hexOf(MoodOption? o) => o == null
        ? ''
        : '#${o.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
    await syncMood(
      groupId: groupId,
      moodEmojiAssetPath: myOpt?.imagePath ?? (myWd?.moodEmoji ?? ''),
      moodLabel: myOpt?.localizedLabel ?? (myWd?.moodLabel ?? ''),
      moodScore: myOpt?.score ?? 0,
      moodColor: hexOf(myOpt),
      userName: myWd?.displayName ?? '',
      partnerMoodEmojiAssetPath: pOpt?.imagePath ?? (partnerWd?.moodEmoji ?? ''),
      partnerMoodLabel: pOpt?.localizedLabel ?? (partnerWd?.moodLabel ?? ''),
      partnerMoodScore: pOpt?.score ?? 0,
      partnerMoodColor: hexOf(pOpt),
      partnerUserName: partnerWd?.displayName ?? '',
    );
  }

  Future<void> _updateAllPhotoWidgetProviders() async {
    await HomeWidget.updateWidget(
      name: 'PhotoDayWidgetProvider',
      androidName: 'PhotoDayWidgetProvider',
    );
    await HomeWidget.updateWidget(
      name: 'SelfPhotoWidgetProvider',
      androidName: 'SelfPhotoWidgetProvider',
    );
    await HomeWidget.updateWidget(
      name: 'PartnerPhotoWidgetProvider',
      androidName: 'PartnerPhotoWidgetProvider',
    );
  }

  /// Последний известный флаг романтической темы — fallback в syncTimer.
  bool _lastIsRomantic = true;

  /// Последний известный индекс темы приложения — fallback в syncTimer.
  int _lastThemeIndex = 0;


  // ════════════════════════════════════════════════════════════════════════
  //  ПРИВЯЗКА ВИДЖЕТОВ К ГРУППАМ
  // ════════════════════════════════════════════════════════════════════════

  static const _boundGroupPrefix = 'widget_bound_group_';
  static const _photoSaveMemoryPrefix = 'photo_day_save_memory_';
  static const _photoRefreshSeedPrefix = 'photo_day_refresh_seed_';
  static const _photoDayPendingConfigsKey = 'photo_day_pending_configs';
  static const _widgetChannel = MethodChannel('love_app/widgets');

  /// iOS-мост: копирование медиа виджетов в контейнер App Group
  /// (AppDelegate.copyToAppGroup). Расширение виджета — отдельный процесс со
  /// своей песочницей и читать файлы из getApplicationSupportDirectory НЕ может;
  /// картинку видно, только если она лежит в общем App Group контейнере.
  static const _iosMediaChannel = MethodChannel('love_app/ios_widget_media');

  /// Делает локальный файл [localPath] доступным расширению виджета.
  /// • iOS — копирует в контейнер App Group и возвращает путь ВНУТРИ контейнера
  ///   (только он читается виджетом); сбой/пусто → '' (sandbox-путь виджету всё
  ///   равно бесполезен, лучше пустое фото, чем «битый» путь).
  /// • Android — путь как есть (виджету доступно обычное app-storage).
  /// [name] — стабильное имя файла в контейнере (перезапись = обновление фото).
  /// Публичная обёртка [_toWidgetReadablePath] — для [WidgetService] (парный
  /// виджет), чтобы не дублировать iOS App Group мост.
  Future<String> appGroupReadablePath(String localPath, String name) =>
      _toWidgetReadablePath(localPath, name);

  /// Удаляет из контейнера App Group файлы виджет-медиа с именем на [prefix]
  /// (iOS). Нужно, чтобы старые фото не копились и WidgetKit не держал картинку
  /// по устаревшему пути при смене фото.
  Future<void> clearAppGroupMedia(String prefix) async {
    if (!Platform.isIOS || prefix.isEmpty) return;
    try {
      await _iosMediaChannel
          .invokeMethod('clearAppGroupMedia', {'prefix': prefix});
    } catch (e) {
      debugPrint('HomeWidgetService.clearAppGroupMedia failed: $e');
    }
  }

  Future<String> _toWidgetReadablePath(String localPath, String name) async {
    if (localPath.isEmpty || !Platform.isIOS) return localPath;
    try {
      final res = await _iosMediaChannel.invokeMethod<String>(
        'copyToAppGroup',
        {'srcPath': localPath, 'name': name},
      );
      return (res != null && res.isNotEmpty) ? res : '';
    } catch (e) {
      debugPrint('HomeWidgetService._toWidgetReadablePath failed: $e');
      return '';
    }
  }

  /// Привязать тип виджета к группе (вызывается при пине).
  Future<void> bindWidgetToGroup(String widgetType, String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_boundGroupPrefix$widgetType', groupId);

    debugPrint('HomeWidgetService: $widgetType bound to group $groupId');
  }

  Future<List<int>> getPhotoDayWidgetIds() async {
    if (!Platform.isAndroid) return const [];
    try {
      final ids = await _widgetChannel.invokeListMethod<dynamic>(
        'getPhotoDayWidgetIds',
      );
      return ids
              ?.map((id) => id is int ? id : int.tryParse(id.toString()))
              .whereType<int>()
              .toList() ??
          const [];
    } catch (e) {
      debugPrint('HomeWidgetService.getPhotoDayWidgetIds failed: $e');
      return const [];
    }
  }

  Future<List<int>> getPhotoGridWidgetIds() async {
    if (!Platform.isAndroid) return const [];
    try {
      final ids = await _widgetChannel.invokeListMethod<dynamic>(
        'getPhotoGridWidgetIds',
      );
      return ids
              ?.map((id) => id is int ? id : int.tryParse(id.toString()))
              .whereType<int>()
              .toList() ??
          const [];
    } catch (e) {
      debugPrint('HomeWidgetService.getPhotoGridWidgetIds failed: $e');
      return const [];
    }
  }

  String _photoDayWidgetKey(int widgetId, String suffix) =>
      'photo_day_widget_${widgetId}_$suffix';

  Future<void> enqueuePhotoDayWidgetConfig({
    required String groupId,
    required String mode,
    String kind = 'self',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getString(_photoDayPendingConfigsKey);
    final List<dynamic> pending = current == null || current.isEmpty
        ? []
        : (jsonDecode(current) as List<dynamic>);
    pending.add({
      'groupId': groupId,
      'mode': mode,
      'kind': kind,
      'path': '',
      'caption': '',
      'memoryId': '',
      'authorName': '',
      'authorUid': '',
      'viewerUid': '',
      'viewerName': '',
      'refreshSeed': 0,
    });
    await prefs.setString(_photoDayPendingConfigsKey, jsonEncode(pending));
  }

  Future<String> getPhotoDayWidgetMode(
    int widgetId, {
    String? fallbackGroupId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final widgetMode = prefs.getString(_photoDayWidgetKey(widgetId, 'mode'));
    if (widgetMode != null && widgetMode.isNotEmpty) return widgetMode;
    return 'custom';
  }

  Future<List<int>> getSelfPhotoWidgetIds() async {
    if (!Platform.isAndroid) return const [];
    try {
      final ids = await _widgetChannel.invokeListMethod<dynamic>(
        'getSelfPhotoWidgetIds',
      );
      return ids
              ?.map((id) => id is int ? id : int.tryParse(id.toString()))
              .whereType<int>()
              .toList() ??
          const [];
    } catch (e) {
      debugPrint('HomeWidgetService.getSelfPhotoWidgetIds failed: $e');
      return const [];
    }
  }

  Future<List<int>> getPartnerPhotoWidgetIds() async {
    if (!Platform.isAndroid) return const [];
    try {
      final ids = await _widgetChannel.invokeListMethod<dynamic>(
        'getPartnerPhotoWidgetIds',
      );
      return ids
              ?.map((id) => id is int ? id : int.tryParse(id.toString()))
              .whereType<int>()
              .toList() ??
          const [];
    } catch (e) {
      debugPrint('HomeWidgetService.getPartnerPhotoWidgetIds failed: $e');
      return const [];
    }
  }

  Future<void> setPhotoDayWidgetMode(int widgetId, String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_photoDayWidgetKey(widgetId, 'mode'), mode);
  }

  Future<String> getPhotoDayWidgetKind(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_photoDayWidgetKey(widgetId, 'kind'));
    if (stored != null && stored.isNotEmpty) return stored;
    final homeWidgetStored = await HomeWidget.getWidgetData<String>(
      _photoDayWidgetKey(widgetId, 'kind'),
    );
    if (homeWidgetStored != null && homeWidgetStored.isNotEmpty) {
      await prefs.setString(_photoDayWidgetKey(widgetId, 'kind'), homeWidgetStored);
      return homeWidgetStored;
    }
    final legacyDisplay = prefs.getString(
      _photoDayWidgetKey(widgetId, 'display'),
    );
    return legacyDisplay == 'partner' ? 'partner' : 'self';
  }

  Future<String?> getPhotoDayWidgetStoredKind(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_photoDayWidgetKey(widgetId, 'kind'));
    if (stored == null || stored.isEmpty) return null;
    return stored;
  }

  Future<String> getPhotoDayWidgetDisplay(int widgetId) async {
    final kind = await getPhotoDayWidgetKind(widgetId);
    return kind == 'partner' ? 'partner' : 'mine';
  }

  Future<Map<String, String>?> _getPartnerWidgetData(
    String groupId,
    String currentUserUid,
  ) async {
    if (groupId.isEmpty || currentUserUid.isEmpty) return null;

    final cacheKey = '$groupId|$currentUserUid';
    final cached = _partnerDataCache[cacheKey];
    if (cached != null && cached.isFresh) return cached.data;

    // 1. UID партнёра: сначала из native-хранилища (его пишет WidgetService при
    //    bind и читает фоновый isolate) — чтобы НЕ читать group-doc на каждый
    //    refresh. Это был дублирующий /groups read на каждый рефреш фото-виджета,
    //    в т.ч. в фоновом isolate с холодным кэшем (топ чтений в Firebase).
    String partnerUid =
        (await HomeWidget.getWidgetData<String>('love_widget_partner_uid')) ??
            '';
    String partnerName = '';
    if (partnerUid.isEmpty || partnerUid == currentUserUid) {
      // Fallback: вывести партнёра из участников группы (старый путь, +1 чтение).
      partnerUid = '';
      final resolved = await _resolvePartnerFromGroup(groupId, currentUserUid);
      if (resolved == null || resolved.uid.isEmpty) {
        _partnerDataCache[cacheKey] = _CachedWidgetData(null);
        return null;
      }
      partnerUid = resolved.uid;
      partnerName = resolved.name;
    }

    // 2. Читаем документ партнёра напрямую, а не всю коллекцию
    try {
      final wd = await _readWidgetData(groupId, partnerUid);

      if (wd != null) {
        final result = {
          'photoUrl': wd.photoForPartnerUrl ?? '',
          'photoUrls': wd.photoForPartnerUrls.join(','),
          'authorName': wd.displayName,
          'authorUid': partnerUid,
        };
        _partnerDataCache[cacheKey] = _CachedWidgetData(result);
        return result;
      }
    } catch (e) {
      debugPrint('_getPartnerWidgetData doc read failed: $e');
    }

    // Партнёр ещё не открывал виджеты — возвращаем имя из memberNames
    final result = {
      'photoUrl': '',
      'photoUrls': '',
      'authorName': partnerName.isNotEmpty ? partnerName : '',
      'authorUid': partnerUid.isNotEmpty ? partnerUid : '',
    };
    _partnerDataCache[cacheKey] = _CachedWidgetData(result);
    return result;
  }

  Future<Map<String, String>?> _getMyWidgetData(
    String groupId,
    String currentUserUid,
  ) async {
    if (groupId.isEmpty || currentUserUid.isEmpty) return null;

    final cacheKey = '$groupId|$currentUserUid';
    final cached = _myDataCache[cacheKey];
    if (cached != null && cached.isFresh) return cached.data;

    final wd = await _readWidgetData(groupId, currentUserUid);
    if (wd == null) {
      _myDataCache[cacheKey] = _CachedWidgetData(null);
      return null;
    }

    final result = {
      'authorName': wd.displayName,
      'authorUid': currentUserUid,
    };
    _myDataCache[cacheKey] = _CachedWidgetData(result);
    return result;
  }

  Future<void> _clearPhotoOfDay({
    required int widgetId,
    String? groupId,
    String authorName = '',
    String authorUid = '',
  }) async {
    await _savePhotoDayWidgetData(widgetId, {
      'path': '',
      'caption': '',
      'memory_id': '',
      'author': authorName,
      'author_uid': authorUid,
      if (groupId != null) 'group_id': groupId,
    });

    await _updateAllPhotoWidgetProviders();
  }

  Future<void> clearPhotoDayWidget(int widgetId, String groupId) async {
    await _clearPhotoOfDay(widgetId: widgetId, groupId: groupId);
  }

  Future<List<int>> getPhotoDayWidgetIdsByKind(String kind) async {
    final ids = await getPhotoDayWidgetIds();
    final filtered = <int>[];
    for (final id in ids) {
      if (await getPhotoDayWidgetKind(id) == kind) {
        filtered.add(id);
      }
    }
    return filtered;
  }

  Future<String?> getPhotoDayWidgetName(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_photoDayWidgetKey(widgetId, 'name'));
  }

  Future<void> setPhotoDayWidgetName(int widgetId, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_photoDayWidgetKey(widgetId, 'name'), name);
  }

  Future<String?> getPhotoDayWidgetGroupId(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_photoDayWidgetKey(widgetId, 'group_id'));
    if (stored != null && stored.isNotEmpty) return stored;

    final homeWidgetStored = await HomeWidget.getWidgetData<String>(
      _photoDayWidgetKey(widgetId, 'group_id'),
    );
    if (homeWidgetStored != null && homeWidgetStored.isNotEmpty) {
      await prefs.setString(
        _photoDayWidgetKey(widgetId, 'group_id'),
        homeWidgetStored,
      );
      return homeWidgetStored;
    }

    return stored;
  }

  Future<String?> getPhotoDayWidgetCustomPath(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_photoDayWidgetKey(widgetId, 'custom_path'));
  }

  Future<void> setPhotoDayWidgetCustomPath(int widgetId, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_photoDayWidgetKey(widgetId, 'custom_path'), path);
  }

  Future<int> getPhotoDayWidgetRefreshSeed(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_photoDayWidgetKey(widgetId, 'refresh_seed')) ?? 0;
  }

  Future<int> incrementPhotoDayWidgetRefreshSeed(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    final next =
        (prefs.getInt(_photoDayWidgetKey(widgetId, 'refresh_seed')) ?? 0) + 1;
    await prefs.setInt(_photoDayWidgetKey(widgetId, 'refresh_seed'), next);
    return next;
  }

  Future<String> getPhotoDayWidgetRotationType(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_photoDayWidgetKey(widgetId, 'rotation_type')) ??
        'unlock';
  }

  Future<void> setPhotoDayWidgetRotationType(int widgetId, String type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_photoDayWidgetKey(widgetId, 'rotation_type'), type);
    // Дублируем в HomeWidgetPreferences, чтобы нативный PhotoDayRotationReceiver мог прочитать.
    await HomeWidget.saveWidgetData<String>(
      _photoDayWidgetKey(widgetId, 'rotation_type'),
      type,
    );
  }

  Future<int> getPhotoDayWidgetRotationInterval(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_photoDayWidgetKey(widgetId, 'rotation_interval')) ??
        60;
  }

  Future<void> setPhotoDayWidgetRotationInterval(
    int widgetId,
    int minutes,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _photoDayWidgetKey(widgetId, 'rotation_interval'),
      minutes,
    );
    // Дублируем в HomeWidgetPreferences, чтобы нативный PhotoDayRotationReceiver мог прочитать.
    await HomeWidget.saveWidgetData<int>(
      _photoDayWidgetKey(widgetId, 'rotation_interval'),
      minutes,
    );
  }

  /// URL-ы фото конкретного виджета (независимо от других экземпляров).
  /// Хранится в SharedPreferences под ключом `photo_day_widget_{id}_urls`.
  Future<List<String>> getPhotoDayWidgetUrls(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_photoDayWidgetKey(widgetId, 'urls'));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list
            .map((e) => e?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<void> setPhotoDayWidgetUrls(int widgetId, List<String> urls) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _photoDayWidgetKey(widgetId, 'urls'),
      jsonEncode(urls),
    );
  }

  Future<void> clearPhotoDayWidgetUrls(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_photoDayWidgetKey(widgetId, 'urls'));
  }

  Future<Map<String, String?>> getPhotoDayWidgetPreview(int widgetId) async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'path': prefs.getString(_photoDayWidgetKey(widgetId, 'path')),
      'memoryId': prefs.getString(_photoDayWidgetKey(widgetId, 'memory_id')),
      'authorName': prefs.getString(_photoDayWidgetKey(widgetId, 'author')),
      'authorUid': prefs.getString(_photoDayWidgetKey(widgetId, 'author_uid')),
      'mode': prefs.getString(_photoDayWidgetKey(widgetId, 'mode')),
      'kind': prefs.getString(_photoDayWidgetKey(widgetId, 'kind')),
      'groupId': prefs.getString(_photoDayWidgetKey(widgetId, 'group_id')),
    };
  }

  Future<void> _savePhotoDayWidgetData(
    int widgetId,
    Map<String, String> values,
  ) async {
    for (final entry in values.entries) {
      final key = _photoDayWidgetKey(widgetId, entry.key);
      if (entry.key == 'refresh_seed' || entry.key == 'rotation_interval') {
        await HomeWidget.saveWidgetData<int>(
          key,
          int.tryParse(entry.value) ?? 0,
        );
      } else {
        await HomeWidget.saveWidgetData<String>(key, entry.value);
      }
    }
  }

  Future<bool> getPhotoDaySaveMemory(String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_photoSaveMemoryPrefix$groupId') ?? true;
  }

  Future<void> setPhotoDaySaveMemory(String groupId, bool save) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_photoSaveMemoryPrefix$groupId', save);
  }

  Future<int> getPhotoRefreshSeed(String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_photoRefreshSeedPrefix$groupId') ?? 0;
  }

  Future<int> incrementPhotoRefreshSeed(String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getInt('$_photoRefreshSeedPrefix$groupId') ?? 0) + 1;
    await prefs.setInt('$_photoRefreshSeedPrefix$groupId', next);
    return next;
  }

  /// Получить groupId, к которому привязан виджет. null = не привязан.
  Future<String?> getBoundGroup(String widgetType) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_boundGroupPrefix$widgetType');
  }

  // ════════════════════════════════════════════════════════════════════════
  //  1. СЧЁТЧИК ДНЕЙ ВМЕСТЕ
  // ════════════════════════════════════════════════════════════════════════

  /// Синхронизирует данные для виджета «Дни вместе».
  ///
  /// [groupId]    — идентификатор группы (обязательный).
  /// [daysCount]  — количество дней (int).
  /// [coupleNames] — «Алекс & Юля».
  /// [emoji]       — эмодзи отношений (❤️).
  /// [startDate]   — дата начала в читаемом формате (01.06.2024).
  Future<void> syncDaysCounter({
    required String groupId,
    required int daysCount,
    required String coupleNames,
    String emoji = '❤️',
    String startDate = '',
    String myGender = '',
    String partnerGender = '',
  }) async {
    try {
      // Solo mode uses 'solo' as sentinel so Kotlin WidgetGroupHelper
      // gets a non-empty days_counter_latest_group and can find the data.
      final g = groupId.isEmpty ? 'solo' : groupId;
      await HomeWidget.saveWidgetData<String>(
        'days_${g}_count',
        daysCount.toString(),
      );
      await HomeWidget.saveWidgetData<String>('days_${g}_couple_names', coupleNames);
      await HomeWidget.saveWidgetData<String>('days_${g}_relationship_emoji', emoji);
      await HomeWidget.saveWidgetData<String>('days_${g}_start_date', startDate);
      await HomeWidget.saveWidgetData<String>('days_${g}_my_gender', myGender);
      await HomeWidget.saveWidgetData<String>('days_${g}_partner_gender', partnerGender);
      // Кешируем для syncTimerAndDays — тот не имеет доступа к данным профиля
      if (myGender.isNotEmpty) _cachedMyGender = myGender;
      if (partnerGender.isNotEmpty) _cachedPartnerGender = partnerGender;
      // Kotlin WidgetGroupHelper looks up "days_counter_latest_group" (dataType = widgetType)
      await HomeWidget.saveWidgetData<String>('days_counter_latest_group', g);
      await HomeWidget.updateWidget(
        name: 'DaysCounterWidgetProvider',
        androidName: 'DaysCounterWidgetProvider',
      );
      debugPrint('HomeWidgetService: days counter synced — $daysCount days (group=$groupId)');
    } catch (e) {
      debugPrint('HomeWidgetService.syncDaysCounter failed: $e');
    }
  }

  static const _daysPhotosEnabledKey = 'days_widget_photos_enabled';

  /// Включены ли свои фото пары на виджете «Дни вместе» (локальный кэш состояния).
  Future<bool> isDaysCounterPhotosEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_daysPhotosEnabledKey) ?? false;
  }

  /// Включает/выключает показ фото пары на виджете «Дни вместе».
  ///
  /// При включении кэширует обе аватарки в локальные файлы и пишет их пути +
  /// флаг `days_${g}_use_photos`. Нативный виджет читает их и рисует кружочки
  /// вместо нарисованной пары. Если хотя бы одной аватарки нет — откатываемся
  /// на рисунок (use_photos='0').
  Future<void> setDaysCounterPhotos({
    required String groupId,
    required bool enabled,
    required String myAvatarUrl,
    required String partnerAvatarUrl,
  }) async {
    final g = groupId.isEmpty ? 'solo' : groupId;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_daysPhotosEnabledKey, enabled);

      String myPath = '';
      String partnerPath = '';
      if (enabled) {
        myPath = await _cachePhotoFromUrl(myAvatarUrl, 'days_avatar_my_$g');
        partnerPath =
            await _cachePhotoFromUrl(partnerAvatarUrl, 'days_avatar_partner_$g');
      }
      // Включаем только когда обе аватарки реально закэшировались.
      final usePhotos = enabled && myPath.isNotEmpty && partnerPath.isNotEmpty;

      await HomeWidget.saveWidgetData<String>(
        'days_${g}_use_photos',
        usePhotos ? '1' : '0',
      );
      await HomeWidget.saveWidgetData<String>('days_${g}_my_avatar_path', myPath);
      await HomeWidget.saveWidgetData<String>(
        'days_${g}_partner_avatar_path',
        partnerPath,
      );
      await HomeWidget.saveWidgetData<String>('days_counter_latest_group', g);
      await HomeWidget.updateWidget(
        name: 'DaysCounterWidgetProvider',
        androidName: 'DaysCounterWidgetProvider',
      );
      debugPrint(
        'HomeWidgetService.setDaysCounterPhotos: enabled=$enabled usePhotos=$usePhotos group=$g',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.setDaysCounterPhotos failed: $e');
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  1b. ОГОНЁК ПАРЫ  (серия дней подряд)
  // ════════════════════════════════════════════════════════════════════════

  /// Синхронизирует виджет «Огонёк пары» — сколько дней подряд пара заходила.
  ///
  /// [streakDays]     — текущая серия (дней подряд).
  /// [recordStreak]   — рекорд серии (для подписи «Рекорд: N»).
  /// [lastOpenedDate] — дата последнего совместного захода «YYYY-MM-DD».
  ///   По ней нативный виджет сам решает, «горит» серия или потухла, поэтому
  ///   счётчик корректно обнуляется даже без открытия приложения.
  Future<void> syncStreak({
    required int streakDays,
    int recordStreak = 0,
    String lastOpenedDate = '',
  }) async {
    try {
      await HomeWidget.saveWidgetData<String>(
        'streak_days',
        streakDays.toString(),
      );
      await HomeWidget.saveWidgetData<String>(
        'streak_record',
        recordStreak.toString(),
      );
      await HomeWidget.saveWidgetData<String>(
        'streak_last_date',
        lastOpenedDate,
      );
      await HomeWidget.updateWidget(
        name: 'StreakWidgetProvider',
        androidName: 'StreakWidgetProvider',
      );
      debugPrint(
        'HomeWidgetService: streak synced — $streakDays days '
        '(record=$recordStreak, last=$lastOpenedDate)',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.syncStreak failed: $e');
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  2. ТАЙМЕР / ОБРАТНЫЙ ОТСЧЁТ
  // ════════════════════════════════════════════════════════════════════════

  /// Синхронизирует данные выбранного таймера.
  ///
  /// Передаётся [TimerItem] — текущий дефолтный или выбранный таймер.
  /// [groupId] — идентификатор группы (обязательный).
  Future<void> syncTimer(
    TimerItem timer, {
    required String groupId,
    bool? isRomantic,
    int? themeIndex,
  }) async {
    try {
      // Solo mode uses 'solo' as sentinel so Kotlin WidgetGroupHelper
      // gets a non-empty latest_group and can find the data.
      final g = groupId.isEmpty ? 'solo' : groupId;
      debugPrint(
        'HomeWidgetService.syncTimer: START title=${timer.title} startMs=${timer.startDate.millisecondsSinceEpoch} group=$g',
      );
      // Если вызов не передал тему/романтичность (напр. синк из TimerService по
      // серии/дате) — берём ПОСЛЕДНИЕ известные, чтобы не сбрасывать активную
      // тему лепесткового виджета на дефолт.
      final romantic = isRomantic ?? _lastIsRomantic;
      final theme = themeIndex ?? _lastThemeIndex;
      _lastIsRomantic = romantic;
      _lastThemeIndex = theme;

      await HomeWidget.saveWidgetData<String>('timer_${g}_title', timer.title);
      await HomeWidget.saveWidgetData<String>(
        'timer_${g}_days',
        timer.daysElapsed.toString(),
      );
      await HomeWidget.saveWidgetData<String>(
        'timer_${g}_is_countdown',
        timer.isCountdown ? '1' : '0',
      );
      await HomeWidget.saveWidgetData<String>(
        'timer_${g}_date',
        timer.formattedStartDate,
      );
      // Дата старта в мс — нужна PetalTimerWidgetProvider для вычисления лепестков
      await HomeWidget.saveWidgetData<String>(
        'timer_${g}_start_ms',
        timer.startDate.millisecondsSinceEpoch.toString(),
      );
      // Флаг темы: 1 = романтическая (сердце/розовый), 0 = нейтральная (звезда/жёлтый)
      await HomeWidget.saveWidgetData<String>(
        'timer_${g}_is_romantic',
        romantic ? '1' : '0',
      );
      // Индекс темы приложения (0=pink,1=purple,2=blue,3=orange,4=green) для лепесткового виджета
      await HomeWidget.saveWidgetData<String>(
        'timer_${g}_petal_theme',
        theme.toString(),
      );
      // Точные цвета активной темы (fg = акцент/primary, bg = фон лепестков),
      // чтобы ЛЮБАЯ из 20 тем совпадала с приложением, а не схлопывалась в
      // 5-цветную натив-палитру по индексу.
      final pt = AppThemes.byIndex(theme);
      String petalHex(int argb) =>
          '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
      await HomeWidget.saveWidgetData<String>(
        'timer_${g}_petal_bg',
        petalHex(pt.timerDialBackground.value),
      );
      await HomeWidget.saveWidgetData<String>(
        'timer_${g}_petal_fg',
        petalHex(pt.primary.value),
      );
      // Save latest group for fallback binding (use 'solo' sentinel for solo mode)
      await HomeWidget.saveWidgetData<String>('timer_latest_group', g);
      await HomeWidget.saveWidgetData<String>('petal_timer_latest_group', g);
      await HomeWidget.updateWidget(
        name: 'TimerWidgetProvider',
        androidName: 'TimerWidgetProvider',
      );
      await HomeWidget.updateWidget(
        name: 'PetalTimerWidgetProvider',
        androidName: 'PetalTimerWidgetProvider',
      );
      debugPrint(
        'HomeWidgetService: timer synced — ${timer.title}, days=${timer.daysElapsed}, startMs=${timer.startDate.millisecondsSinceEpoch}, group=$g',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.syncTimer failed: $e');
    }
  }

  /// Синхронизирует Timer-виджет И Days Counter одним вызовом.
  /// Вызывается из TimerService._syncWidgetTimer, чтобы оба виджета
  /// всегда обновлялись вместе при любом изменении активного таймера.
  Future<void> syncTimerAndDays(TimerItem timer, {required String groupId}) async {
    await syncTimer(timer, groupId: groupId);
    // Days Counter: обновляем дни, дату И гендерные данные из кеша,
    // чтобы картинка пары всегда соответствовала полу пользователей.
    try {
      final g = groupId.isEmpty ? 'solo' : groupId;
      await HomeWidget.saveWidgetData<String>(
        'days_${g}_count',
        timer.daysElapsed.abs().toString(),
      );
      await HomeWidget.saveWidgetData<String>(
        'days_${g}_start_date',
        _formatDate(timer.startDate),
      );
      // Гендер из кеша — заполняется при syncAllBoundWidgets
      await HomeWidget.saveWidgetData<String>('days_${g}_my_gender', _cachedMyGender);
      await HomeWidget.saveWidgetData<String>('days_${g}_partner_gender', _cachedPartnerGender);
      await HomeWidget.saveWidgetData<String>('days_counter_latest_group', g);
      await HomeWidget.updateWidget(
        name: 'DaysCounterWidgetProvider',
        androidName: 'DaysCounterWidgetProvider',
      );
      debugPrint(
        'HomeWidgetService.syncTimerAndDays: days=${timer.daysElapsed.abs()} myGender=$_cachedMyGender partnerGender=$_cachedPartnerGender group=$g',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.syncTimerAndDays days part failed: $e');
    }
  }

  /// Очистить данные таймера в виджете (соло-режим, нет таймеров)
  Future<void> clearTimerWidget() async {
    try {
      // Сбрасываем ключи соло-группы
      await HomeWidget.saveWidgetData<String>('timer_solo_title', '');
      await HomeWidget.saveWidgetData<String>('timer_solo_days', '0');
      await HomeWidget.saveWidgetData<String>('timer_solo_is_countdown', '0');
      await HomeWidget.saveWidgetData<String>('timer_solo_date', '');
      await HomeWidget.saveWidgetData<String>('timer_solo_start_ms', '0');
      await HomeWidget.saveWidgetData<String>('timer_latest_group', 'solo');
      await HomeWidget.saveWidgetData<String>('petal_timer_latest_group', 'solo');
      await HomeWidget.updateWidget(
        name: 'TimerWidgetProvider',
        androidName: 'TimerWidgetProvider',
      );
      await HomeWidget.updateWidget(
        name: 'PetalTimerWidgetProvider',
        androidName: 'PetalTimerWidgetProvider',
      );
      debugPrint('HomeWidgetService: timer widget cleared');
    } catch (e) {
      debugPrint('HomeWidgetService.clearTimerWidget failed: $e');
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  3. ФОТО ДНЯ  (Memory Lane)
  // ════════════════════════════════════════════════════════════════════════

  Future<void> syncPhotoOfDayCarousel({
    required List<String> photoUrls, // can be network URLs or local file paths
    String authorName = '',
    String authorUid = '',
    int? widgetId,
    String? groupId,
  }) async {
    try {
      final viewerUid = PocketBaseService().userId ?? '';
      final viewerName = (PbAuthService().currentProfile()?['displayName'] as String? ?? '');

      List<String> localPaths = [];
      final dir = await getApplicationSupportDirectory();

      for (int i = 0; i < photoUrls.length; i++) {
        final url = photoUrls[i];
        if (url.startsWith('http') ||
            url.startsWith('gs://') ||
            url.startsWith('sb://') ||
            url.startsWith('pb://')) {
          // pb:// резолвится в http+token внутри _cachePhotoFromUrl и
          // скачивается локально; File(pb://) не существует, поэтому без этой
          // ветки фото не кэшировалось и нативный виджет получал пустой путь.
          final p = await _cachePhotoFromUrl(
            url,
            'photo_day_carousel_${widgetId}_$i',
          );
          if (p.isNotEmpty) localPaths.add(p);
        } else {
          final file = File(url);
          if (file.existsSync()) {
            final suffix = widgetId != null ? '_${widgetId}_$i' : '_$i';
            final target = File('${dir.path}/widget_photo_day$suffix.jpg');
            await file.copy(target.path);
            final readable =
                await _toWidgetReadablePath(target.path, 'photo_day$suffix');
            if (readable.isNotEmpty) localPaths.add(readable);
          }
        }
      }

      final pathsJson = jsonEncode(localPaths);

      // Flutter-side index management.
      // "unlock" rotation is handled entirely by the native alarm
      // (PhotoDayRotationReceiver + ELAPSED_REALTIME_WAKEUP alarm). Flutter must
      // NOT advance for "unlock" here — doing so on every sync causes the photo
      // to cycle rapidly and also shows the wrong initial photo on first setup.
      // Flutter only advances for "time" mode as a backup for when the device is
      // awake and the 15-min alarm fires less precisely than the interval.
      int displayIndex = 0;
      if (widgetId != null && localPaths.length > 1) {
        final prefs = await SharedPreferences.getInstance();
        final indexKey = 'fcidx_$widgetId';
        final storedIndex = prefs.getInt(indexKey) ?? 0;

        final rotationType = await getPhotoDayWidgetRotationType(widgetId);
        if (rotationType == 'time') {
          final tsKey = 'fclts_$widgetId';
          final rotationIntervalMin =
              await getPhotoDayWidgetRotationInterval(widgetId);
          final lastAdvanceMs = prefs.getInt(tsKey) ?? 0;
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - lastAdvanceMs >= rotationIntervalMin * 60 * 1000) {
            displayIndex = (storedIndex + 1) % localPaths.length;
            await prefs.setInt(indexKey, displayIndex);
            await prefs.setInt(tsKey, nowMs);
            debugPrint(
              'HomeWidgetService: time-based advance widget $widgetId'
              ' → idx $displayIndex',
            );
          } else {
            displayIndex = storedIndex % localPaths.length;
          }
        } else {
          // "unlock" or "none": the native PhotoDayRotationReceiver owns the
          // current index and writes it to HomeWidgetPreferences.
          // Flutter's own `fcidx_N` lives in FlutterSharedPreferences — a
          // DIFFERENT file — so it never sees advances made by the native
          // receiver while the app was closed.  Read the authoritative native
          // index directly so we don't overwrite the receiver's progress on
          // every app open.
          final nativeIndex = await HomeWidget.getWidgetData<int>(
            _photoDayWidgetKey(widgetId, 'current_index'),
          );
          displayIndex = (nativeIndex ?? storedIndex) % localPaths.length;
          // Keep Flutter's cache in sync.
          await prefs.setInt(indexKey, displayIndex);
        }
      }

      if (widgetId != null) {
        // Determine kind from widgetId
        final kind = await getPhotoDayWidgetKind(widgetId);
        await _savePhotoDayWidgetData(widgetId, {
          'paths': pathsJson,
          'path': localPaths.isNotEmpty ? localPaths[displayIndex] : '',
          'author': authorName,
          'author_uid': authorUid,
          'viewer_uid': viewerUid,
          'viewer_name': viewerName,
          'kind': kind,
          if (groupId != null) 'group_id': groupId,
        });

        // Sync index to Kotlin so the native alarm resumes from the right position.
        await _widgetChannel.invokeMethod('updatePhotoDayCarousel', {
          'widgetId': widgetId,
          'paths': localPaths,
          'currentIndex': displayIndex,
        });
      }

      await _updateAllPhotoWidgetProviders();
      debugPrint(
        'HomeWidgetService: carousel synced — ${localPaths.length} photos',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.syncPhotoOfDayCarousel failed: $e');
    }
  }

  Future<void> syncPhotoOfDay({
    required String photoUrl,
    String caption = '',
    String memoryId = '',
    String authorName = '',
    String authorUid = '',
    File? localFile,
    int? widgetId,
    String? groupId,
    int? refreshSeed,
  }) async {
    try {
      String localPath = '';
      if (localFile != null) {
        // Если передали файл напрямую (с устройства) — копируем его в кэш виджета
        final dir = await getApplicationSupportDirectory();
        final suffix = widgetId != null ? '_$widgetId' : '';
        final file = File('${dir.path}/widget_photo_day$suffix.jpg');
        await localFile.copy(file.path);
        localPath = await _toWidgetReadablePath(file.path, 'photo_day$suffix');
      } else {
        localPath = await _cachePhotoFromUrl(
          photoUrl,
          widgetId != null ? 'photo_day_$widgetId' : 'photo_day',
        );
      }

      final viewerUid = PocketBaseService().userId ?? '';
      final viewerName = (PbAuthService().currentProfile()?['displayName'] as String? ?? '');

      if (widgetId != null) {
        // Determine kind from widgetId
        final kind = await getPhotoDayWidgetKind(widgetId);
        await _savePhotoDayWidgetData(widgetId, {
          'path': localPath,
          'caption': caption,
          'memory_id': memoryId,
          'author': authorName,
          'author_uid': authorUid,
          'viewer_uid': viewerUid,
          'viewer_name': viewerName,
          'kind': kind,
          if (groupId != null) 'group_id': groupId,
          if (refreshSeed != null) 'refresh_seed': refreshSeed.toString(),
        });
      } else {
        await HomeWidget.saveWidgetData<String>('photo_day_path', localPath);
        await HomeWidget.saveWidgetData<String>('photo_day_caption', caption);
        await HomeWidget.saveWidgetData<String>(
          'photo_day_memory_id',
          memoryId,
        );
        await HomeWidget.saveWidgetData<String>('photo_day_author', authorName);
        await HomeWidget.saveWidgetData<String>(
          'photo_day_author_uid',
          authorUid,
        );
        await HomeWidget.saveWidgetData<String>(
          'photo_day_viewer_uid',
          viewerUid,
        );
        await HomeWidget.saveWidgetData<String>(
          'photo_day_viewer_name',
          viewerName,
        );
      }
      await _updateAllPhotoWidgetProviders();
      debugPrint(
        'HomeWidgetService: photo of day synced — $memoryId (path=$localPath)',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.syncPhotoOfDay failed: $e');
    }
  }

  /// Выбирает фото для виджета "Фото дня" и синхронизирует его.
  ///
  /// [forceNext] — если true, инкрементирует seed, чтобы выбрать следующее фото.
  /// [widgetId] — конкретный ID виджета (null = все виджеты этого groupId).
  /// [overrideKind] — явный тип виджета ('partner'/'self'), обходит SharedPreferences.
  ///   Используется для предотвращения race condition при первом запуске.
  /// Works for both group mode and single user mode (no group).
  Future<void> refreshPhotoOfDay(
    String groupId, {
    bool forceNext = false,
    int? widgetId,
    String? overrideKind,
  }) async {
    try {
      // If no widgetId specified, refresh all photo day widgets for this group
      if (widgetId == null) {
        final allIds = await getPhotoDayWidgetIds();
        // Определяем partner-виджеты заранее, чтобы принудительно передать kind='partner'.
        // Без этого race condition: если refreshPhotoOfDay сработает до Kotlin onUpdate(),
        // SharedPreferences будет пустым и kind вернётся как 'self', что сломает виджет навсегда.
        Set<int> partnerIds = const {};
        if (Platform.isAndroid) {
          partnerIds = (await getPartnerPhotoWidgetIds()).toSet();
        }
        for (final id in allIds) {
          final widgetGroupId = await getPhotoDayWidgetGroupId(id);
          // Sync if: no group bound, or bound to current group, or no groupId at all (single user)
          if (widgetGroupId == null ||
              widgetGroupId.isEmpty ||
              widgetGroupId == groupId) {
            await refreshPhotoOfDay(
              groupId,
              widgetId: id,
              forceNext: forceNext,
              overrideKind: partnerIds.contains(id) ? 'partner' : null,
            );
          }
        }
        return;
      }

      // Single user mode (no group): use widget's own stored URLs
      if (groupId.isEmpty) {
        await _syncPhotoDayWidgetSingleUser(widgetId, forceNext: forceNext);
        return;
      }

      // overrideKind предотвращает race condition: если kind ещё не записан Kotlin-ом,
      // getPhotoDayWidgetKind вернёт 'self' по умолчанию и permanently сломает виджет.
      final selectedKind = overrideKind ?? await getPhotoDayWidgetKind(widgetId);

      // Сохраняем текущий профиль (viewer) для различения моего/партнёрского фото
      final currentUserUid = PocketBaseService().userId ?? '';
      final currentUserName = (PbAuthService().currentProfile()?['displayName'] as String? ?? '');

      await _savePhotoDayWidgetData(widgetId, {
        'viewer_uid': currentUserUid,
        'viewer_name': currentUserName,
        'mode': 'custom',
        'kind': selectedKind,
        'group_id': groupId,
      });

      final List<String> ownWidgetUrls = await getPhotoDayWidgetUrls(widgetId);

      Map<String, String>? targetData;
      if (selectedKind == 'partner') {
        targetData = await _getPartnerWidgetData(groupId, currentUserUid);
      } else {
        targetData = await _getMyWidgetData(groupId, currentUserUid);
      }

      final targetPhotoUrl = targetData?['photoUrl'] ?? '';
      final targetPhotoUrlsRaw = targetData?['photoUrls'] ?? '';
      List<String> targetPhotoUrls = targetPhotoUrlsRaw.isNotEmpty
          ? targetPhotoUrlsRaw.split(',')
          : [];

      if (selectedKind != 'partner' && ownWidgetUrls.isNotEmpty) {
        targetPhotoUrls = ownWidgetUrls;
      }

      final bool targetHasCustomPhoto = selectedKind == 'partner'
          ? (targetPhotoUrl.isNotEmpty || targetPhotoUrls.isNotEmpty)
          : ownWidgetUrls.isNotEmpty;

      if (targetHasCustomPhoto) {
        debugPrint(
          'HomeWidgetService: showing photo '
          '(kind=$selectedKind) '
          'author=${targetData?['authorName']} uid=${targetData?['authorUid']}',
        );

        if (targetPhotoUrls.length > 1) {
          await syncPhotoOfDayCarousel(
            photoUrls: targetPhotoUrls,
            authorName: targetData?['authorName'] ?? '',
            authorUid: targetData?['authorUid'] ?? '',
            widgetId: widgetId,
            groupId: groupId,
          );
        } else {
          await syncPhotoOfDay(
            photoUrl: targetPhotoUrls.isNotEmpty
                ? targetPhotoUrls.first
                : targetPhotoUrl,
            caption: '',
            memoryId: '',
            authorName: targetData?['authorName'] ?? '',
            authorUid: targetData?['authorUid'] ?? '',
            widgetId: widgetId,
            groupId: groupId,
          );
        }
        return;
      }

      await _clearPhotoOfDay(
        widgetId: widgetId,
        groupId: groupId,
        authorName: targetData?['authorName'] ?? '',
        authorUid: targetData?['authorUid'] ?? '',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.refreshPhotoOfDay failed: $e');
    }
  }

  /// Синхронизация фото виджета для одиночного режима (без группы).
  /// Использует собственные URL-ы виджета.
  Future<void> _syncPhotoDayWidgetSingleUser(
    int widgetId, {
    bool forceNext = false,
  }) async {
    try {
      final currentUserUid = PocketBaseService().userId ?? '';
      final currentUserName = (PbAuthService().currentProfile()?['displayName'] as String? ?? '');

      final selectedKind = await getPhotoDayWidgetKind(widgetId);

      // 'solo' sentinel so getPhotoDayWidgetGroupId returns non-null/'solo',
      // which prevents pair-mode shouldSync from falsely matching this widget.
      await _savePhotoDayWidgetData(widgetId, {
        'viewer_uid': currentUserUid,
        'viewer_name': currentUserName,
        'mode': 'custom',
        'kind': selectedKind,
        'group_id': 'solo',
      });

      // For single user, use widget's own stored URLs
      final ownUrls = await getPhotoDayWidgetUrls(widgetId);
      final customPath = await getPhotoDayWidgetCustomPath(widgetId);

      if (ownUrls.isNotEmpty) {
        if (ownUrls.length > 1) {
          // Multiple photos — let the native rotation receiver handle cycling.
          // syncPhotoOfDayCarousel caches all files, saves `paths` and `path`,
          // and calls updatePhotoDayCarousel so the Kotlin receiver can rotate.
          await syncPhotoOfDayCarousel(
            photoUrls: ownUrls,
            authorName: currentUserName,
            authorUid: currentUserUid,
            widgetId: widgetId,
          );
          // syncPhotoOfDayCarousel already calls _updateAllPhotoWidgetProviders.
          debugPrint(
            'HomeWidgetService: photo day (single user) synced for widget $widgetId',
          );
          return;
        }

        // Single photo — cache and display directly.
        final selectedUrl = ownUrls.first;
        final localPath = (selectedUrl.startsWith('http') ||
                selectedUrl.startsWith('gs://') ||
                selectedUrl.startsWith('sb://') ||
                selectedUrl.startsWith('pb://'))
            ? await _cachePhotoFromUrl(selectedUrl, 'photo_day_solo_$widgetId')
            : selectedUrl;

        await _savePhotoDayWidgetData(widgetId, {
          'path': localPath,
          'author': currentUserName,
          'author_uid': currentUserUid,
        });
      } else if (customPath != null && customPath.isNotEmpty) {
        // Use custom local photo
        await _savePhotoDayWidgetData(widgetId, {
          'path': customPath,
          'refresh_seed': '0',
          'author': currentUserName,
          'author_uid': currentUserUid,
        });
      } else {
        // No photos - clear
        await _savePhotoDayWidgetData(widgetId, {
          'path': '',
          'refresh_seed': '0',
        });
      }

      await _updateAllPhotoWidgetProviders();
      debugPrint(
        'HomeWidgetService: photo day (single user) synced for widget $widgetId',
      );
    } catch (e) {
      debugPrint('HomeWidgetService._syncPhotoDayWidgetSingleUser failed: $e');
    }
  }

  /// Вызывается при удалении воспоминания, чтобы убрать его из виджете, если оно там отображалось
  Future<void> handleMemoryDeleted(
    String groupId,
    String deletedMemoryId,
  ) async {
    try {
      final currentMemoryId = await HomeWidget.getWidgetData<String>(
        'photo_day_memory_id',
      );
      if (currentMemoryId == deletedMemoryId) {
        debugPrint(
          'HomeWidgetService: Deleted memory was displayed in widget. Updating...',
        );

        // Временно очищаем виджет
        await HomeWidget.saveWidgetData<String>('photo_day_path', '');
        await HomeWidget.saveWidgetData<String>('photo_day_caption', '');
        await HomeWidget.saveWidgetData<String>('photo_day_memory_id', '');
        await HomeWidget.saveWidgetData<String>('photo_day_author', '');
        await _updateAllPhotoWidgetProviders();

        // Пытаемся загрузить новое случайное фото
        await refreshPhotoOfDay(groupId);
      }
    } catch (e) {
      debugPrint('HomeWidgetService.handleMemoryDeleted failed: $e');
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  4. НАСТРОЕНИЕ
  // ════════════════════════════════════════════════════════════════════════

  /// Синхронизирует виджет настроения.
  ///
  /// [moodEmojiAssetPath]        — путь к ассету моего эмодзи (напр. 'assets/images/emoji/033-love.png').
  /// [moodLabel]                 — текстовое название моего настроения.
  /// [moodColor]                 — цвет моего настроения (hex).
  /// [userName]                  — моё имя.
  /// [partnerMoodEmojiAssetPath] — путь к ассету эмодзи партнёра.
  /// [partnerMoodLabel]          — текстовое название настроения партнёра.
  /// [partnerMoodColor]          — цвет настроения партнёра (hex).
  /// [partnerUserName]           — имя партнёра.
  /// [noMoodText]                — локализованный текст «нет настроения».
  /// [nameFallbackMe]            — локализованный «Я/Me».
  /// [nameFallbackPartner]       — локализованный «Партнёр/Partner».
  /// [ratingPrefix]              — локализованный «Оценка/Rating».
  Future<void> syncMood({
    required String groupId,
    required String moodEmojiAssetPath,
    required String moodLabel,
    required int moodScore,
    String moodColor = '',
    String userName = '',
    String partnerMoodEmojiAssetPath = '',
    String partnerMoodLabel = '',
    String partnerMoodColor = '',
    required int partnerMoodScore,
    String partnerUserName = '',
    String noMoodText = '',
    String nameFallbackMe = '',
    String nameFallbackPartner = '',
    String ratingPrefix = '',
  }) async {
    if (moodEmojiAssetPath.isEmpty &&
        moodLabel.isEmpty &&
        moodScore == 0 &&
        partnerMoodEmojiAssetPath.isEmpty &&
        partnerMoodLabel.isEmpty &&
        partnerMoodScore == 0) {
      debugPrint('HomeWidgetService.syncMood skipped: no mood data to save');
      return;
    }

    try {
      final g = groupId;
      // ── Моё настроение ──
      String myLocalPath = '';
      if (moodEmojiAssetPath.isNotEmpty) {
        myLocalPath = await _copyAssetToLocal(moodEmojiAssetPath);
      }
      await HomeWidget.saveWidgetData<String>('mood_emoji_path', myLocalPath);
      await HomeWidget.saveWidgetData<String>('mood_label', moodLabel);
      await HomeWidget.saveWidgetData<String>('mood_user_name', userName);
      await HomeWidget.saveWidgetData<int>('mood_score', moodScore);
      await HomeWidget.saveWidgetData<String>('mood_color', moodColor);
      await HomeWidget.saveWidgetData<int>('user_count', 2);
      await HomeWidget.saveWidgetData<String>('user_0_emoji_path', myLocalPath);
      await HomeWidget.saveWidgetData<String>('user_0_name', userName);
      await HomeWidget.saveWidgetData<String>('user_0_label', moodLabel);
      // Group-prefixed score, color and label keys (read by MoodWidgetProvider)
      await HomeWidget.saveWidgetData<int>('mood_${g}_user_0_score', moodScore);
      await HomeWidget.saveWidgetData<String>('mood_${g}_user_0_color', moodColor);
      await HomeWidget.saveWidgetData<String>('mood_${g}_user_0_label', moodLabel);

      // ── Настроение партнёра ──
      String partnerLocalPath = '';
      if (partnerMoodEmojiAssetPath.isNotEmpty) {
        partnerLocalPath = await _copyAssetToLocal(partnerMoodEmojiAssetPath);
      }
      await HomeWidget.saveWidgetData<String>(
        'partner_mood_emoji_path',
        partnerLocalPath,
      );
      await HomeWidget.saveWidgetData<String>(
        'partner_mood_label',
        partnerMoodLabel,
      );
      await HomeWidget.saveWidgetData<String>(
        'partner_mood_user_name',
        partnerUserName,
      );
      await HomeWidget.saveWidgetData<String>(
        'user_1_emoji_path',
        partnerLocalPath,
      );
      await HomeWidget.saveWidgetData<String>('user_1_name', partnerUserName);
      await HomeWidget.saveWidgetData<String>('user_1_label', partnerMoodLabel);
      // Group-prefixed score, color and label keys (read by MoodWidgetProvider)
      await HomeWidget.saveWidgetData<int>('mood_${g}_user_1_score', partnerMoodScore);
      await HomeWidget.saveWidgetData<String>('mood_${g}_user_1_color', partnerMoodColor);
      await HomeWidget.saveWidgetData<String>('mood_${g}_user_1_label', partnerMoodLabel);
      await HomeWidget.saveWidgetData<int>(
        'partner_mood_score',
        partnerMoodScore,
      );
      // Save latest group for fallback binding
      await HomeWidget.saveWidgetData<String>('mood_latest_group', groupId);

      // ── Локализованные строки для нативного виджета ──
      await HomeWidget.saveWidgetData<String>(
        'no_mood_text',
        noMoodText.isNotEmpty ? noMoodText : 'Пока нет данных',
      );
      await HomeWidget.saveWidgetData<String>(
        'name_fallback_me',
        nameFallbackMe.isNotEmpty ? nameFallbackMe : 'Вы',
      );
      await HomeWidget.saveWidgetData<String>(
        'name_fallback_partner',
        nameFallbackPartner.isNotEmpty ? nameFallbackPartner : 'Партнёр',
      );
      await HomeWidget.saveWidgetData<String>(
        'rating_prefix',
        ratingPrefix.isNotEmpty ? ratingPrefix : 'Оценка',
      );

      await HomeWidget.updateWidget(
        name: 'MoodWidgetProvider',
        androidName: 'MoodWidgetProvider',
      );
      debugPrint(
        'HomeWidgetService: mood synced — me=$moodLabel, partner=$partnerMoodLabel',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.syncMood failed: $e');
    }
  }

  /// Синхронизирует данные настроения для MoodWidgetProvider (групповой формат до 4 человек).
  ///
  /// [members] — список мап, где ключи 'name' и 'emojiPath'.
  Future<void> syncGroupMood(List<Map<String, String>> members) async {
    try {
      await HomeWidget.saveWidgetData<int>('user_count', members.length);
      for (int i = 0; i < members.length; i++) {
        final member = members[i];
        final emojiAsset = member['emojiPath'] ?? '';
        String localPath = '';
        if (emojiAsset.isNotEmpty) {
          localPath = await _copyAssetToLocal(emojiAsset);
        }
        await HomeWidget.saveWidgetData<String>(
          'user_${i}_emoji_path',
          localPath,
        );
        await HomeWidget.saveWidgetData<String>(
          'user_${i}_name',
          member['name'] ?? '',
        );
      }

      await HomeWidget.updateWidget(
        name: 'MoodWidgetProvider',
        androidName: 'MoodWidgetProvider',
      );
      debugPrint(
        'HomeWidgetService: group mood synced for ${members.length} users',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.syncGroupMood failed: $e');
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  5. RELATIONSHIP STATS
  // ════════════════════════════════════════════════════════════════════════

  /// Синхронизирует данные для виджета «Статистика отношений».
  /// [groupId] — идентификатор группы (обязательный).
  Future<void> syncRelationshipStats({
    required String groupId,
    required int daysTogether,
    required int memoriesCount,
    required int drawingsCount,
    required int missYouCount,
    String? daysLabel,
    String? memoriesLabel,
    String? drawingsLabel,
    String? missYouLabel,
  }) async {
    try {
      final g = groupId;
      await HomeWidget.saveWidgetData<String>(
        'stats_${g}_days',
        daysTogether.toString(),
      );
      await HomeWidget.saveWidgetData<String>(
        'stats_${g}_memories',
        memoriesCount.toString(),
      );
      await HomeWidget.saveWidgetData<String>(
        'stats_${g}_drawings',
        drawingsCount.toString(),
      );
      await HomeWidget.saveWidgetData<String>(
        'stats_${g}_miss_you',
        missYouCount.toString(),
      );

      if (daysLabel != null)
        await HomeWidget.saveWidgetData<String>('stats_${g}_days_label', daysLabel);
      if (memoriesLabel != null)
        await HomeWidget.saveWidgetData<String>(
          'stats_${g}_memories_label',
          memoriesLabel,
        );
      if (drawingsLabel != null)
        await HomeWidget.saveWidgetData<String>(
          'stats_${g}_drawings_label',
          drawingsLabel,
        );
      if (missYouLabel != null)
        await HomeWidget.saveWidgetData<String>(
          'stats_${g}_miss_you_label',
          missYouLabel,
        );

      // Save latest group for fallback binding
      await HomeWidget.saveWidgetData<String>('stats_latest_group', groupId);

      await HomeWidget.updateWidget(
        name: 'RelationshipStatsWidgetProvider',
        androidName: 'RelationshipStatsWidgetProvider',
      );
      debugPrint('HomeWidgetService: relationship stats synced (group=$groupId)');
    } catch (e) {
      debugPrint('HomeWidgetService.syncRelationshipStats failed: $e');
    }
  }

  // Кэш для refreshRelationshipStats: внутри платные Firestore операции
  // (group doc get) — а вызывается на каждый syncAllBoundWidgets.
  // Counts меняются медленно, дёргать их чаще раза в несколько минут нет смысла.
  // In-memory кэш сбрасывается при холодном старте — поэтому дублируем в SharedPreferences.
  static const Duration _relStatsCacheTtl = Duration(minutes: 5);
  final Map<String, _CachedRelStats> _relStatsCache = {};

  static String _relStatsPrefKey(String groupId, String field) =>
      'relStats_${groupId}_$field';

  Future<_CachedRelStats?> _loadRelStatsFromPrefs(String groupId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(_relStatsPrefKey(groupId, 'ts'));
      if (ts == null) return null;
      final age = DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(ts));
      if (age > _relStatsCacheTtl) return null;
      return _CachedRelStats(
        memoriesCount: prefs.getInt(_relStatsPrefKey(groupId, 'mem')) ?? 0,
        drawingsCount: prefs.getInt(_relStatsPrefKey(groupId, 'drw')) ?? 0,
        missYouCount: prefs.getInt(_relStatsPrefKey(groupId, 'msy')) ?? 0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveRelStatsToPrefs(String groupId, _CachedRelStats s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_relStatsPrefKey(groupId, 'ts'),
          s.timestamp.millisecondsSinceEpoch);
      await prefs.setInt(_relStatsPrefKey(groupId, 'mem'), s.memoriesCount);
      await prefs.setInt(_relStatsPrefKey(groupId, 'drw'), s.drawingsCount);
      await prefs.setInt(_relStatsPrefKey(groupId, 'msy'), s.missYouCount);
    } catch (_) {}
  }

  /// Загружает актуальную статистику из Firestore и синхронизирует виджет.
  Future<void> refreshRelationshipStats(
    String groupId, {
    DateTime? startDate,
  }) async {
    if (groupId.isEmpty) return;
    try {
      int memoriesCount;
      int drawingsCount;
      int missYouCount;

      final inMemory = _relStatsCache[groupId];
      final cached = (inMemory != null && inMemory.isFresh)
          ? inMemory
          : await _loadRelStatsFromPrefs(groupId);

      if (cached != null) {
        memoriesCount = cached.memoriesCount;
        drawingsCount = cached.drawingsCount;
        missYouCount = cached.missYouCount;
        if (inMemory == null) _relStatsCache[groupId] = cached;
      } else {
        // Миграция §3: счётчики из group-дока PB (денормализованные колонки
        // memories_count/drawings_count), missYou — сумма по miss_you группы.
        final group = await PbDataService().loadGroupById(groupId);
        if (group == null) return;
        memoriesCount = (group.data['memories_count'] as num?)?.toInt() ?? 0;
        drawingsCount = (group.data['drawings_count'] as num?)?.toInt() ?? 0;
        final counts = await PbDataService().getMissYouCounts(groupId);
        missYouCount = counts.values.fold<int>(0, (a, b) => a + b);

        final fresh = _CachedRelStats(
          memoriesCount: memoriesCount,
          drawingsCount: drawingsCount,
          missYouCount: missYouCount,
        );
        _relStatsCache[groupId] = fresh;
        unawaited(_saveRelStatsToPrefs(groupId, fresh));
      }

      // 4. Days together
      int days = 0;
      if (startDate != null) {
        days = DateTime.now().difference(startDate).inDays;
      }

      await syncRelationshipStats(
        groupId: groupId,
        daysTogether: days,
        memoriesCount: memoriesCount,
        drawingsCount: drawingsCount,
        missYouCount: missYouCount,
      );
    } catch (e) {
      debugPrint('HomeWidgetService.refreshRelationshipStats failed: $e');
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  АВТОСИНХРОНИЗАЦИЯ ВСЕХ ВИДЖЕТОВ ПО ПРИВЯЗАННЫМ ГРУППАМ
  // ════════════════════════════════════════════════════════════════════════

  /// Синхронизирует каждый виджет данными из **его** привязанной группы.
  ///
  /// Если виджет привязан к группе, отличной от [activeGroupId], он **не
  /// обновляется** — на рабочем столе остаются данные, записанные последний
  /// раз, когда эта группа была активна. Это гарантирует, что переключение
  /// группы не затирает чужие виджеты.
  ///
  /// Обновляются только:
  ///  • виджеты, привязанные к [activeGroupId]
  ///  • виджеты, не привязанные ни к какой группе (null → текущая)
  Future<void> syncAllBoundWidgets({
    required String activeGroupId,
    required List<TimerItem> activeTimers,
    TimerItem? activeSysTimer,
    DateTime? activeStartDate,
    required String coupleNames,
    required String emoji,
    String myGender = '',
    String partnerGender = '',
    String relationshipStatusId = '',
    bool isRomantic = true,
    int themeIndex = 0,
  }) async {
    try {
      debugPrint(
        'HomeWidgetService.syncAllBoundWidgets: activeGroup=$activeGroupId',
      );

      // Выбираем «активный» таймер один раз — тот же самый идёт и в Timer-виджет,
      // и в Days Counter, чтобы они гарантированно показывали одно и то же.
      final activeTimer = await _resolveActiveTimer(activeTimers, activeGroupId);

      // ── Days Counter ──
      debugPrint('  days_counter → syncing (activeGroup=$activeGroupId, timer=${activeTimer?.title})');
      await _syncDaysCounterWithTimer(
        activeGroupId: activeGroupId,
        activeTimer: activeTimer,
        activeSysTimer: activeSysTimer,
        activeStartDate: activeStartDate,
        activeTimers: activeTimers,
        coupleNames: coupleNames,
        emoji: emoji,
        myGender: myGender,
        partnerGender: partnerGender,
      );

      // ── Timer ──
      debugPrint('  timer → syncing (activeGroup=$activeGroupId, timer=${activeTimer?.title})');
      if (activeTimer != null) {
        await syncTimer(activeTimer, groupId: activeGroupId, isRomantic: isRomantic, themeIndex: themeIndex);
      } else {
        await _syncTimerFromMemory(
          activeTimers: activeTimers,
          groupId: activeGroupId,
          relationshipStatusId: relationshipStatusId,
          isRomantic: isRomantic,
          themeIndex: themeIndex,
        );
      }

      // ── Photo of Day ──
      final widgetIds = await getPhotoDayWidgetIds();
      if (widgetIds.isEmpty) {
        await refreshPhotoOfDay(activeGroupId);
      } else {
        // Определяем partner-виджеты заранее для корректного kind (см. refreshPhotoOfDay)
        Set<int> partnerIds = const {};
        if (Platform.isAndroid) {
          partnerIds = (await getPartnerPhotoWidgetIds()).toSet();
        }
        for (final widgetId in widgetIds) {
          final widgetGroupId = await getPhotoDayWidgetGroupId(widgetId);
          // Solo widgets get group_id='solo'; unbound widgets have null.
          // In solo mode: sync solo-marked and unbound widgets.
          // In pair mode: sync only unbound (null) and widgets bound to this group.
          final shouldSync = activeGroupId.isEmpty
              ? (widgetGroupId == null || widgetGroupId.isEmpty || widgetGroupId == 'solo')
              : (widgetGroupId == null || widgetGroupId == activeGroupId);
          if (shouldSync) {
            debugPrint(
              '  photo_day#$widgetId → syncing (group=$widgetGroupId)',
            );
            await refreshPhotoOfDay(
              activeGroupId,
              widgetId: widgetId,
              overrideKind: partnerIds.contains(widgetId) ? 'partner' : null,
            );
          }
        }
      }

      // ── Relationship Stats ──
      debugPrint('  relationship_stats → syncing (activeGroup=$activeGroupId)');
      await refreshRelationshipStats(
        activeGroupId,
        // «Дни вместе» считаем от АКТИВНОГО таймера (тот же, что Days Counter и
        // круг в приложении — дефолтный/закреплённый), а НЕ от системного: если
        // основным сделан пользовательский таймер, системный хранит дату пары
        // (≈сегодня) → виджет показывал 0.
        startDate:
            activeTimer?.startDate ?? activeSysTimer?.startDate ?? activeStartDate,
      );

      // ── Mood — привязан к пользователю, не к группе ──
      // (mood синхронизируется в WidgetService при изменении)
    } catch (e) {
      debugPrint('HomeWidgetService.syncAllBoundWidgets failed: $e');
    }
  }

  /// Публичная версия для вызова из widget_screen.dart (после пина виджета).
  Future<TimerItem?> resolveActiveTimerPublic(
    List<TimerItem> activeTimers,
    String groupId,
  ) => _resolveActiveTimer(activeTimers, groupId);

  /// Выбирает «активный» таймер для виджетов — тот же алгоритм, что и в
  /// _syncTimerFromMemory, чтобы Timer-виджет и Days Counter всегда показывали
  /// одно и то же.
  Future<TimerItem?> _resolveActiveTimer(
    List<TimerItem> activeTimers,
    String groupId,
  ) async {
    if (activeTimers.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('widget_timer_id_$groupId');
    if (savedId != null) {
      try {
        return activeTimers.firstWhere((t) => t.id == savedId);
      } catch (_) {}
    }
    // Дефолтный таймер (может быть системным или пользовательским)
    try {
      return activeTimers.firstWhere((t) => t.isDefault);
    } catch (_) {}
    return activeTimers.first;
  }

  /// Синхронизирует Days Counter используя уже выбранный [activeTimer].
  /// Если [activeTimer] null — откатывается к системному таймеру / дате пары.
  Future<void> _syncDaysCounterWithTimer({
    required String activeGroupId,
    required TimerItem? activeTimer,
    required TimerItem? activeSysTimer,
    required DateTime? activeStartDate,
    required List<TimerItem> activeTimers,
    required String coupleNames,
    required String emoji,
    String myGender = '',
    String partnerGender = '',
  }) async {
    if (activeTimer != null) {
      await syncDaysCounter(
        groupId: activeGroupId,
        daysCount: activeTimer.daysElapsed.abs(),
        coupleNames: coupleNames,
        emoji: activeTimer.emoji,
        startDate: _formatDate(activeTimer.startDate),
        myGender: myGender,
        partnerGender: partnerGender,
      );
      return;
    }
    // Fallback — старая логика для случаев без таймеров
    await _syncDaysCounterFromMemory(
      activeGroupId: activeGroupId,
      activeSysTimer: activeSysTimer,
      activeStartDate: activeStartDate,
      activeTimers: activeTimers,
      coupleNames: coupleNames,
      emoji: emoji,
      myGender: myGender,
      partnerGender: partnerGender,
    );
  }

  /// Синхронизирует счётчик дней из данных в памяти (текущая группа).
  Future<void> _syncDaysCounterFromMemory({
    required String activeGroupId,
    TimerItem? activeSysTimer,
    DateTime? activeStartDate,
    required List<TimerItem> activeTimers,
    required String coupleNames,
    required String emoji,
    String myGender = '',
    String partnerGender = '',
  }) async {
    // If a non-system timer is set as default, use it (user's custom primary timer).
    // This mirrors _syncTimerFromMemory so both widgets show the same timer's data.
    final customDefault = activeTimers.where((t) => t.isDefault && !t.isSystem).firstOrNull;
    if (customDefault != null) {
      await syncDaysCounter(
        groupId: activeGroupId,
        daysCount: customDefault.daysElapsed.abs(),
        coupleNames: coupleNames,
        emoji: customDefault.emoji,
        startDate: _formatDate(customDefault.startDate),
        myGender: myGender,
        partnerGender: partnerGender,
      );
    } else if (activeSysTimer != null) {
      final start = activeSysTimer.startDate;
      await syncDaysCounter(
        groupId: activeGroupId,
        daysCount: activeSysTimer.daysElapsed.abs(),
        coupleNames: coupleNames,
        emoji: activeSysTimer.emoji,
        startDate: _formatDate(start),
        myGender: myGender,
        partnerGender: partnerGender,
      );
    } else if (activeStartDate != null) {
      await syncDaysCounter(
        groupId: activeGroupId,
        daysCount: DateTime.now().difference(activeStartDate).inDays,
        coupleNames: coupleNames,
        emoji: emoji,
        startDate: _formatDate(activeStartDate),
        myGender: myGender,
        partnerGender: partnerGender,
      );
    } else if (activeTimers.isNotEmpty) {
      // Solo mode: no system timer and no pair date — fall back to the default timer.
      final timer = activeTimers.firstWhere(
        (t) => t.isDefault,
        orElse: () => activeTimers.first,
      );
      await syncDaysCounter(
        groupId: activeGroupId,
        daysCount: timer.daysElapsed.abs(),
        coupleNames: coupleNames,
        emoji: timer.emoji,
        startDate: _formatDate(timer.startDate),
        myGender: myGender,
        partnerGender: partnerGender,
      );
    }
  }

  /// Синхронизирует таймер из данных в памяти (текущая группа).
  Future<void> _syncTimerFromMemory({
    required List<TimerItem> activeTimers,
    required String groupId,
    String relationshipStatusId = '',
    bool isRomantic = true,
    int themeIndex = 0,
  }) async {
    if (activeTimers.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('widget_timer_id_$groupId');
    TimerItem? timer;
    if (savedId != null) {
      try {
        timer = activeTimers.firstWhere((t) => t.id == savedId);
      } catch (_) {}
    }
    // Fallback: default timer first (includes system/relationship timer),
    // then first non-system, then any timer.
    timer ??= activeTimers.firstWhere(
      (t) => t.isDefault,
      orElse: () => activeTimers.firstWhere(
        (t) => !t.isSystem,
        orElse: () => activeTimers.first,
      ),
    );
    await syncTimer(timer, groupId: groupId, isRomantic: isRomantic, themeIndex: themeIndex);
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  // ════════════════════════════════════════════════════════════════════════
  //  ВСПОМОГАТЕЛЬНЫЕ
  // ════════════════════════════════════════════════════════════════════════

  /// Обновляет ВСЕ виджеты рабочего стола (включая парный).
  Future<void> updateAllProviders() async {
    try {
      await HomeWidget.updateWidget(
        name: 'LoveWidgetProvider',
        androidName: 'LoveWidgetProvider',
      );
      await HomeWidget.updateWidget(
        name: 'DaysCounterWidgetProvider',
        androidName: 'DaysCounterWidgetProvider',
      );
      await HomeWidget.updateWidget(
        name: 'TimerWidgetProvider',
        androidName: 'TimerWidgetProvider',
      );
      await _updateAllPhotoWidgetProviders();
      await HomeWidget.updateWidget(
        name: 'MoodWidgetProvider',
        androidName: 'MoodWidgetProvider',
      );
      await HomeWidget.updateWidget(
        name: 'RelationshipStatsWidgetProvider',
        androidName: 'RelationshipStatsWidgetProvider',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.updateAllProviders failed: $e');
    }
  }

  // ── Скачать фото по URL или gs:// пути в локальный кэш ──
  Future<String> _cachePhotoFromUrl(String url, String key) async {
    if (url.isEmpty) return '';
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/widget_$key.jpg');
    try {
      String httpUrl = url;

      // pb:// (PocketBase protected media) → HTTPS с file-токеном (скачиваем
      // в приложении и кладём локальный файл для нативного виджета).
      if (PbMediaService().isPbRef(url)) {
        httpUrl = await PbMediaService().resolveUrlAuthed(url) ?? url;
      }
      // Legacy gs:// (Firebase) / sb:// (Supabase) БОЛЬШЕ НЕ резолвим — проект
      // полностью на PocketBase. Старые такие фото в виджете не подгрузятся
      // (отдаём кэш, если он есть). Новое медиа приходит как pb:// (см. выше).
      else if (url.startsWith('gs://') || url.startsWith('sb://')) {
        return file.existsSync()
            ? await _toWidgetReadablePath(file.path, 'cache_$key')
            : '';
      }

      final response = await http
          .get(Uri.parse(httpUrl))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        debugPrint('HomeWidgetService: photo cached → ${file.path}');
        return await _toWidgetReadablePath(file.path, 'cache_$key');
      }
      // Download failed — fall back to previously cached file if it exists
      if (file.existsSync()) {
        debugPrint('HomeWidgetService: download failed (${response.statusCode}), using cached file');
        return await _toWidgetReadablePath(file.path, 'cache_$key');
      }
    } catch (e) {
      debugPrint('HomeWidgetService._cachePhotoFromUrl failed: $e');
      if (file.existsSync()) return await _toWidgetReadablePath(file.path, 'cache_$key');
    }
    return '';
  }

  // ════════════════════════════════════════════════════════════════════════
  //  6. НАСТРОЕНИЕ НА ЭКРАНЕ БЛОКИРОВКИ
  // ════════════════════════════════════════════════════════════════════════

  static const _lockScreenMoodEnabledKey = 'lock_screen_mood_enabled';

  Future<bool> getLockScreenMoodEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_lockScreenMoodEnabledKey) ?? false;
  }

  Future<void> setLockScreenMoodEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lockScreenMoodEnabledKey, enabled);
  }

  /// Синхронизирует настроение для виджета экрана блокировки.
  ///
  /// [enabled]                   — включён ли виджет.
  /// [moodEmojiAssetPath]        — путь к ассету моего эмодзи.
  /// [moodLabel]                 — моё настроение.
  /// [userName]                  — моё имя.
  /// [partnerMoodEmojiAssetPath] — путь к ассету партнёра.
  /// [partnerMoodLabel]          — настроение партнёра.
  /// [partnerUserName]           — имя партнёра.
  Future<void> syncLockScreenMood({
    required bool enabled,
    required String moodEmojiAssetPath,
    required String moodLabel,
    String userName = '',
    String partnerMoodEmojiAssetPath = '',
    String partnerMoodLabel = '',
    String partnerUserName = '',
  }) async {
    try {
      await HomeWidget.saveWidgetData<String>(
        'lock_mood_enabled',
        enabled ? '1' : '0',
      );

      // Моё настроение
      String myLocalPath = '';
      if (enabled && moodEmojiAssetPath.isNotEmpty) {
        myLocalPath = await _copyAssetToLocal(moodEmojiAssetPath);
      }
      await HomeWidget.saveWidgetData<String>(
        'lock_mood_emoji_path',
        myLocalPath,
      );
      await HomeWidget.saveWidgetData<String>(
        'lock_mood_label',
        enabled ? moodLabel : '',
      );
      await HomeWidget.saveWidgetData<String>('lock_mood_user_name', userName);

      // Настроение партнёра
      String partnerLocalPath = '';
      if (enabled && partnerMoodEmojiAssetPath.isNotEmpty) {
        partnerLocalPath = await _copyAssetToLocal(partnerMoodEmojiAssetPath);
      }
      await HomeWidget.saveWidgetData<String>(
        'lock_partner_mood_emoji_path',
        partnerLocalPath,
      );
      await HomeWidget.saveWidgetData<String>(
        'lock_partner_mood_label',
        enabled ? partnerMoodLabel : '',
      );
      await HomeWidget.saveWidgetData<String>(
        'lock_partner_mood_user_name',
        partnerUserName,
      );

      await HomeWidget.updateWidget(
        name: 'LockScreenMoodWidgetProvider',
        androidName: 'LockScreenMoodWidgetProvider',
      );
      debugPrint(
        'HomeWidgetService: lock screen mood synced — '
        'enabled=$enabled, me=$moodLabel, partner=$partnerMoodLabel',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.syncLockScreenMood failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ── 7. Фото-сетка ──
  // ═══════════════════════════════════════════════════════════════════════════

  /// Читает настройки ПАРТНЁРА из Firestore (photoGridCount + photoGridUrls),
  /// скачивает/кэширует фото и отправляет их в нативный виджет.
  /// Данные сохраняются per-widgetId, чтобы каждый экземпляр был уникальным.
  Future<void> refreshPhotoGrid(String groupId) async {
    if (groupId.isEmpty) return;
    try {
      final currentUserUid = PocketBaseService().userId ?? '';
      if (currentUserUid.isEmpty) return;

      // Определяем UID партнёра из members группы (1 read)
      // вместо чтения всей коллекции widgetData (N reads).
      final resolved = await _resolvePartnerFromGroup(groupId, currentUserUid);
      if (resolved == null) {
        debugPrint('HomeWidgetService.refreshPhotoGrid: group read failed');
        return;
      }
      final partnerUid = resolved.uid;
      if (partnerUid.isEmpty) return;

      // Читаем только документ партнёра (1 read вместо N)
      final partnerData = await _readWidgetData(groupId, partnerUid);
      if (partnerData == null) {
        debugPrint('HomeWidgetService.refreshPhotoGrid: no partner data');
        return;
      }

      final count = partnerData.photoGridCount;
      final urls = partnerData.photoGridUrls;

      // Кэшируем фото один раз (одинаковые для всех экземпляров)
      final List<String> localPaths = [];
      for (int i = 0; i < 4; i++) {
        final url = i < urls.length ? urls[i] : '';
        if (url.isNotEmpty) {
          final localPath = await _cachePhotoFromUrl(url, 'photo_grid_$i');
          localPaths.add(localPath);
        } else {
          localPaths.add('');
        }
      }

      // Сохраняем per-widget ключи для каждого экземпляра
      final widgetIds = await getPhotoGridWidgetIds();
      if (widgetIds.isEmpty) {
        // Fallback: глобальные ключи (если виджетов нет ещё — для совместимости)
        await HomeWidget.saveWidgetData<int>('photo_grid_count', count);
        for (int i = 0; i < 4; i++) {
          await HomeWidget.saveWidgetData<String>(
            'photo_grid_$i',
            localPaths[i],
          );
        }
      } else {
        for (final widgetId in widgetIds) {
          await HomeWidget.saveWidgetData<int>(
            'photo_grid_${widgetId}_count',
            count,
          );
          for (int i = 0; i < 4; i++) {
            await HomeWidget.saveWidgetData<String>(
              'photo_grid_${widgetId}_$i',
              localPaths[i],
            );
          }
        }
      }

      await HomeWidget.updateWidget(
        name: 'PhotoGridWidgetProvider',
        androidName: 'PhotoGridWidgetProvider',
      );
      debugPrint(
        'HomeWidgetService.refreshPhotoGrid: count=$count, urls=$urls, widgets=$widgetIds',
      );
    } catch (e) {
      debugPrint('HomeWidgetService.refreshPhotoGrid failed: $e');
    }
  }

  // ── Скопировать Flutter-ассет (emoji PNG) в локальный файл ──
  Future<String> _copyAssetToLocal(String assetPath) async {
    if (assetPath.isEmpty) return '';
    // Удалённое настроение из каталога (публичный URL) — нативный виджет умеет
    // только локальные файлы, поэтому качаем картинку в файл (один раз, кэш на
    // диске). При сбое — классический бандл-ассет по id (имя файла URL = id).
    if (assetPath.startsWith('http://') || assetPath.startsWith('https://')) {
      return _downloadToLocal(assetPath);
    }
    try {
      final dir = await getApplicationSupportDirectory();
      final fileName = assetPath.split('/').last;
      final file = File('${dir.path}/widget_mood_$fileName');

      // Если уже скопировано — не копируем повторно (но на iOS всё равно отдаём
      // путь из App Group контейнера, иначе виджет файл не прочитает).
      if (file.existsSync()) {
        return await _toWidgetReadablePath(file.path, 'mood_$fileName');
      }

      // Грузим ассет; если его нет в этой сборке (партнёр прислал эмодзи из
      // пака, которого у нас нет — постепенный раскат) — падаем на эквивалент
      // из классического пака, чтобы вместо пустоты показать смайлик.
      ByteData? bytes;
      try {
        bytes = await rootBundle.load(assetPath);
      } catch (_) {
        final fallback = MoodOption.classicFallbackFor(assetPath);
        if (fallback != null) bytes = await rootBundle.load(fallback);
      }
      if (bytes == null) return '';
      await file.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      debugPrint('HomeWidgetService: asset copied → ${file.path}');
      return await _toWidgetReadablePath(file.path, 'mood_$fileName');
    } catch (e) {
      debugPrint('HomeWidgetService._copyAssetToLocal failed: $e');
    }
    return '';
  }

  /// Скачать удалённую картинку настроения (URL каталога) в локальный файл для
  /// нативного виджета. Имя файла — по hash URL (разные паки с одинаковым именем
  /// файла не конфликтуют). При сбое сети — классический бандл-ассет по id.
  Future<String> _downloadToLocal(String url) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/widget_mood_url_${url.hashCode}.webp');
      final moodName = 'mood_url_${url.hashCode}';
      if (file.existsSync()) {
        return await _toWidgetReadablePath(file.path, moodName);
      }
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        await file.writeAsBytes(resp.bodyBytes);
        debugPrint('HomeWidgetService: mood url downloaded → ${file.path}');
        return await _toWidgetReadablePath(file.path, moodName);
      }
    } catch (e) {
      debugPrint('HomeWidgetService._downloadToLocal failed: $e');
    }
    final fallback = MoodOption.classicFallbackFor(url);
    if (fallback != null) return _copyAssetToLocal(fallback);
    return '';
  }
}

class _CachedWidgetData {
  final Map<String, String>? data;
  final DateTime timestamp;
  _CachedWidgetData(this.data) : timestamp = DateTime.now();
  bool get isFresh =>
      DateTime.now().difference(timestamp) < HomeWidgetService._widgetDataCacheTtl;
}

class _CachedRelStats {
  final int memoriesCount;
  final int drawingsCount;
  final int missYouCount;
  final DateTime timestamp;
  _CachedRelStats({
    required this.memoriesCount,
    required this.drawingsCount,
    required this.missYouCount,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
  bool get isFresh =>
      DateTime.now().difference(timestamp) < HomeWidgetService._relStatsCacheTtl;
}
