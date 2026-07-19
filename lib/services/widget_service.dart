import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/widget_data.dart';
import '../models/memory.dart';
import '../models/mood_entry.dart';
import 'media_service.dart';
import 'home_widget_service.dart';
import 'level_service.dart';
import 'memory_repository.dart';
import 'mood_repository.dart';
import 'pb_auth_service.dart';
import 'pb_data_service.dart';
import 'pb_media_service.dart';
import 'pb_realtime_service.dart';
import 'pocketbase_service.dart';

/// Сервис синхронизации виджет-данных между партнёрами — на PocketBase
/// (миграция §3): коллекция `widget_data` (live SSE, без лимитов). Авто-отправка
/// в Memory Lane / Mood Calendar идёт через мигрированные [MemoryRepository] /
/// [MoodRepository]. `FirebaseService` остаётся ТОЛЬКО под медиа (загрузка фото в
/// Storage + signed-URL для скачивания gs:///sb:// в нативный виджет) — медиа §4.
class WidgetService extends ChangeNotifier {
  final PbDataService _data = PbDataService();
  final PbRealtimeService _rt = PbRealtimeService();
  bool _isDisposed = false;

  int _bindGeneration = 0;

  @override
  void notifyListeners() {
    if (!_isDisposed) super.notifyListeners();
  }

  String _groupId = '';
  String get groupId => _groupId;

  // ── Данные виджетов ──
  WidgetData? _myData;
  final Map<String, WidgetData> _partnerData = {};

  WidgetData? get myData => _myData;
  WidgetData? partnerDataOf(String uid) => _partnerData[uid];

  /// Первый партнёр (для пары) — удобный геттер
  WidgetData? get firstPartnerData =>
      _partnerData.isNotEmpty ? _partnerData.values.first : null;

  // ── Подписки ──
  StreamSubscription? _mySub;
  final Map<String, StreamSubscription> _partnerSubs = {};

  // Дебаунс для _syncToNativeWidget. Метод копирует PNG-ассеты, скачивает
  // фото через HTTP и пишет 30+ значений в SharedPreferences. На каждом
  // snapshot widgetData (mood/status/message change) он стрелял — при цепных
  // изменениях лагало 200-500ms. Не Firestore reads, но UX-критично.
  Timer? _syncNativeDebounce;

  // Кэш профиля пользователя — чтобы не читать users/{uid} на каждую запись
  // в _updateField (mood/status/message менялись по 1 read на каждое обновление).
  // Сбрасывается в unbindFromGroup, обновляется лениво при первом запросе.
  String? _cachedProfileName;
  String? _cachedProfileAvatar;
  String? _cachedProfileGender;
  String? _cachedProfileUid;

  // Подписи photo-полей: refreshPhotoOfDay делает full-collection .get() на
  // widgetData + fallback на group doc — пересчитывать его на КАЖДЫЙ snapshot
  // (включая mood/status/message) очень дорого. Триггерим только когда реально
  // поменялись фото-поля.
  String? _myPhotoSig;
  final Map<String, String> _partnerPhotoSigs = {};

  static String _photoSigOf(WidgetData? d) {
    if (d == null) return '';
    return [
      d.photoUrl ?? '',
      d.photoForPartnerUrl ?? '',
      d.photoForPartnerUrls.join('|'),
      d.photoGridUrls.join('|'),
    ].join('§');
  }

  // ── Настройки автоотправки ──
  bool _autoSendPhotoToMemory = true;
  bool _autoSendMessageToMemory = true;
  bool _autoSendMusicToMemory = true;
  bool _autoSendMoodToCalendar = true;

  bool get autoSendPhotoToMemory => _autoSendPhotoToMemory;
  bool get autoSendMessageToMemory => _autoSendMessageToMemory;
  bool get autoSendMusicToMemory => _autoSendMusicToMemory;
  bool get autoSendMoodToCalendar => _autoSendMoodToCalendar;

  // ══════════════════════════════════════════════════════════════════════════
  // INIT
  // ══════════════════════════════════════════════════════════════════════════

  /// Привязка к группе. Начинает слушать свой виджет.
  Future<void> bindToGroup(String groupId) async {
    if (groupId.isEmpty || groupId == _groupId) return;
    // unbindFromGroup increments _bindGeneration internally, so capture
    // the generation AFTER the call to avoid an immediate guard mismatch.
    await unbindFromGroup(clearNativeWidget: false);
    final generation = ++_bindGeneration;
    _groupId = groupId;
    await _loadSettings();
    if (_isDisposed || generation != _bindGeneration) return;
    // Persist groupId so the background isolate (onUpdate refresh) can find it
    await HomeWidget.saveWidgetData<String>('love_widget_group_id', groupId);
    _listenToMyData();
    notifyListeners();
  }

  /// Подписка на виджет-данные партнёра
  void listenToPartner(String partnerUid) {
    if (partnerUid.isEmpty || _groupId.isEmpty) return;
    // Persist partnerUid so the background isolate can fetch partner data
    HomeWidget.saveWidgetData<String>('love_widget_partner_uid', partnerUid);

    _partnerSubs.remove(partnerUid)?.cancel();
    _partnerData.remove(partnerUid);

    _partnerSubs[partnerUid] = _rt.watchWidgetOne(_groupId, partnerUid).listen(
      (rec) {
        if (_isDisposed) return;
        if (rec != null) {
          _partnerData[partnerUid] = WidgetData.fromPb(rec);
        } else {
          _partnerData[partnerUid] = WidgetData(uid: partnerUid);
          // Fallback: имя/аватар из group-дока (member_names/member_avatars).
          _loadPartnerFallback(partnerUid);
        }
        _scheduleSyncToNative();
        // refreshPhotoOfDay перечитывает виджет-данные — дёргаем только когда
        // реально изменились фото-поля партнёра, а не mood/status.
        final newSig = _photoSigOf(_partnerData[partnerUid]);
        if (_groupId.isNotEmpty && _partnerPhotoSigs[partnerUid] != newSig) {
          _partnerPhotoSigs[partnerUid] = newSig;
          HomeWidgetService.instance.invalidateWidgetDataCache();
          HomeWidgetService.instance.refreshPhotoOfDay(_groupId);
        }
        notifyListeners();
      },
      onError: (e) => debugPrint('WidgetService partner listener error: $e'),
    );
  }

  Future<void> unbindFromGroup({bool clearNativeWidget = true}) async {
    _bindGeneration++;
    _mySub?.cancel();
    _mySub = null;
    for (final sub in _partnerSubs.values) {
      sub.cancel();
    }
    _partnerSubs.clear();
    _groupId = '';
    _myData = null;
    _partnerData.clear();
    _myPhotoSig = null;
    _partnerPhotoSigs.clear();

    // Clear native group/partner keys so background isolates don't
    // read stale group references after unbind.
    await HomeWidget.saveWidgetData<String>('love_widget_group_id', '');
    await HomeWidget.saveWidgetData<String>('love_widget_partner_uid', '');

    if (clearNativeWidget) {
      await _syncToNativeWidget();
    }
    notifyListeners();
  }

  void _listenToMyData() {
    final uid = PocketBaseService().userId;
    if (uid == null || _groupId.isEmpty) return;

    _mySub?.cancel();
    _mySub = _rt.watchWidgetOne(_groupId, uid).listen(
      (rec) {
        if (_isDisposed) return;
        if (rec != null) {
          _myData = WidgetData.fromPb(rec);
        } else {
          _myData = WidgetData(uid: uid);
          // Bootstrap record with profile data so widget shows name/avatar
          _initializeMyWidgetData(uid);
        }
        _scheduleSyncToNative();
        final newSig = _photoSigOf(_myData);
        if (_groupId.isNotEmpty && _myPhotoSig != newSig) {
          _myPhotoSig = newSig;
          HomeWidgetService.instance.invalidateWidgetDataCache();
          HomeWidgetService.instance.refreshPhotoOfDay(_groupId);
        }
        notifyListeners();
      },
      onError: (e) => debugPrint('WidgetService my data listener error: $e'),
    );
  }

  /// Creates the widget_data record with profile data when it doesn't exist yet.
  Future<void> _initializeMyWidgetData(String uid) async {
    final gid = _groupId;
    if (gid.isEmpty) return;
    try {
      final p = PbAuthService().currentProfile() ?? const {};
      if (_isDisposed || _groupId != gid) return;
      await _data.upsertWidget(gid, uid, {
        'displayName': p['displayName'] ?? '',
        'avatarUrl': p['avatarUrl'] ?? '',
        'gender': p['gender'] ?? '',
      });
      debugPrint('WidgetService: widget_data initialized for $uid');
    } catch (e) {
      debugPrint('WidgetService._initializeMyWidgetData failed: $e');
    }
  }

  /// Reads partner name/avatar from the group record (member_names/member_avatars)
  /// as fallback when their widget_data record doesn't exist yet.
  Future<void> _loadPartnerFallback(String partnerUid) async {
    final gid = _groupId;
    if (gid.isEmpty) return;
    try {
      final g = await _data.loadGroupById(gid);
      if (g == null || _isDisposed || _groupId != gid) return;
      final names = g.data['member_names'];
      final avatars = g.data['member_avatars'];
      final name = (names is Map ? names[partnerUid] : null)?.toString() ?? '';
      final avatar =
          (avatars is Map ? avatars[partnerUid] : null)?.toString() ?? '';
      if (name.isEmpty && avatar.isEmpty) return;
      _partnerData[partnerUid] = WidgetData(
        uid: partnerUid,
        displayName: name,
        avatarUrl: avatar,
      );
      _syncToNativeWidget();
      notifyListeners();
    } catch (e) {
      debugPrint('WidgetService._loadPartnerFallback failed: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UPDATE
  // ══════════════════════════════════════════════════════════════════════════

  /// Обновить статус
  Future<void> updateStatus(String status) async {
    await _updateField({'status': status});
  }

  /// Обновить настроение (emoji).
  /// [skipCalendar] — передай true если moodService.addMood уже добавил запись,
  /// чтобы не создавать дубль.
  Future<void> updateMood(
    String emojiPath,
    String label, {
    bool skipCalendar = false,
  }) async {
    final groupId = _groupId;
    await _updateField({
      'moodEmoji': emojiPath,
      'moodLabel': label,
    }, groupId: groupId);

    unawaited(LevelService.instance.award(XpAction.changeMood));

    // Автоотправка в календарь — только если не пропускаем. Через мигрированный
    // MoodRepository (PB), id генерит сервер, личность — текущий PB-юзер.
    if (!skipCalendar && _autoSendMoodToCalendar && groupId.isNotEmpty) {
      try {
        final option = MoodOption.byImagePath(emojiPath);
        await MoodRepository().add(
          groupId: groupId,
          moodId: option?.id ?? label.toLowerCase().replaceAll(' ', '_'),
          imagePath: emojiPath,
          label: label,
          timestamp: DateTime.now(),
        );
      } catch (e) {
        debugPrint('Widget → Calendar failed: $e');
      }
    }
  }

  /// Имя/аватар автора для авто-воспоминаний (из профиля PB).
  ({String name, String avatar}) _memoryAuthor() {
    final p = PbAuthService().currentProfile() ?? const {};
    return (
      name: (p['displayName'] as String?) ?? '',
      avatar: (p['avatarUrl'] as String?) ?? '',
    );
  }

  /// Обновить сообщение
  Future<void> updateMessage(String message) async {
    final groupId = _groupId;
    await _updateField({'message': message}, groupId: groupId);

    // Автоотправка в Memory Lane
    if (_autoSendMessageToMemory && message.isNotEmpty && groupId.isNotEmpty) {
      try {
        final a = _memoryAuthor();
        await MemoryRepository().add(
          groupId: groupId,
          authorName: a.name,
          authorAvatar: a.avatar,
          type: MemoryType.text,
          caption: '💬 $message',
        );
      } catch (e) {
        debugPrint('Widget → Memory (msg) failed: $e');
      }
    }
  }

  /// Обновить фото
  Future<void> updatePhoto(String localPath) async {
    final groupId = _groupId;
    if (groupId.isEmpty) return;
    // Загрузка в Storage (медиа §4 — пока Firebase Storage).
    final uid = PocketBaseService().userId ?? '';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final dest = 'widget/$groupId/${uid}_$ts.jpg';
    final url = await MediaService().uploadFile(localPath, dest);
    if (url == null || groupId != _groupId) return;

    await _updateField({'photoUrl': url}, groupId: groupId);

    // Автоотправка в Memory Lane
    if (_autoSendPhotoToMemory && groupId.isNotEmpty) {
      try {
        final a = _memoryAuthor();
        await MemoryRepository().add(
          groupId: groupId,
          authorName: a.name,
          authorAvatar: a.avatar,
          type: MemoryType.photo,
          imageUrl: url,
          caption: '📸 Виджет',
        );
      } catch (e) {
        debugPrint('Widget → Memory (photo) failed: $e');
      }
    }
  }

  /// Обновить фото по URL (уже загружено)
  Future<void> updatePhotoUrl(String url) async {
    await _updateField({'photoUrl': url}, groupId: _groupId);
  }

  /// Фото, которым я делюсь с партнёром для partner-widget.
  /// Заменяет карусель одним фото — используется для «живого» фото с камеры.
  Future<void> updatePhotoForPartnerUrl(String url) async {
    await _updateField({
      'photoForPartnerUrl': url,
      'photoForPartnerUrls': [url],
    }, groupId: _groupId);
  }

  Future<void> updatePhotoForPartnerCarousel(List<String> urls) async {
    await _updateField({
      'photoForPartnerUrls': urls,
      'photoForPartnerUrl': urls.isNotEmpty ? urls.first : null,
    }, groupId: _groupId);
  }

  /// Сохранить настройки сетки фото (мои фото, которые увидит партнёр)
  Future<void> updatePhotoGrid(int count, List<String> photoUrls) async {
    await _updateField({
      'photoGridCount': count,
      'photoGridUrls': photoUrls,
    }, groupId: _groupId);
  }

  /// Обновить музыку
  Future<void> updateMusic({
    required String title,
    required String artist,
    String? url,
    String? coverUrl,
  }) async {
    final groupId = _groupId;
    await _updateField({
      'musicTitle': title,
      'musicArtist': artist,
      'musicUrl': url,
      'musicCoverUrl': coverUrl,
    }, groupId: groupId);

    // Автоотправка в Memory Lane
    if (_autoSendMusicToMemory && groupId.isNotEmpty) {
      try {
        final a = _memoryAuthor();
        await MemoryRepository().add(
          groupId: groupId,
          authorName: a.name,
          authorAvatar: a.avatar,
          type: MemoryType.music,
          musicTitle: title,
          musicArtist: artist,
          musicUrl: url,
          musicCoverUrl: coverUrl,
        );
      } catch (e) {
        debugPrint('Widget → Memory (music) failed: $e');
      }
    }
  }

  /// Очистить конкретный слот
  // Очистка пишет ПУСТУЮ строку (не null): upsertWidget отбрасывает null-поля
  // ради частичного апдейта, поэтому null не стёр бы значение. fromPb коэрсит
  // '' обратно в null при чтении.
  Future<void> clearStatus() => _updateField({'status': ''});
  Future<void> clearMood() => _updateField({'moodEmoji': '', 'moodLabel': ''});
  Future<void> clearMessage() => _updateField({'message': ''});
  Future<void> clearPhoto() => _updateField({'photoUrl': ''});
  Future<void> clearMusic() => _updateField({
    'musicTitle': '',
    'musicArtist': '',
    'musicUrl': '',
    'musicCoverUrl': '',
  });

  /// Очистить все данные виджета
  Future<void> clearAll() async {
    await _updateField({
      'status': '',
      'moodEmoji': '',
      'moodLabel': '',
      'message': '',
      'photoUrl': '',
      'musicTitle': '',
      'musicArtist': '',
      'musicUrl': '',
      'musicCoverUrl': '',
    });
  }

  Future<void> _updateField(
    Map<String, dynamic> fields, {
    String? groupId,
    bool emitEvent = true, // legacy-параметр (FCM-триггер убран); сохранён для API
  }) async {
    final uid = PocketBaseService().userId;
    final targetGroupId = groupId ?? _groupId;
    if (uid == null || targetGroupId.isEmpty) return;

    try {
      // Профиль кэшируется на сессию (currentProfile() и так читает кэш-rec PB,
      // но держим локальный кэш ради invalidateProfileCache/refreshProfileOnWidget).
      if (_cachedProfileUid != uid) {
        _cachedProfileUid = uid;
        _cachedProfileName = null;
        _cachedProfileAvatar = null;
        _cachedProfileGender = null;
      }
      if (_cachedProfileName == null ||
          _cachedProfileAvatar == null ||
          _cachedProfileGender == null) {
        final p = PbAuthService().currentProfile() ?? const {};
        _cachedProfileName = (p['displayName'] as String?) ?? '';
        _cachedProfileAvatar = (p['avatarUrl'] as String?) ?? '';
        _cachedProfileGender = (p['gender'] as String?) ?? '';
      }
      final name = _cachedProfileName!;
      final avatar = _cachedProfileAvatar!;
      final gender = _cachedProfileGender!;

      // Запись в PB widget_data (upsert по group+uid). Партнёр видит изменение
      // через свой live SSE-листенер; фоновый пуш (убитый процесс) — через
      // PbPushService по SSE-дельте (мигрирует в §5), НЕ через Firebase-триггер.
      await _data.upsertWidget(targetGroupId, uid, {
        'displayName': name,
        'avatarUrl': avatar,
        'gender': gender,
        ...fields,
      });

      if (targetGroupId != _groupId) return;

      // Синхронизируем нативный виджет сразу после записи, не дожидаясь
      // SSE-листенера (Xiaomi убивает процесс слишком быстро).
      await _syncToNativeWidget();
    } catch (e) {
      debugPrint('WidgetService._updateField failed: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SETTINGS
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> setAutoSendPhotoToMemory(bool value) async {
    _autoSendPhotoToMemory = value;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setAutoSendMessageToMemory(bool value) async {
    _autoSendMessageToMemory = value;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setAutoSendMusicToMemory(bool value) async {
    _autoSendMusicToMemory = value;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setAutoSendMoodToCalendar(bool value) async {
    _autoSendMoodToCalendar = value;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoSendPhotoToMemory =
          prefs.getBool('widget_autoSendPhotoToMemory') ?? true;
      _autoSendMessageToMemory =
          prefs.getBool('widget_autoSendMessageToMemory') ?? true;
      _autoSendMusicToMemory =
          prefs.getBool('widget_autoSendMusicToMemory') ?? true;
      _autoSendMoodToCalendar =
          prefs.getBool('widget_autoSendMoodToCalendar') ?? true;
    } catch (e) {
      debugPrint('WidgetService._loadSettings failed: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
        'widget_autoSendPhotoToMemory',
        _autoSendPhotoToMemory,
      );
      await prefs.setBool(
        'widget_autoSendMessageToMemory',
        _autoSendMessageToMemory,
      );
      await prefs.setBool(
        'widget_autoSendMusicToMemory',
        _autoSendMusicToMemory,
      );
      await prefs.setBool(
        'widget_autoSendMoodToCalendar',
        _autoSendMoodToCalendar,
      );
    } catch (e) {
      debugPrint('WidgetService._saveSettings failed: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // NATIVE HOME SCREEN WIDGET SYNC
  // ══════════════════════════════════════════════════════════════════════════

  /// Планирует _syncToNativeWidget с дебаунсом 150ms — собирает каскад
  /// snapshot-событий (mood/status/message могут прилетать пачкой) в один
  /// тяжёлый sync вместо 5+ повторов.
  void _scheduleSyncToNative() {
    _syncNativeDebounce?.cancel();
    _syncNativeDebounce = Timer(const Duration(milliseconds: 150), () {
      if (_isDisposed) return;
      _syncToNativeWidget();
    });
  }

  /// Синхронизирует данные в SharedPreferences для нативного виджета Android
  Future<void> _syncToNativeWidget() async {
    final bindGeneration = _bindGeneration;
    try {
      // ── Мои данные ──
      final my = _myData;
      // moodEmoji хранит путь к asset-файлу — для нативного виджета
      // используем moodLabel (текстовая метка: «Счастлив», «Грустный» и т.д.)
      await HomeWidget.saveWidgetData<String>(
        'my_name',
        my?.displayName.isNotEmpty == true ? my!.displayName : 'Я',
      );
      await HomeWidget.saveWidgetData<String>('my_mood', my?.moodLabel ?? '');
      await HomeWidget.saveWidgetData<String>('my_status', my?.status ?? '');
      await HomeWidget.saveWidgetData<String>('my_message', my?.message ?? '');
      await HomeWidget.saveWidgetData<String>(
        'my_music_title',
        my?.musicTitle ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'my_music_artist',
        my?.musicArtist ?? '',
      );

      // ── Данные партнёра ──
      final partner = firstPartnerData;
      await HomeWidget.saveWidgetData<String>(
        'partner_name',
        partner?.displayName.isNotEmpty == true
            ? partner!.displayName
            : 'Партнёр',
      );
      await HomeWidget.saveWidgetData<String>(
        'partner_mood',
        partner?.moodLabel ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'partner_status',
        partner?.status ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'partner_message',
        partner?.message ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'partner_music_title',
        partner?.musicTitle ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'partner_music_artist',
        partner?.musicArtist ?? '',
      );

      // ── Фото: сохраняем URL, кэшируем локально фоново ──
      // MY сторона показывает ТОЛЬКО photoUrl (фото, явно выбранное для
      // парного виджета). НЕ падаем на photoForPartnerUrl — это отдельная
      // функция «Фото партнёра» (что я отправляю партнёру), и её фото не
      // должно протекать на мою половину парного виджета.
      // PARTNER сторона: приоритет photoForPartnerUrl — это фото, которым
      // партнёр осознанно поделился, чтобы оно показывалось у меня.
      await HomeWidget.saveWidgetData<String>(
        'my_photo_url',
        my?.photoUrl ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'partner_photo_url',
        partner?.photoForPartnerUrl ?? partner?.photoUrl ?? '',
      );

      // ── Аватарки для 2-человечного виджета (LoveWidget) ──
      // LoveWidget всё ещё использует старые ключи для 2 людей
      await HomeWidget.saveWidgetData<String>(
        'my_avatar_url',
        my?.avatarUrl ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'partner_avatar_url',
        partner?.avatarUrl ?? '',
      );

      // ── Обновить виджет на рабочем столе (текстовые данные сразу) ──
      await HomeWidget.updateWidget(
        name: 'LoveWidgetProvider',
        androidName: 'LoveWidgetProvider',
      );
      if (_isDisposed || bindGeneration != _bindGeneration) return;
      debugPrint(
        'NativeWidget: synced — my=${my?.displayName}, partner=${partner?.displayName}',
      );

      // ── Синхронизируем виджет настроения для группы (до 4 человек) ──
      // Фильтруем текущего пользователя из partnerData, чтобы не было дублирования аватарок
      final myUid = PocketBaseService().userId ?? '';
      final membersForWidget = <WidgetData>[];
      if (my != null) membersForWidget.add(my);
      membersForWidget.addAll(_partnerData.values.where((d) => d.uid != myUid));
      final limitedMembers = membersForWidget.take(4).toList();

      final membersData = limitedMembers
          .map(
            (m) => {
              'name': m.displayName.isNotEmpty ? m.displayName : 'Участник',
              'emojiPath': m.moodEmoji,
            },
          )
          .toList();
      await HomeWidgetService.instance.syncGroupMood(membersData);
      if (_isDisposed || bindGeneration != _bindGeneration) return;

      for (int i = 0; i < limitedMembers.length; i++) {
        await HomeWidget.saveWidgetData<String>(
          'user_${i}_avatar_url',
          limitedMembers[i].avatarUrl,
        );
      }

      // Кэшируем эмодзи из assets → локальные файлы для нативного виджета (фоново)
      Future.wait([
        _cacheEmojiForWidget(my?.moodEmoji, 'my_mood_emoji_path'),
        _cacheEmojiForWidget(partner?.moodEmoji, 'partner_mood_emoji_path'),
      ]).then((_) async {
        if (_isDisposed || bindGeneration != _bindGeneration) return;
        try {
          await HomeWidget.updateWidget(
            name: 'LoveWidgetProvider',
            androidName: 'LoveWidgetProvider',
          );
        } catch (e) {
          debugPrint('WidgetService emoji update failed: $e');
        }
      });

      // Скачиваем фото и аватарки локально в фоне и обновляем виджет повторно.
      // MY сторона — только photoUrl (см. комментарий выше про my_photo_url):
      // фото «для партнёра» не должно попадать на мою половину парного виджета.
      _cachePhotosForWidget(
        my?.photoUrl,
        partner?.photoForPartnerUrl ?? partner?.photoUrl,
      );
      _cacheAvatarsForLoveWidget(my?.avatarUrl, partner?.avatarUrl);
      _cacheGroupAvatarsForWidget(limitedMembers);

      // PhotoDay обновляется ТОЛЬКО при изменении фото-полей (photoUrl,
      // photoForPartnerUrl, photoForPartnerUrls, photoGridUrls) через
      // проверку _photoSig() в слушателях. Не дёргаем здесь — на каждое
      // изменение mood/status/message это было бы N×collection.get() reads.
    } catch (e) {
      debugPrint('WidgetService._syncToNativeWidget failed: $e');
    }
  }

  /// Скачивает фото в локальный кэш и обновляет нативный виджет (LoveWidget).
  void _cachePhotosForWidget(String? myUrl, String? partnerUrl) {
    final bindGeneration = _bindGeneration;
    Future.wait([
      _downloadPhoto(myUrl, 'my_photo_path'),
      _downloadPhoto(partnerUrl, 'partner_photo_path'),
    ]).then((_) async {
      if (_isDisposed || bindGeneration != _bindGeneration) return;
      try {
        await HomeWidget.updateWidget(
          name: 'LoveWidgetProvider',
          androidName: 'LoveWidgetProvider',
        );
      } catch (e) {
        debugPrint('WidgetService._cachePhotosForWidget update failed: $e');
      }
    });
  }

  /// Скачивает аватарки для парного виджета (LoveWidget) в локальный кэш.
  void _cacheAvatarsForLoveWidget(String? myUrl, String? partnerUrl) {
    final bindGeneration = _bindGeneration;
    Future.wait([
      _downloadPhoto(myUrl, 'my_avatar_path'),
      _downloadPhoto(partnerUrl, 'partner_avatar_path'),
    ]).then((_) async {
      if (_isDisposed || bindGeneration != _bindGeneration) return;
      try {
        await HomeWidget.updateWidget(
          name: 'LoveWidgetProvider',
          androidName: 'LoveWidgetProvider',
        );
      } catch (e) {
        debugPrint(
          'WidgetService._cacheAvatarsForLoveWidget update failed: $e',
        );
      }
    });
  }

  /// Скачивает аватарки группы в локальный кэш и обновляет MoodWidget.
  void _cacheGroupAvatarsForWidget(List<WidgetData> members) {
    final bindGeneration = _bindGeneration;
    final futures = <Future<void>>[];
    for (int i = 0; i < members.length; i++) {
      futures.add(
        _downloadPhoto(members[i].avatarUrl, 'user_${i}_avatar_path'),
      );
    }
    Future.wait(futures).then((_) async {
      if (_isDisposed || bindGeneration != _bindGeneration) return;
      try {
        await HomeWidget.updateWidget(
          name: 'MoodWidgetProvider',
          androidName: 'MoodWidgetProvider',
        );
      } catch (e) {
        debugPrint(
          'WidgetService._cacheGroupAvatarsForWidget update failed: $e',
        );
      }
    });
  }

  /// Копирует Flutter asset с эмодзи в файловый кэш и сохраняет путь
  /// под ключом [key] в SharedPreferences нативного виджета.
  Future<void> _cacheEmojiForWidget(String? assetPath, String key) async {
    if (assetPath == null || assetPath.isEmpty) {
      await HomeWidget.saveWidgetData<String>(key, '');
      return;
    }
    // Удалённое настроение из каталога (публичный URL) — нативный виджет умеет
    // только локальные файлы, поэтому скачиваем картинку в файл (кэш по URL).
    if (assetPath.startsWith('http://') || assetPath.startsWith('https://')) {
      await _cacheEmojiUrlForWidget(assetPath, key);
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedAsset = prefs.getString('${key}_cached_asset') ?? '';
      final cachedPath = prefs.getString('${key}_cached_path') ?? '';

      if (cachedAsset == assetPath &&
          cachedPath.isNotEmpty &&
          File(cachedPath).existsSync()) {
        await HomeWidget.saveWidgetData<String>(
            key, await HomeWidgetService.instance.appGroupReadablePath(cachedPath, key));
        return;
      }

      // Грузим ассет; если его нет в этой сборке (партнёр прислал эмодзи из
      // пака, которого у нас нет — постепенный раскат) — падаем на эквивалент
      // из классического пака, чтобы показать смайлик, а не пустоту с одной
      // лишь текстовой меткой.
      ByteData? byteData;
      try {
        byteData = await rootBundle.load(assetPath);
      } catch (_) {
        final fallback = MoodOption.classicFallbackFor(assetPath);
        if (fallback != null) byteData = await rootBundle.load(fallback);
      }
      if (byteData == null) {
        await HomeWidget.saveWidgetData<String>(key, '');
        return;
      }

      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$key.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());
      await HomeWidget.saveWidgetData<String>(
          key, await HomeWidgetService.instance.appGroupReadablePath(file.path, key));
      await prefs.setString('${key}_cached_asset', assetPath);
      await prefs.setString('${key}_cached_path', file.path);
      debugPrint('_cacheEmojiForWidget: $key cached at ${file.path}');
    } catch (e) {
      debugPrint('_cacheEmojiForWidget($key) failed: $e');
      await HomeWidget.saveWidgetData<String>(key, '');
    }
  }

  /// Скачать удалённую картинку настроения (URL каталога) в локальный файл для
  /// нативного виджета. При сбое сети — классический бандл-ассет по id.
  Future<void> _cacheEmojiUrlForWidget(String url, String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedAsset = prefs.getString('${key}_cached_asset') ?? '';
      final cachedPath = prefs.getString('${key}_cached_path') ?? '';
      if (cachedAsset == url &&
          cachedPath.isNotEmpty &&
          File(cachedPath).existsSync()) {
        await HomeWidget.saveWidgetData<String>(
            key, await HomeWidgetService.instance.appGroupReadablePath(cachedPath, key));
        return;
      }
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/$key.webp');
        await file.writeAsBytes(resp.bodyBytes);
        await HomeWidget.saveWidgetData<String>(
            key, await HomeWidgetService.instance.appGroupReadablePath(file.path, key));
        await prefs.setString('${key}_cached_asset', url);
        await prefs.setString('${key}_cached_path', file.path);
        return;
      }
    } catch (e) {
      debugPrint('_cacheEmojiUrlForWidget($key) failed: $e');
    }
    // Фолбэк: классический ассет по id (имя файла URL = id настроения).
    final fallback = MoodOption.classicFallbackFor(url);
    if (fallback != null) {
      await _cacheEmojiForWidget(fallback, key);
    } else {
      await HomeWidget.saveWidgetData<String>(key, '');
    }
  }

  /// Скачивает изображение по [url] в файловый кэш и сохраняет путь
  /// под ключом [key] в SharedPreferences нативного виджета.
  Future<void> _downloadPhoto(String? url, String key) async {
    if (url == null || url.isEmpty) {
      await HomeWidget.saveWidgetData<String>(key, '');
      // Фото убрали → чистим старые файлы этого ключа в контейнере, иначе iOS
      // держал бы закэшированную картинку по прежнему пути.
      await HomeWidgetService.instance.clearAppGroupMedia(key);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${key}_cached_url');
      await prefs.remove('${key}_cached_wpath');
      return;
    }
    try {
      String httpUrl = url;

      // pb:// (PocketBase protected media) → HTTPS с file-токеном.
      if (PbMediaService().isPbRef(url)) {
        httpUrl = await PbMediaService().resolveUrlAuthed(url) ?? url;
      }
      // Легаси gs:// (Firebase) / sb:// (Supabase) больше не резолвим — Firebase
      // убран. Такие старые ссылки в виджет не подгрузятся.
      else if (url.startsWith('gs://') || url.startsWith('sb://')) {
        await HomeWidget.saveWidgetData<String>(key, '');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final cachedUrl = prefs.getString('${key}_cached_url') ?? '';
      final cachedWPath = prefs.getString('${key}_cached_wpath') ?? '';

      // URL не изменился и путь в контейнере уже записан — повторно не качаем.
      if (cachedUrl == url && cachedWPath.isNotEmpty) {
        await HomeWidget.saveWidgetData<String>(key, cachedWPath);
        return;
      }

      // Уникальное имя = ключ + хэш ссылки. iOS WidgetKit кэширует картинку по
      // ПУТИ файла: при записи каждого нового фото в ОДИН и тот же файл виджет
      // держит старое изображение и не перерисовывается (баг «фото не
      // обновляется, пока стоит другое; уберёшь одно — второе оживает»). Меняя
      // путь при каждой смене фото, заставляем WidgetKit грузить свежее.
      final sig = url.hashCode.toUnsigned(32).toRadixString(16);
      final uniqueName = '${key}_$sig';

      final response = await http
          .get(Uri.parse(httpUrl))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('_downloadPhoto($key): HTTP ${response.statusCode} for $url');
        await HomeWidget.saveWidgetData<String>(key, '');
        return;
      }

      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$uniqueName.jpg');
      await file.writeAsBytes(response.bodyBytes);

      // Старые файлы этого ключа (контейнер + локальные) убираем ДО записи нового
      // пути, чтобы не копились и не оставалось «залипшего» кэша по старому пути.
      await HomeWidgetService.instance.clearAppGroupMedia(key);
      _cleanupOldLocalPhotos(dir, key, '$uniqueName.jpg');

      final widgetPath = await HomeWidgetService.instance
          .appGroupReadablePath(file.path, uniqueName);
      await HomeWidget.saveWidgetData<String>(key, widgetPath);
      await prefs.setString('${key}_cached_url', url);
      await prefs.setString('${key}_cached_wpath', widgetPath);
      debugPrint('_downloadPhoto: $key → $widgetPath');
    } catch (e) {
      debugPrint('_downloadPhoto($key) failed: $e');
      await HomeWidget.saveWidgetData<String>(key, '');
    }
  }

  /// Удаляет старые локальные файлы `<key>_*.jpg` (кроме [keepName]) из [dir] —
  /// чтобы уникальные имена фото не копились на диске.
  void _cleanupOldLocalPhotos(Directory dir, String key, String keepName) {
    try {
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        final name = f.path.split(Platform.pathSeparator).last;
        if (name.startsWith('${key}_') &&
            name.endsWith('.jpg') &&
            name != keepName) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PUBLIC SYNC
  // ══════════════════════════════════════════════════════════════════════════

  /// Forces an immediate re-sync of the native home-screen widget.
  /// Call this when the app comes to foreground so the widget is always fresh.
  Future<void> syncNow() => _syncToNativeWidget();

  /// Сбросить кэш профиля — вызывать после редактирования имени/аватара/пола,
  /// чтобы следующий _updateField подтянул свежие значения из users/{uid}.
  void invalidateProfileCache() {
    _cachedProfileName = null;
    _cachedProfileAvatar = null;
    _cachedProfileGender = null;
  }

  /// Проталкивает свежий профиль (имя/аватар/пол) в widgetData текущей группы
  /// и нативный виджет. Звать ПОСЛЕ смены аватара/имени.
  ///
  /// Без этого виджет показывает старый аватар до перезахода: профиль кэшируется
  /// на сессию ([_cachedProfileAvatar]), а единственный писатель аватара в
  /// widgetData — [_updateField] — берёт из кэша. Здесь сбрасываем кэш и пустым
  /// [_updateField] перечитываем профиль из users/{uid} → пишем свежий avatarUrl
  /// в widgetData (партнёр увидит через свой live-листенер) и сразу синхронизируем
  /// нативный виджет (он перекачает новую картинку — у аватара меняется URL).
  Future<void> refreshProfileOnWidget() async {
    invalidateProfileCache();
    if (_groupId.isEmpty) return;
    await _updateField(const {}, emitEvent: false);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DISPOSE
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void dispose() {
    _isDisposed = true;
    _syncNativeDebounce?.cancel();
    _mySub?.cancel();
    for (final sub in _partnerSubs.values) {
      sub.cancel();
    }
    _partnerSubs.clear();
    super.dispose();
  }
}
