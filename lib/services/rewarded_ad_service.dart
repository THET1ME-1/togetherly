import 'dart:async';
import 'dart:io';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:yandex_mobileads/mobile_ads.dart' as yandex;

import 'pb_coins_service.dart';

/// Загрузка и показ rewarded-видео по схеме «водопад»: сначала Яндекс, и если
/// у Яндекса нет рекламы ([onAdFailedToLoad]) — резерв из AdMob (Google).
///
/// У Яндекса Google-SSV нет: факт досмотра возвращается из [show] (`true`), и
/// награда начисляется серверным callable [FirebaseService.callGrantAdReward]
/// (авторитетно, с дневным лимитом) прямо в [_showYandex]. AdMob (резерв) выдаёт
/// награду НЕ сам — это делает серверный SSV-callback (Cloud Function
/// adSsvCallback), который проверяет подпись Google и начисляет коины по `uid`
/// из `customData`.
class RewardedAdService {
  // AdMob — резервная сеть. Debug использует официальный test-блок Google.
  static const String _testRewardedAdUnit =
      'ca-app-pub-3940256099942544/5224354917';
  static const String _prodRewardedAdUnit =
      'ca-app-pub-1956369312643059/7521878316';

  // Яндекс — основная сеть. Debug использует официальный demo-блок Яндекса.
  static const String _prodYandexRewardedUnit = 'R-M-19386995-2';
  static const String _demoYandexRewardedUnit = 'demo-rewarded-yandex';

  RewardedAd? _ad;
  yandex.RewardedAd? _yandexAd;
  yandex.RewardedAdLoader? _yandexLoader;
  bool _isLoading = false;
  // Идёт показ ролика. Защита от «реклама показывается дважды»: двойной тап по
  // кнопке (она тапабельна в зазоре между тапом и появлением полноэкранной
  // рекламы) или гонка вызовов show() не должны запускать второй ролик.
  bool _isShowing = false;

  // Фоновый авто-ретрай предзагрузки. Когда обе сети не дали рекламу (частый
  // транзиентный no-fill), без ретрая реклама остаётся «не готова» до тех пор,
  // пока юзер не тапнет кнопку — и только этот тап перезапускал загрузку.
  // Отсюда симптом «первый тап — не готово, второй — работает». Сами
  // перезапрашиваем каскад с backoff, чтобы ролик дозагрузился, пока юзер ещё
  // на экране, и тап был мгновенным.
  static const List<Duration> _retryBackoff = [
    Duration(seconds: 3),
    Duration(seconds: 6),
    Duration(seconds: 12),
  ];
  Timer? _retryTimer;
  int _retryCount = 0;
  bool _disposed = false;

  String get _adUnitId =>
      kDebugMode ? _testRewardedAdUnit : _prodRewardedAdUnit;

  String get _yandexAdUnitId =>
      kDebugMode ? _demoYandexRewardedUnit : _prodYandexRewardedUnit;

  /// Готова реклама хоть из одной сети.
  bool get isReady => _ad != null || _yandexAd != null;

  /// True, если показанная реклама была из Яндекса (нет Google-SSV → награду
  /// начисляет серверный callable `grantAdReward`, авторитетно).
  bool _lastShowWasYandex = false;
  bool get lastShowWasYandex => _lastShowWasYandex;

  /// Авторитетный баланс коинов после Яндекс-показа (из ответа `grantAdReward`).
  /// null — для AdMob-пути (там баланс приходит позже через SSV) или если
  /// callable не ответил (не задеплоен/оффлайн) — тогда баланс надо подтянуть
  /// с сервера отдельно.
  int? _lastServerCoins;
  int? get lastServerCoins => _lastServerCoins;

  /// True, если сервер РЕАЛЬНО начислил награду за Яндекс-показ (false при
  /// дневном лимите/ошибке). Нужно, чтобы не показывать фейковую награду.
  bool _lastRewardGranted = false;
  bool get lastRewardGranted => _lastRewardGranted;

  /// True, если сервер отказал из-за дневного лимита (а не из-за ошибки).
  /// Используется, чтобы показать пользователю «лимит исчерпан».
  bool _lastRateLimited = false;
  bool get lastRateLimited => _lastRateLimited;

  /// Предзагружает рекламу: сначала Яндекс, при неудаче — AdMob.
  /// Безопасно дёргать несколько раз.
  Future<void> load() async {
    if (_disposed) return;
    if (_isLoading || isReady) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _retryTimer?.cancel();
    _isLoading = true;
    unawaited(_loadYandex());
  }

  /// Резервная загрузка AdMob — вызывается, когда Яндекс не дал рекламы.
  Future<void> _loadAdMob() async {
    if (_disposed) return;
    try {
      await RewardedAd.load(
        adUnitId: _adUnitId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            _ad = ad;
            _isLoading = false;
            _retryCount = 0; // успех — сбрасываем backoff
          },
          onAdFailedToLoad: (error) {
            debugPrint('AdMob rewarded failed ($error)');
            _ad = null;
            // Обе сети не дали рекламу → планируем фоновый ретрай каскада.
            _scheduleRetry();
          },
        ),
      );
    } catch (e) {
      debugPrint('AdMob rewarded load exception: $e');
      _scheduleRetry();
    }
  }

  /// Планирует фоновую перезагрузку каскада после полного провала обеих сетей.
  /// Backoff и лимит попыток — чтобы не молотить запросами при оффлайне.
  void _scheduleRetry() {
    _isLoading = false;
    if (_disposed || isReady) return;
    if (_retryCount >= _retryBackoff.length) return; // лимит исчерпан
    final delay = _retryBackoff[_retryCount];
    _retryCount++;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (_disposed || isReady) return;
      load();
    });
  }

  Future<void> _loadYandex() async {
    try {
      _yandexLoader ??= await yandex.RewardedAdLoader.create(
        onAdLoaded: (ad) {
          _yandexAd = ad;
          _isLoading = false;
          _retryCount = 0; // успех — сбрасываем backoff
        },
        onAdFailedToLoad: (error) {
          debugPrint(
              'Yandex rewarded failed: ${error.code} ${error.description}'
              ' → AdMob fallback');
          _yandexAd = null;
          unawaited(_loadAdMob());
        },
      );
      await _yandexLoader!.loadAd(
        adRequestConfiguration:
            yandex.AdRequestConfiguration(adUnitId: _yandexAdUnitId),
      );
    } catch (e) {
      debugPrint('Yandex rewarded load exception: $e → AdMob fallback');
      unawaited(_loadAdMob());
    }
  }

  /// Показывает загруженную рекламу (Яндекс в приоритете, иначе AdMob-резерв).
  ///
  /// `uid` — uid пользователя, передаётся в SSV `custom_data` (только AdMob).
  /// Возвращает true, если пользователь досмотрел до награды. Для Яндекса
  /// награда начисляется внутри [_showYandex] (callable), для AdMob — на сервере
  /// через SSV.
  Future<bool> show({required String uid}) async {
    // Уже идёт показ — игнорируем повторный вызов (двойной тап/гонка), иначе
    // запустится второй ролик подряд.
    if (_isShowing) return false;
    _isShowing = true;
    // Сбрасываем авторитетный результат прошлого показа.
    _lastServerCoins = null;
    _lastRewardGranted = false;
    _lastRateLimited = false;
    try {
      if (_yandexAd != null) {
        _lastShowWasYandex = true;
        return await _showYandex(_yandexAd!);
      }
      if (_ad != null) {
        _lastShowWasYandex = false;
        return await _showAdMob(_ad!);
      }
      return false;
    } finally {
      _isShowing = false;
    }
  }

  Future<bool> _showAdMob(RewardedAd ad) async {
    _ad = null; // одноразовая

    bool earned = false;
    final completer = Completer<bool>();

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        if (!completer.isCompleted) completer.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('RewardedAd show failed: $error');
        unawaited(Sentry.captureException(
          'AdMob rewarded failed to show: ${error.code} ${error.message}',
          withScope: (s) {
            s.setExtra('reason', 'admob rewarded show failed');
            s.level = SentryLevel.warning;
          },
        ));
        ad.dispose();
        if (!completer.isCompleted) completer.complete(false);
      },
    );

    ad.show(
      onUserEarnedReward: (_, reward) {
        earned = true;
      },
    );
    final result = await completer.future;
    if (result) {
      // У AdMob на PocketBase серверного SSV-callback нет (adSsvCallback не
      // портирован), поэтому начисляем тем же авторитетным роутом, что и Яндекс
      // (/api/coins/ad-reward). Без этого сервер не видит просмотр → суточный
      // счётчик «X/3» откатывался к нулю при следующем синке профиля, а коины
      // держались лишь оптимистично (ensureCoinsAtLeast).
      await _grantAdReward();
    } else {
      // Закрыл рекламу до награды — коинов не будет.
      // Breadcrumb (не ошибка: чаще это просто ранний выход пользователя).
      Sentry.addBreadcrumb(Breadcrumb(
          message: 'ad_reward: AdMob dismissed without earned reward',
          level: SentryLevel.info));
    }
    return result;
  }

  Future<bool> _showYandex(yandex.RewardedAd ad) async {
    _yandexAd = null; // одноразовая
    // Награду начисляем ПРЯМО В onRewarded, а не после закрытия. Раньше код
    // ждал onAdDismissed и лишь потом смотрел флаг earned (с окном 400мс на
    // запоздавший reward). На медленных устройствах Яндекс присылает onRewarded
    // уже ПОСЛЕ dismiss+окна → earned читался как false, grantAdReward не
    // вызывался, коины/счётчик не менялись (баг «посмотрел — монет нет»). Грант
    // внутри колбэка снимает гонку с таймингом закрытия полностью.
    bool earned = false;
    Future<void>? grantFuture;
    final dismissed = Completer<void>();
    void finish() {
      if (!dismissed.isCompleted) dismissed.complete();
    }

    await ad.setAdEventListener(
      eventListener: yandex.RewardedAdEventListener(
        onRewarded: (reward) {
          if (earned) return; // защита от повторного события
          earned = true;
          grantFuture = _grantAdReward();
        },
        onAdDismissed: finish,
        onAdFailedToShow: (error) {
          debugPrint('Yandex rewarded show failed: ${error.description}');
          finish();
        },
      ),
    );
    await ad.show();
    await dismissed.future;
    // onRewarded может прийти вплотную к закрытию (или сразу после) — даём ему
    // долететь, прежде чем решить, что награды не было. Окно щедрое: грант всё
    // равно идёт внутри колбэка, лишнего ожидания на успешном пути нет.
    if (!earned) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    // Если награда засчитана — дожидаемся завершения серверного начисления,
    // чтобы вызывающий получил актуальные lastServerCoins/lastRewardGranted.
    if (grantFuture != null) {
      await grantFuture;
    }
    if (!earned) {
      // Реклама показана и закрыта, но onRewarded так и не пришёл → грант не
      // вызывался, коинов нет. Это ядро жалоб «посмотрел рекламу — монет нет».
      unawaited(Sentry.captureException(
        'Yandex rewarded shown but no reward earned (onRewarded missing)',
        withScope: (s) {
          s.setExtra('reason', 'rewarded ad shown without reward callback');
          s.level = SentryLevel.warning;
        },
      ));
    }
    return earned;
  }

  /// Серверное начисление за rewarded-показ. Ни у Яндекса, ни у AdMob на
  /// PocketBase нет Google-SSV, поэтому начисляем авторитетным роутом
  /// `/api/coins/ad-reward` для ОБЕИХ сетей: Яндекс зовёт из onRewarded, AdMob —
  /// после досмотра. С дневным лимитом на сервере. Результат — в
  /// [lastServerCoins]/[lastRewardGranted]/[lastRateLimited]: вызывающий
  /// применяет точный баланс и не рисует фейк при лимите.
  Future<void> _grantAdReward() async {
    try {
      final res = await PbCoinsService().adReward();
      if (res != null) {
        _lastRewardGranted = res['ok'] == true;
        _lastRateLimited = res['rateLimited'] == true;
        final c = res['coins'];
        if (c is num) _lastServerCoins = c.toInt();
        if (_lastRateLimited) {
          // Лимит 3/сутки — это НЕ баг, поэтому breadcrumb, а не recordError.
          // Но в панели видно «дошёл до лимита» → отличаем от реального отказа.
          debugPrint('Yandex reward: daily limit reached, not granted');
          Sentry.addBreadcrumb(Breadcrumb(
              message: 'ad_reward: rate-limited (daily cap), coins=$c',
              level: SentryLevel.info));
        } else if (!_lastRewardGranted) {
          // ok=false без rateLimited — неожиданный отказ начисления.
          unawaited(Sentry.captureException(
            'grantAdReward ok=false (not rate-limited): $res',
            withScope: (s) {
              s.setExtra('reason', 'ad reward not granted (server said no)');
              s.level = SentryLevel.warning;
            },
          ));
        } else {
          Sentry.addBreadcrumb(Breadcrumb(
              message: 'ad_reward: granted +3, coins=$c',
              level: SentryLevel.info));
        }
      } else {
        // null = функция не ответила. Самая частая причина — grantAdReward
        // не задеплоена: `firebase deploy --only functions:grantAdReward`.
        // Это и есть «посмотрел рекламу — коинов нет». Фиксируем как ошибку.
        debugPrint('grantAdReward returned null '
            '(not deployed / offline?) — coins not credited');
        unawaited(Sentry.captureException(
          'grantAdReward returned null — coins NOT credited '
          '(function not deployed / offline?)',
          withScope: (s) {
            s.setExtra('reason', 'ad reward grant call returned null');
            s.level = SentryLevel.warning;
          },
        ));
      }
    } catch (e, st) {
      debugPrint('grantAdReward (Yandex) failed: $e');
      unawaited(Sentry.captureException(
        e,
        stackTrace: st,
        withScope: (s) {
          s.setExtra('reason', 'ad reward grant call threw');
          s.level = SentryLevel.warning;
        },
      ));
    }
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _ad?.dispose();
    _ad = null;
    _yandexAd = null;
    unawaited(_yandexLoader?.destroy() ?? Future.value());
    _yandexLoader = null;
  }
}
