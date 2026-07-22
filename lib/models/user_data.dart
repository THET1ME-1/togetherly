import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/pb_coins_service.dart';
import '../services/pb_data_service.dart';
import '../services/pocketbase_service.dart';
import '../services/push_background_service.dart';
import '../services/widget_background_refresh_service.dart';
import '../services/offline/offline_reset.dart';
import '../theme/app_theme.dart';
import '../utils/safe_text.dart';
import 'profile_icon.dart';

enum Gender { male, female }

class UserData extends ChangeNotifier {
  String _displayName = '';
  String _email = '';
  String _avatarUrl = '';
  Gender? _gender;
  bool _isRegistered = false;
  bool _hasSeenWelcome = false;
  String _uid = '';
  String? _badge;

  // ── Дата рождения (только день+месяц важны для поздравлений) ──
  DateTime? _birthDate;

  // ── Коины и премиум-контент ──
  // Локальные значения — только КЭШ. Источник правды — Firestore,
  // изменения идут исключительно через серверные Cloud Functions.
  int _coins = 0;
  final Set<int> _ownedThemes = <int>{};
  // Купленные профильные иконки (КЭШ; источник правды — Firestore/сервер).
  final Set<String> _ownedIcons = <String>{};
  // Разблокированные одноразовые фичи (КЭШ; источник правды — Firestore/сервер).
  final Set<String> _ownedFeatures = <String>{};
  // Иконки-награды, выданные вручную (Sponsor/Helper).
  final Set<String> _grantedBadges = <String>{};
  bool _devCoinsGranted = false;
  // В этой сессии уже обращались за dev-грантом (любой исход) — не долбим на
  // каждом lifecycle-событии (load/silent-sign-in/регистрация).
  bool _devCoinsAttempted = false;
  // Сервер дал ОКОНЧАТЕЛЬНЫЙ ответ (выдано или «ты не дев» 403/400) — persistent,
  // чтобы не-разработчики больше НИКОГДА не дёргали dev-coins (раньше это были
  // сотни `dev-coins 403` в Bugsink). Сбрасывается только на logout.
  bool _devCoinsChecked = false;
  int _adRewardsToday = 0;
  String _adRewardsDate = ''; // YYYY-MM-DD UTC; '' = ещё не получал

  /// Максимум rewarded-просмотров в сутки (зеркало AD_REWARDS_PER_DAY на сервере)
  static const int adRewardsDailyLimit = 3;

  /// Монет за один просмотр рекламы (зеркало AD_REWARD_AMOUNT на сервере)
  static const int adRewardAmount = 3;

  /// Кулдаун ежедневного бонуса и награды за воспоминание (зеркало COOLDOWN в
  /// coins.pb.js: 20ч). В пределах окна задание считается «выполненным».
  static const int _coinCooldownMs = 20 * 60 * 60 * 1000;

  // ── Getters ──
  String get displayName => _displayName;
  String get email => _email;
  String get avatarUrl => _avatarUrl;
  Gender? get gender => _gender;
  bool get isRegistered => _isRegistered;
  bool get hasSeenWelcome => _hasSeenWelcome;
  String get uid => _uid;
  String? get badge => _badge;

  set badge(String? value) {
    _badge = value;
    notifyListeners();
  }

  bool get isMale => _gender == Gender.male;
  bool get isFemale => _gender == Gender.female;

  DateTime? get birthDate => _birthDate;

  // ── Тема оформления ──────────────────────────────────────────────────────
  int _themeId = -1; // -1 → используется тема по умолчанию (pink)
  int? _previewThemeId; // временный оверрайд без сохранения (предпросмотр)
  bool _blobAnimationEnabled = true;

  int get themeId {
    if (_themeId >= 0 && _themeId < AppThemes.all.length) return _themeId;
    return 0; // default = pink
  }

  /// Полный объект активной темы со всеми цветами
  AppTheme get theme => AppThemes.byIndex(_previewThemeId ?? themeId);

  bool get isPreviewingTheme => _previewThemeId != null;
  int? get previewThemeId => _previewThemeId;

  /// Временно применить тему без сохранения. Передай null чтобы сбросить.
  void setPreviewTheme(int? id) {
    _previewThemeId = id;
    notifyListeners();
  }

  // Алиасы для удобства (используются в экранах)
  bool get isPurpleTheme => themeId == 1;
  Color get themeAccent => theme.primary;
  Color get themeAccentLight => theme.primaryLight;
  String get themeName => theme.name;

  // ── Коины ─────────────────────────────────────────────────────────────────
  int get coins => _coins;

  bool _dailyBonusClaimedThisSession = false;
  bool get dailyBonusClaimedThisSession => _dailyBonusClaimedThisSession;

  bool _memoryRewardClaimedThisSession = false;
  bool _memoryRewardClaimInProgress = false;
  bool get memoryRewardClaimedThisSession => _memoryRewardClaimedThisSession;

  /// Восстанавливает статус «выполнено» для ежедневного бонуса/воспоминания из
  /// серверных таймстампов кулдауна (epoch-ms). Без этого ✓ держится только на
  /// сессионном флаге, который ставится лишь при успешном начислении В ЭТОМ
  /// запуске → при повторном входе (или когда коин за период уже получен)
  /// задание ошибочно показывается невыполненным. В пределах кулдауна (20ч)
  /// считаем выполненным. Не сбрасываем уже выставленный флаг (на случай гонки
  /// между авто-начислением на старте и синком профиля).
  void _seedClaimFlagsFromServer(dynamic lastDailyMs, dynamic lastMemoryMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lastDailyMs is num && lastDailyMs > 0 &&
        now - lastDailyMs.toInt() < _coinCooldownMs) {
      _dailyBonusClaimedThisSession = true;
    }
    if (lastMemoryMs is num && lastMemoryMs > 0 &&
        now - lastMemoryMs.toInt() < _coinCooldownMs) {
      _memoryRewardClaimedThisSession = true;
    }
  }

  /// Сколько rewarded-просмотров пользователь сделал сегодня (UTC).
  /// Если последняя дата начисления — не сегодня, возвращает 0.
  int get adRewardsToday {
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    return _adRewardsDate == today ? _adRewardsToday : 0;
  }

  /// Сколько ещё просмотров доступно сегодня.
  int get adRewardsRemaining =>
      (adRewardsDailyLimit - adRewardsToday).clamp(0, adRewardsDailyLimit);

  /// Список ID разблокированных премиум-тем
  Set<int> get ownedThemes => Set.unmodifiable(_ownedThemes);

  /// Доступна ли тема (free или куплена)
  bool hasTheme(int id) {
    final t = AppThemes.byIndex(id);
    return !t.isPremium || _ownedThemes.contains(id);
  }

  // ── Профильные иконки ───────────────────────────────────────────────────────
  /// Купленные иконки (id из [ProfileIcon.all]).
  Set<String> get ownedIcons => Set.unmodifiable(_ownedIcons);

  /// Иконки-награды, выданные вручную (Sponsor/Helper).
  Set<String> get grantedBadges => Set.unmodifiable(_grantedBadges);

  /// Закреплённая рядом с именем иконка. null — не выбрана.
  String? get equippedIcon =>
      (_badge != null && _badge!.isNotEmpty) ? _badge : null;

  /// Доступна ли иконка пользователю (куплена или выдана).
  bool ownsIcon(String id) =>
      _ownedIcons.contains(id) || _grantedBadges.contains(id);

  /// Все доступные пользователю иконки (купленные + выданные), без дублей.
  Set<String> get availableIcons => {..._ownedIcons, ..._grantedBadges};

  // ── Одноразовые фичи ─────────────────────────────────────────────────────
  /// ID фичи: свои фото пары на виджете «Дни вместе» (зеркало FEATURE_PRICES).
  static const String featureDaysWidgetPhotos = 'days_widget_photos';

  /// Разблокированные одноразовые фичи.
  Set<String> get ownedFeatures => Set.unmodifiable(_ownedFeatures);

  /// Разблокирована ли фича пользователем.
  bool ownsFeature(String id) => _ownedFeatures.contains(id);

  /// Применяет результат, пришедший с сервера (callable function).
  /// Используется как единственный путь обновления баланса/owned.
  void _applyServerResult(Map<String, dynamic> result) {
    final coins = result['coins'];
    if (coins is num) _coins = coins.toInt();
    final owned = result['ownedThemes'];
    if (owned is List) {
      _ownedThemes
        ..clear()
        ..addAll(owned.whereType<num>().map((e) => e.toInt()));
    }
    final ownedI = result['ownedIcons'];
    if (ownedI is List) {
      _ownedIcons
        ..clear()
        ..addAll(ownedI.whereType<String>());
    }
    final ownedF = result['ownedFeatures'];
    if (ownedF is List) {
      _ownedFeatures
        ..clear()
        ..addAll(ownedF.whereType<String>());
    }
    unawaited(_saveLocal());
    notifyListeners();
  }

  /// Гарантирует, что баланс не упадёт ниже [floor].
  /// Вызывается после оптимистичного начисления, пока SSV ещё не подтвердил.
  void ensureCoinsAtLeast(int floor) {
    if (_coins < floor) {
      _coins = floor;
      notifyListeners();
    }
  }

  /// Оптимистичное начисление награды за рекламу — до подтверждения сервером.
  /// Даёт мгновенный отклик UI; сервер потом подтвердит через SSV (AdMob-путь).
  void applyOptimisticAdReward(int amount) {
    _coins += amount;
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    if (_adRewardsDate != today) {
      _adRewardsDate = today;
      _adRewardsToday = 0;
    }
    _adRewardsToday += 1;
    _saveLocal();
    notifyListeners();
  }

  /// Применяет АВТОРИТЕТНЫЙ результат начисления за рекламу (Яндекс-callable
  /// `grantAdReward` синхронно возвращает реальный баланс). В отличие от
  /// [applyOptimisticAdReward] не угадывает сумму — ставит точный серверный
  /// баланс. Счётчик увеличивается только если сервер РЕАЛЬНО начислил
  /// ([granted]); при дневном лимите счётчик выставляется в максимум, чтобы
  /// кнопка корректно заблокировалась.
  void applyServerAdReward({required int coins, required bool granted}) {
    _coins = coins;
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    if (_adRewardsDate != today) {
      _adRewardsDate = today;
      _adRewardsToday = 0;
    }
    _adRewardsToday =
        granted ? _adRewardsToday + 1 : adRewardsDailyLimit;
    _saveLocal();
    notifyListeners();
  }

  /// Перезагружает coins/ownedThemes с сервера.
  Future<void> refreshCoinsFromServer() async {
    try {
      final data = await PbDataService().loadUserProfileMap(PocketBaseService().userId ?? "");
      if (data == null) return;
      final cloudCoins = data['coins'];
      if (cloudCoins is num) _coins = cloudCoins.toInt();
      final cloudOwned = data['ownedThemes'];
      if (cloudOwned is List) {
        _ownedThemes
          ..clear()
          ..addAll(cloudOwned.whereType<num>().map((e) => e.toInt()));
      }
      final cloudOwnedIcons = data['ownedIcons'];
      if (cloudOwnedIcons is List) {
        _ownedIcons
          ..clear()
          ..addAll(cloudOwnedIcons.whereType<String>());
      }
      final cloudOwnedFeatures = data['ownedFeatures'];
      if (cloudOwnedFeatures is List) {
        _ownedFeatures
          ..clear()
          ..addAll(cloudOwnedFeatures.whereType<String>());
      }
      // Счётчик просмотров рекламы за день. Без этого после серверного
      // начисления (Яндекс grantAdReward / AdMob SSV) клиентский «X/3» не
      // догоняет правду сервера, счётчик «застывает» и задание не отмечается
      // выполненным даже когда лимит исчерпан.
      final cloudAdCount = data['adRewardsToday'];
      if (cloudAdCount is num) _adRewardsToday = cloudAdCount.toInt();
      final cloudAdDate = data['adRewardsDate'];
      if (cloudAdDate is String) _adRewardsDate = cloudAdDate;
      _seedClaimFlagsFromServer(data['lastDailyBonusMs'], data['lastMemoryRewardMs']);
      await _saveLocal();
      notifyListeners();
    } catch (e) {
      debugPrint('refreshCoinsFromServer failed: $e');
    }
  }

  /// Ежедневный бонус. Возвращает true при успешном начислении (false если cooldown).
  Future<bool> claimDailyBonus() async {
    final r = await PbCoinsService().dailyBonus();
    if (r == null) return false;
    _applyServerResult(r);
    final awarded = r['ok'] == true;
    if (awarded) {
      _dailyBonusClaimedThisSession = true;
      notifyListeners();
    }
    return awarded;
  }

  /// Награда за добавление воспоминания (1 🪙/день).
  /// Возвращает кол-во начисленных монет, или 0 если cooldown/ошибка.
  Future<int> claimMemoryReward() async {
    if (_memoryRewardClaimedThisSession || _memoryRewardClaimInProgress) return 0;
    _memoryRewardClaimInProgress = true;
    try {
      final r = await PbCoinsService().memoryReward();
      if (r == null) return 0;
      _applyServerResult(r);
      final amount = (r['ok'] == true) ? (r['awarded'] as num?)?.toInt() ?? 0 : 0;
      if (amount > 0) {
        _memoryRewardClaimedThisSession = true;
        notifyListeners();
      }
      return amount;
    } finally {
      _memoryRewardClaimInProgress = false;
    }
  }

  /// Награда за подключение партнёра (50 🪙). Выдаётся по одному разу на каждую
  /// УНИКАЛЬНУЮ пару людей (дедуп на сервере по email/uid партнёра), обоим
  /// участникам независимо. [partnerUid] — uid второго участника пары.
  /// Возвращает кол-во начисленных монет, или 0 если уже выдано/нет партнёра.
  Future<int> claimPartnerInviteReward(String partnerUid) async {
    if (partnerUid.isEmpty) return 0;
    final r = await PbCoinsService().partnerInvite(partnerUid);
    if (r == null) return 0;
    _applyServerResult(r);
    return (r['ok'] == true) ? (r['awarded'] as num?)?.toInt() ?? 0 : 0;
  }

  /// Награда за 7-дневный стрик настроения обоих (10 🪙 раз в 7 дней).
  /// Возвращает кол-во начисленных монет, или 0 если cooldown.
  Future<int> claimMoodStreakReward(String groupId) async {
    final r = await PbCoinsService().moodStreak(groupId);
    if (r == null) return 0;
    _applyServerResult(r);
    return (r['ok'] == true) ? (r['awarded'] as num?)?.toInt() ?? 0 : 0;
  }

  /// Пытается купить тему на сервере. Возвращает true при успехе.
  Future<bool> purchaseTheme(int themeId) async {
    final t = AppThemes.byIndex(themeId);
    if (!t.isPremium) return true; // free
    if (_ownedThemes.contains(themeId)) return true;
    final r = await PbCoinsService().purchaseTheme(themeId);
    if (r == null) return false;
    _applyServerResult(r);
    return _ownedThemes.contains(themeId);
  }

  /// Покупает профильную иконку на сервере. Возвращает true при успехе.
  /// Списание монет и запись в ownedIcons делает Cloud Function `purchaseIcon`
  /// (защищено от обхода цены/двойного списания).
  Future<bool> purchaseIcon(ProfileIcon icon) async {
    if (icon.grantOnly) return false; // награды не продаются
    if (_ownedIcons.contains(icon.id)) return true; // уже куплена
    final r = await PbCoinsService().purchaseIcon(icon.id);
    if (r == null) return false;
    _applyServerResult(r);
    return _ownedIcons.contains(icon.id);
  }

  /// Покупает одноразовую разблокировку фичи за коины. Возвращает true при успехе.
  /// Списание монет и запись в ownedFeatures делает Cloud Function `purchaseFeature`
  /// (защищено от обхода цены/двойного списания).
  /// Гасит код пополнения. Возвращает начисленные монеты, либо null при
  /// ошибке (неверный код, уже погашен, нет связи).
  Future<int?> redeemCode(String code) async {
    final r = await PbCoinsService().redeem(code);
    if (r == null || r['ok'] != true) return null;
    _applyServerResult(r);
    final awarded = (r['awarded'] as num?)?.toInt() ?? 0;
    return awarded;
  }

  Future<bool> purchaseFeature(String featureId) async {
    if (_ownedFeatures.contains(featureId)) return true; // уже куплена
    final r = await PbCoinsService().purchaseFeature(featureId);
    if (r == null) return false;
    _applyServerResult(r);
    return _ownedFeatures.contains(featureId);
  }

  /// Списывает коины за расходуемое действие (напр. смена фона чата).
  /// Списывает КАЖДЫЙ раз. Цена и проверка баланса — на сервере.
  /// Возвращает true при успешном списании.
  Future<bool> spendCoins(String actionId) async {
    final r = await PbCoinsService().spend(actionId);
    if (r == null) return false;
    _applyServerResult(r);
    return r['ok'] == true;
  }

  /// Закрепляет иконку рядом с именем (или снимает, если [id] == null/'').
  /// badge не влияет на экономику — пишется напрямую (как и раньше).
  /// Закрепить можно только доступную (купленную/выданную) иконку.
  Future<void> setBadgeIcon(String? id) async {
    final clear = id == null || id.isEmpty;
    if (!clear && !ownsIcon(id)) return; // нельзя закрепить чужую иконку
    _badge = clear ? null : id;
    await _saveLocal();
    await PbDataService().updateUserProfile(PocketBaseService().userId ?? "", {'badge': _badge ?? ''});
    notifyListeners();
  }

  /// Выдаёт иконку-награду (Sponsor/Helper). Идемпотентно.
  /// Если у пользователя ещё нет закреплённой иконки — закрепляет автоматически.
  /// Грант определяется по e-mail в [main] (та же модель доверия, что и раньше).
  ///
  /// Возвращает true, только если бейдж выдан ВПЕРВЫЕ (его не было в наборе) —
  /// чтобы вызывающий код мог разово уведомить пользователя, а не на каждом
  /// запуске.
  Future<bool> grantSpecialBadge(String id) async {
    final added = _grantedBadges.add(id);
    final autoEquip = _badge == null || _badge!.isEmpty;
    if (!added && !autoEquip) return false; // ничего не изменилось — без записи
    if (autoEquip) _badge = id;
    await _saveLocal();
    await PbDataService().updateUserProfile(PocketBaseService().userId ?? "", {
      'grantedBadges': _grantedBadges.toList(),
      'badge': _badge ?? '',
    });
    notifyListeners();
    return added;
  }

  /// Начисляет монеты после успешной IAP-покупки.
  ///
  /// Вызывается из [IapService] после того, как магазин подтвердил транзакцию.
  /// Передаёт [productId] и [purchaseToken] на PB-хук; сервер валидирует
  /// idempotency и начисляет монеты.
  ///
  /// Возвращает новый баланс или null при сетевой / серверной ошибке.
  Future<int?> purchaseCoins({
    required String productId,
    required String purchaseToken,
  }) async {
    final r = await PbCoinsService().iapPurchase(
      productId: productId,
      purchaseToken: purchaseToken,
    );
    if (r == null) return null;
    _applyServerResult(r);
    return _coins;
  }

  /// Единоразовая серверная выдача монет разработчику (проверка email
  /// делается на сервере по auth-токену, обойти невозможно).
  Future<void> _maybeGrantDevCoins() async {
    if (_devCoinsGranted || _devCoinsChecked) return; // уже выдано/отвечено
    if (_devCoinsAttempted) return; // в этой сессии уже пробовали — не долбим
    _devCoinsAttempted = true;
    final r = await PbCoinsService().devCoinsGrant();
    if (r.result == DevCoinsResult.retry) return; // сеть/сессия — позже
    // Сервер ответил окончательно (выдано или отказано) — больше не спрашиваем.
    _devCoinsChecked = true;
    final data = r.data;
    if (r.result == DevCoinsResult.ok && data != null) {
      _applyServerResult(data);
      if (data['ok'] == true) _devCoinsGranted = true;
    }
    await _saveLocal();
  }

  /// Whether the timer card shows a morphing blob shape (true by default)
  bool get blobAnimationEnabled => _blobAnimationEnabled;

  String get initials {
    final name = _displayName.trim();
    if (name.isEmpty) return '?';
    // По графемам, иначе имя с ведущим эмодзи рвёт суррогатную пару (см. SafeText).
    final parts = name.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts[0].firstGraphemeUpper('')}${parts[1].firstGraphemeUpper('')}';
    }
    return name.firstGraphemeUpper();
  }

  // ── Persistence (локальный кэш + Firestore) ──
  Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _hasSeenWelcome = prefs.getBool('hasSeenWelcome') ?? false;
      _isRegistered = prefs.getBool('isRegistered') ?? false;
      _displayName = prefs.getString('displayName') ?? '';
      _email = prefs.getString('email') ?? '';
      _avatarUrl = prefs.getString('avatarUrl') ?? '';
      _uid = prefs.getString('uid') ?? '';
      final genderStr = prefs.getString('gender');
      if (genderStr == 'male') _gender = Gender.male;
      if (genderStr == 'female') _gender = Gender.female;
      _themeId = prefs.getInt('themeId') ?? -1;
      _blobAnimationEnabled = prefs.getBool('blobAnimationEnabled') ?? true;
      _badge = prefs.getString('badge');
      _coins = prefs.getInt('coins') ?? 0;
      _devCoinsGranted = prefs.getBool('devCoinsGranted') ?? false;
      _devCoinsChecked = prefs.getBool('devCoinsChecked') ?? false;
      _adRewardsToday = prefs.getInt('adRewardsToday') ?? 0;
      _adRewardsDate = prefs.getString('adRewardsDate') ?? '';
      final bdMs = prefs.getInt('birthDate');
      _birthDate = bdMs != null
          ? DateTime.fromMillisecondsSinceEpoch(bdMs)
          : null;
      _ownedThemes
        ..clear()
        ..addAll(
          (prefs.getStringList('ownedThemes') ?? const <String>[])
              .map(int.tryParse)
              .whereType<int>(),
        );
      _ownedIcons
        ..clear()
        ..addAll(prefs.getStringList('ownedIcons') ?? const <String>[]);
      _ownedFeatures
        ..clear()
        ..addAll(prefs.getStringList('ownedFeatures') ?? const <String>[]);
      _grantedBadges
        ..clear()
        ..addAll(prefs.getStringList('grantedBadges') ?? const <String>[]);

      // Если авторизован → подтягиваем из облака
      if (PocketBaseService().isLoggedIn && _isRegistered) {
        _uid = PocketBaseService().userId ?? _uid;
        await _syncFromFirestore();
        await _maybeGrantDevCoins();
      }
    } catch (e) {
      debugPrint('SharedPreferences load failed: $e');
    }
    notifyListeners();
  }

  /// Публичная ре-синхронизация с сервером после восстановления сессии
  /// (`signInSilently`). [loadFromPrefs] синкается только если на момент его
  /// вызова уже была активная сессия; при тихом входе сессия поднимается позже,
  /// поэтому без этого вызова приложение весь сеанс показывало бы устаревший
  /// локальный баланс/темы, а серверные начисления молча применялись бы поверх
  /// неактуального состояния.
  Future<void> syncFromServer() async {
    if (!PocketBaseService().isLoggedIn) return;
    await _syncFromFirestore();
    await _maybeGrantDevCoins();
  }

  Future<void> _syncFromFirestore() async {
    try {
      final data = await PbDataService().loadUserProfileMap(PocketBaseService().userId ?? "");
      if (data != null) {
        _displayName = data['displayName'] ?? _displayName;
        _email = data['email'] ?? _email;
        // Only overwrite local avatar if Firestore has a real non-empty value.
        // An empty string in Firestore means the field was accidentally cleared —
        // preserve whatever the user set locally in that case.
        final firestoreAvatar = data['avatarUrl'] as String? ?? '';
        if (firestoreAvatar.isNotEmpty) _avatarUrl = firestoreAvatar;
        final g = data['gender'] as String?;
        if (g == 'male') _gender = Gender.male;
        if (g == 'female') _gender = Gender.female;
        _badge = data['badge'] as String?;

        final cloudCoins = data['coins'];
        if (cloudCoins is int) _coins = cloudCoins;
        final cloudOwned = data['ownedThemes'];
        if (cloudOwned is List) {
          _ownedThemes
            ..clear()
            ..addAll(cloudOwned.whereType<int>());
        }
        final cloudOwnedIcons = data['ownedIcons'];
        if (cloudOwnedIcons is List) {
          _ownedIcons
            ..clear()
            ..addAll(cloudOwnedIcons.whereType<String>());
        }
        final cloudOwnedFeatures = data['ownedFeatures'];
        if (cloudOwnedFeatures is List) {
          _ownedFeatures
            ..clear()
            ..addAll(cloudOwnedFeatures.whereType<String>());
        }
        final cloudGrantedBadges = data['grantedBadges'];
        if (cloudGrantedBadges is List) {
          _grantedBadges
            ..clear()
            ..addAll(cloudGrantedBadges.whereType<String>());
        }
        final cloudGranted = data['devCoinsGranted'];
        if (cloudGranted is bool) _devCoinsGranted = cloudGranted;

        final cloudAdCount = data['adRewardsToday'];
        if (cloudAdCount is num) _adRewardsToday = cloudAdCount.toInt();
        final cloudAdDate = data['adRewardsDate'];
        if (cloudAdDate is String) _adRewardsDate = cloudAdDate;
        _seedClaimFlagsFromServer(
            data['lastDailyBonusMs'], data['lastMemoryRewardMs']);

        final bdRaw = data['birthDate'];
        if (bdRaw is String && bdRaw.isNotEmpty) {
          _birthDate = DateTime.tryParse(bdRaw);
        } else if (bdRaw is int) {
          _birthDate = DateTime.fromMillisecondsSinceEpoch(bdRaw);
        }

        await _saveLocal();

        // Propagate name/avatar to all group documents on every login so
        // partners always see the real name even if the user never explicitly
        // edited their profile after connecting (fixes 'Partner' fallback).
        final myUid = PocketBaseService().userId ?? '';
        if (_displayName.isNotEmpty) {
          unawaited(PbDataService()
              .updateMemberFieldInGroups(myUid, 'member_names', _displayName));
        }
        if (_avatarUrl.isNotEmpty) {
          unawaited(PbDataService()
              .updateMemberFieldInGroups(myUid, 'member_avatars', _avatarUrl));
        }
      }
    } catch (e) {
      debugPrint('Firestore sync failed: $e');
    }
  }

  Future<void> _saveLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('hasSeenWelcome', _hasSeenWelcome);
      await prefs.setBool('isRegistered', _isRegistered);
      await prefs.setString('displayName', _displayName);
      await prefs.setString('email', _email);
      await prefs.setString('avatarUrl', _avatarUrl);
      await prefs.setString('uid', _uid);
      await prefs.setString(
        'gender',
        _gender == Gender.male
            ? 'male'
            : _gender == Gender.female
            ? 'female'
            : '',
      );
      await prefs.setInt('themeId', _themeId);
      await prefs.setBool('blobAnimationEnabled', _blobAnimationEnabled);
      if (_birthDate != null) {
        await prefs.setInt('birthDate', _birthDate!.millisecondsSinceEpoch);
      } else {
        await prefs.remove('birthDate');
      }
      if (_badge != null) {
        await prefs.setString('badge', _badge!);
      } else {
        await prefs.remove('badge');
      }
      await prefs.setInt('coins', _coins);
      await prefs.setBool('devCoinsGranted', _devCoinsGranted);
      await prefs.setBool('devCoinsChecked', _devCoinsChecked);
      await prefs.setInt('adRewardsToday', _adRewardsToday);
      await prefs.setString('adRewardsDate', _adRewardsDate);
      await prefs.setStringList(
        'ownedThemes',
        _ownedThemes.map((e) => e.toString()).toList(),
      );
      await prefs.setStringList('ownedIcons', _ownedIcons.toList());
      await prefs.setStringList('ownedFeatures', _ownedFeatures.toList());
      await prefs.setStringList('grantedBadges', _grantedBadges.toList());
    } catch (e) {
      debugPrint('SharedPreferences save failed: $e');
    }
  }

  // ── Actions ──
  Future<void> markWelcomeSeen() async {
    _hasSeenWelcome = true;
    await _saveLocal();
    notifyListeners();
  }

  Future<void> register({
    required String displayName,
    required String email,
    required Gender gender,
    String avatarUrl = '',
    bool isReturningUser = false, // For login - don't clear data
  }) async {
    // Clear old connection data when registering new user
    final prefs = await SharedPreferences.getInstance();
    final storedUid = prefs.getString('uid') ?? '';
    final currentUid = PocketBaseService().userId ?? '';

    // isNewUser = UID changed AND this is NOT a returning user (login)
    final isNewUser =
        storedUid != currentUid && currentUid.isNotEmpty && !isReturningUser;

    // If UID changed and this is fresh registration, clear ALL old data
    if (isNewUser) {
      await prefs.remove('connections');
      await prefs.remove('activeConnectionIndex');
      await prefs.remove('user_timers');
      await prefs.remove('timer_selected_time_unit');
      debugPrint(
        'Cleared old connections & timers for new user: $storedUid -> $currentUid',
      );
    }

    _displayName = displayName;
    _email = email;
    _gender = gender;
    _avatarUrl = avatarUrl;
    _isRegistered = true;
    _uid = PocketBaseService().userId ?? '';

    await _saveLocal();
    notifyListeners();

    // Сетевое обогащение профиля (запись имени/пола, синк коинов/тем из облака,
    // dev-коины) — БЕСТ-ЭФФОРТ и НЕ должно блокировать завершение входа. Раньше
    // эти три вызова await'ились ЗДЕСЬ и БЕЗ ТАЙМАУТА → если любой повисал
    // (наблюдалось на iOS: «бесконечная загрузка после кнопки Вход/Регистрация»),
    // register() не возвращался, экран входа не навигировал на главный, спиннер
    // крутился вечно. Локальное состояние «вошёл» уже сохранено выше, поэтому
    // уводим обогащение в фон с таймаутами; оно обновит UI через notifyListeners.
    final uid = PocketBaseService().userId ?? '';
    if (PocketBaseService().isLoggedIn && uid.isNotEmpty) {
      unawaited(_enrichAfterLogin(
        uid: uid,
        displayName: displayName,
        gender: gender,
        avatarUrl: avatarUrl,
        isNewUser: isNewUser,
      ));
    }
  }

  /// Фоновое обогащение профиля после входа: запись профиля + синк облака +
  /// dev-коины. Best-effort, каждый шаг с таймаутом — НЕ блокирует вход.
  Future<void> _enrichAfterLogin({
    required String uid,
    required String displayName,
    required Gender gender,
    required String avatarUrl,
    required bool isNewUser,
  }) async {
    const t = Duration(seconds: 12);
    try {
      await PbDataService().updateUserProfile(uid, {
        'displayName': displayName,
        'gender': gender == Gender.male ? 'male' : 'female',
        'avatarUrl': avatarUrl,
        // Сброс пары для нового юзера (email/пароль — поля auth, не трогаем тут).
        if (isNewUser) 'pairId': '',
        if (isNewUser) 'pairIds': <String>[],
      }).timeout(t);
    } catch (e) {
      debugPrint('UserData._enrichAfterLogin updateProfile failed: $e');
    }
    // Синхронизируем монеты/темы с сервера — важно после переустановки, когда
    // SharedPreferences очищены, но облако хранит реальный баланс.
    try {
      await _syncFromFirestore().timeout(t);
    } catch (e) {
      debugPrint('UserData._enrichAfterLogin sync failed: $e');
    }
    try {
      await _maybeGrantDevCoins().timeout(t);
    } catch (e) {
      debugPrint('UserData._enrichAfterLogin devCoins failed: $e');
    }
    notifyListeners();
  }

  Future<void> updateProfile({
    String? displayName,
    String? email,
    String? avatarUrl,
    Gender? gender,
  }) async {
    if (displayName != null) _displayName = displayName;
    if (email != null) _email = email;
    if (avatarUrl != null) _avatarUrl = avatarUrl;
    if (gender != null) _gender = gender;
    await _saveLocal();

    final uid = PocketBaseService().userId ?? '';
    if (PocketBaseService().isLoggedIn && uid.isNotEmpty) {
      await PbDataService().updateUserProfile(uid, {
        'displayName': _displayName,
        'gender': _gender == Gender.male ? 'male' : 'female',
        'avatarUrl': _avatarUrl,
      });
      // Propagate name/avatar changes to all groups so partners receive
      // the update via the group real-time listener.
      if (displayName != null) {
        await PbDataService().updateMemberFieldInGroups(
            uid, 'member_names', _displayName);
      }
      if (avatarUrl != null) {
        await PbDataService().updateMemberFieldInGroups(
            uid, 'member_avatars', _avatarUrl);
      }
    }
    notifyListeners();
  }

  Future<void> setThemeId(int id) async {
    if (id < 0 || id >= AppThemes.all.length) return;
    _themeId = id;
    await _saveLocal();
    notifyListeners();
  }

  Future<void> setBlobAnimationEnabled(bool value) async {
    _blobAnimationEnabled = value;
    await _saveLocal();
    notifyListeners();
  }

  Future<void> updateBirthDate(DateTime? date) async {
    _birthDate = date;
    await _saveLocal();
    await PbDataService().updateUserProfile(PocketBaseService().userId ?? "", {'birthDate': date});
    notifyListeners();
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    PocketBaseService().signOut();
    // Офлайн-кэш предыдущего юзера не должен пережить выход (иначе следующий
    // увидит чужие данные). Чистим локальную копию данных.
    await resetOfflineState();
    // Гасим фоновый пуш-сервис (§5): иначе его постоянное уведомление и
    // SSE-подписка с уже невалидной сессией остались бы висеть после выхода.
    await PushBackgroundService().stop();
    await WidgetBackgroundRefreshService.instance.cancel();
    _isRegistered = false;
    _displayName = '';
    _email = '';
    _avatarUrl = '';
    _gender = null;
    _uid = '';
    await prefs.setBool('isRegistered', false);
    await prefs.remove('displayName');
    await prefs.remove('email');
    await prefs.remove('avatarUrl');
    await prefs.remove('gender');
    await prefs.remove('uid');
    // Clear connection data as well
    await prefs.remove('connections');
    await prefs.remove('activeConnectionIndex');
    await prefs.remove('preferredPartnerUid');
    // Clear timer data so new user doesn't see old timers
    await prefs.remove('user_timers');
    await prefs.remove('timer_selected_time_unit');
    _coins = 0;
    _devCoinsGranted = false;
    _devCoinsChecked = false;
    _devCoinsAttempted = false;
    _ownedThemes.clear();
    _ownedIcons.clear();
    _ownedFeatures.clear();
    _grantedBadges.clear();
    _badge = null;
    _adRewardsToday = 0;
    _adRewardsDate = '';
    await prefs.remove('coins');
    await prefs.remove('devCoinsGranted');
    await prefs.remove('devCoinsChecked');
    await prefs.remove('ownedThemes');
    await prefs.remove('ownedIcons');
    await prefs.remove('ownedFeatures');
    await prefs.remove('grantedBadges');
    await prefs.remove('badge');
    await prefs.remove('adRewardsToday');
    await prefs.remove('adRewardsDate');
    notifyListeners();
  }

  /// Полное удаление аккаунта (требование App Store 5.1.1(v)).
  ///
  /// Порядок важен — удаление auth-записи должно идти, пока сессия ещё валидна:
  ///   1) Распускаем/покидаем все активные пары (soft-disband: данные
  ///      восстановимы партнёром, но удаляемому аккаунту они больше недоступны).
  ///   2) Удаляем саму запись пользователя в PocketBase. Delete-правило
  ///      коллекции `users` = `id = @request.auth.id`, поэтому самоудаление
  ///      разрешено; после него войти под старым аккаунтом невозможно.
  ///   3) Локальный [logout] — чистит офлайн-кэш, сессию и фоновые сервисы.
  ///
  /// Шаг 1 — best-effort (его сбой не блокирует удаление). Если шаг 2 бросает
  /// исключение, оно пробрасывается наверх — UI показывает ошибку и НЕ выходит.
  Future<void> deleteAccount() async {
    final pb = PocketBaseService();
    final uid = pb.userId ?? _uid;
    if (uid.isEmpty) {
      // Нет активной сессии — просто чистим локальное состояние.
      await logout();
      return;
    }

    // 1. Распускаем/покидаем все активные группы пользователя (best-effort).
    try {
      final groups = await PbDataService().activeGroupRecordsForUser(uid);
      for (final g in groups) {
        try {
          await PbDataService().unpairGroup(g.id, uid);
        } catch (e) {
          debugPrint('deleteAccount: unpair ${g.id} failed: $e');
        }
      }
    } catch (e) {
      debugPrint('deleteAccount: unpair phase failed: $e');
    }

    // 2. Удаляем саму запись пользователя (пока сессия ещё валидна).
    await pb.pb.collection('users').delete(uid);

    // 3. Локальный выход: кэш, сессия, фоновые сервисы.
    await logout();
  }
}
