import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'config/sentry_config.dart';
import 'package:home_widget/home_widget.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:yandex_mobileads/mobile_ads.dart' as yandex;
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'models/user_data.dart';
import 'theme/app_theme.dart';
import 'theme/theme_scope.dart';
import 'services/analytics_service.dart';
import 'services/deep_link_service.dart';
import 'services/pb_push_service.dart';
import 'services/catalog_service.dart';
import 'services/live_location_service.dart';
import 'services/locale_service.dart';
import 'services/mascot_inactivity_notification_service.dart';
import 'services/mood_pack_service.dart';
import 'services/pocketbase_service.dart';
import 'services/pb_auth_service.dart';
import 'services/pb_data_service.dart';
import 'services/home_widget_service.dart';
import 'services/widget_background_refresh_service.dart';
import 'services/offline/local_store.dart';
import 'services/offline/connectivity_service.dart';
import 'services/offline/outbox_service.dart';
import 'services/offline/media_cache.dart';
import 'screens/welcome_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/force_update_screen.dart';
import 'widgets/common/m3_loading.dart';
import 'widgets/offline_sync_banner.dart';

// ATT/трекинг убран НАМЕРЕННО: приложение НЕ отслеживает пользователей
// (в App Store Connect: App Privacy → Tracking = None). Без ATT-авторизации
// iOS отдаёт обнулённый IDFA, и AdMob/Yandex показывают неперсональную рекламу.
// Так снят реджект 2.1: ATT-попап всё равно не мог показаться на устройстве
// ревьюера с выключенным системным тумблером «Allow Apps to Request to Track».

/// Запрашивает согласие GDPR (UMP), затем инициализирует AdMob/Yandex SDK.
/// MobileAds.initialize() ДОЛЖЕН вызываться ПОСЛЕ завершения consent flow,
/// иначе на EEA-устройствах SDK стартует без согласия и реклама блокируется.
Future<void> _initConsentAndAds() async {
  final params = ConsentRequestParameters(
    consentDebugSettings: kDebugMode
        ? ConsentDebugSettings(
            debugGeography: DebugGeography.debugGeographyEea,
            testIdentifiers: <String>[],
          )
        : null,
  );

  final completer = Completer<void>();

  ConsentInformation.instance.requestConsentInfoUpdate(
    params,
    () async {
      try {
        await ConsentForm.loadAndShowConsentFormIfRequired((error) {
          if (error != null) debugPrint('UMP form error: $error');
        });
      } finally {
        completer.complete();
      }
    },
    (FormError error) {
      debugPrint('UMP update error: $error');
      completer.complete();
    },
  );

  // Таймаут 5 с — не блокируем запуск если UMP завис
  await completer.future.timeout(const Duration(seconds: 5), onTimeout: () {});

  // Redmi Note 12 Pro (Alex) — для тестирования рекламы в release-сборках
  const releaseTestDeviceIds = <String>['766303ABCCDC5AE221EAA39549B48EF5'];

  try {
    await MobileAds.instance.initialize();
    final testIds = [
      if (kDebugMode) ...const <String>[],
      ...releaseTestDeviceIds,
    ];
    if (testIds.isNotEmpty) {
      MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(testDeviceIds: testIds),
      );
    }
  } catch (e) {
    debugPrint('AdMob init failed: $e');
  }

  // Яндекс — резервная сеть (водопад): если AdMob не отдаёт рекламу
  // (onAdFailedToLoad), баннер/rewarded грузятся из Яндекса. Инициализируем
  // рядом с AdMob; обе SDK живут параллельно и не конфликтуют.
  try {
    await yandex.MobileAds.initialize();
  } catch (e) {
    debugPrint('Yandex Ads init failed: $e');
  }
}

// FCM-фоновый хендлер удалён: пуши на PocketBase (PbPushService).

/// Вызывается нативным виджетом (LoveWidgetProvider.onUpdate) через
/// HomeWidgetBackgroundReceiver, когда процесс Flutter мёртв.
/// Тянет свежие данные из Firestore и обновляет SharedPreferences виджета,
/// чтобы парный виджет показывал актуальный статус/настроение без открытия приложения.
@pragma('vm:entry-point')
Future<void> _homeWidgetBackgroundCallback(Uri? uri) async {
  if (!Platform.isAndroid || uri == null) return;

  final host = uri.host.trim().toLowerCase();
  if (host.isEmpty || host != 'refresh') return;

  try {
    // PB-фон: процесс мёртв → инициализируем клиент и восстанавливаем сессию
    // из SharedPreferences. ⚠️ нужен валидный PB-токен (widget_data protected).
    await PocketBaseService().init();
    final myUid = PocketBaseService().userId ?? '';
    if (myUid.isEmpty) return;

    final groupId =
        await HomeWidget.getWidgetData<String>('love_widget_group_id') ?? '';
    final partnerUid =
        await HomeWidget.getWidgetData<String>('love_widget_partner_uid') ?? '';
    if (groupId.isEmpty) return;

    // Единый источник логики обновления парного виджета из PB (та же, что в
    // изоляте foreground-сервиса PushBackgroundService).
    await HomeWidgetService.instance
        .refreshLoveWidgetFromServer(groupId, myUid, partnerUid);
  } catch (e) {
    debugPrint('_homeWidgetBackgroundCallback failed: $e');
  }
}

/// Ошибки, прилетающие в глобальный async-обработчик из фоновых операций,
/// которые НЕ роняют приложение (выполнение продолжается, есть деградация):
///  • Firebase права/доступ: presence onDisconnect при недокаченных RTDB-правилах,
///    фоновая загрузка в Storage без прав;
///  • google_fonts: офлайн-загрузка шрифта с fonts.gstatic.com падает → текст
///    рисуется системным шрифтом, не краш.
/// Помечаем их non-fatal, чтобы не путать с настоящими падениями.
bool _isBenignBackgroundError(Object error) {
  final s = error.toString();
  return s.contains('permission-denied') ||
      s.contains('permission_denied') ||
      s.contains('firebase_storage/unauthorized') ||
      s.contains('Failed to load font') ||
      // На случай редкого варианта Rubik, не вошедшего в бандл: текст просто
      // рисуется системным шрифтом, не краш.
      s.contains('allowRuntimeFetching');
}

/// Транспортные сетевые сбои = недоступность сервера или плохая сеть юзера
/// (часто из-за блокировок в РФ), НЕ баги приложения. Такие события не шлём в
/// Bugsink (`beforeSend → null`), чтобы реальные краши не тонули в шуме.
bool _isNetworkNoise(Object error) {
  final s = error.toString();
  if (s.contains('SocketException') ||
      s.contains('HandshakeException') ||
      s.contains('Connection closed') ||
      s.contains('Connection reset') ||
      s.contains('Connection refused') ||
      s.contains('Connection failed') ||
      s.contains('Connection terminated') ||
      s.contains('Connection abort') || // вкл. "Software caused connection abort"
      s.contains('Network is unreachable') ||
      s.contains('Connection timed out') ||
      s.contains('Operation timed out')) {
    return true;
  }
  // PocketBase ClientException транспортного уровня: запрос отменён / сервер не
  // ответил. 4xx/5xx (реальные ответы сервера) НЕ трогаем — они информативны.
  if (s.contains('ClientException') &&
      (s.contains('isAbort: true') || s.contains('statusCode: 0'))) {
    return true;
  }
  // PocketBase realtime (SSE) постоянно переподключается на мобильной сети:
  // /api/realtime отдаёт 400 при обрыве/реконнекте — это churn соединения, а не
  // баг. Именно он был issue #3 (1340 fatal-событий, топ по объёму в Bugsink).
  // Глушим все ClientException этого эндпоинта независимо от статуса.
  if (s.contains('ClientException') && s.contains('/api/realtime')) {
    return true;
  }
  return false;
}

/// Android 12+ (mAllowStartForeground) запрещает старт foreground-сервиса из
/// фона. Прямой путь старта уже обёрнут в try/catch, но плагин
/// flutter_foreground_task доставляет отказ ещё и асинхронным событием
/// EventChannel → оно всплывает как необработанная ошибка мимо catch. Это
/// ограничение ОС, а не баг приложения — не шлём в Bugsink (был issue #35).
bool _isForegroundServiceRestriction(Object error) {
  final s = error.toString();
  return s.contains('startForeground() not allowed') ||
      s.contains('ForegroundServiceStartNotAllowed') ||
      s.contains('mAllowStartForeground');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // iOS: home_widget работает поверх общего App Group контейнера. Любой вызов
  // saveWidgetData/updateWidget/clearWidget ДО setAppGroupId падает с
  // PlatformException(-7, «AppGroupId not set. Call setAppGroupId first»).
  // Группа должна совпадать с App Group из Runner.entitlements и
  // TogetherlyWidget.entitlements (= group.com.togetherly.love), иначе виджет и
  // приложение пишут в разные контейнеры. На Android метод — no-op, поэтому
  // выставляем безусловно и максимально рано, до первой синхронизации виджетов.
  await HomeWidget.setAppGroupId('group.com.togetherly.love');

  // Принудительно используем системный Android Photo Picker (ACTION_PICK_IMAGES)
  // вместо legacy ACTION_GET_CONTENT, который на MIUI открывает файловый
  // проводник (DocumentsUI) вместо галереи.
  final imagePickerImpl = ImagePickerPlatform.instance;
  if (imagePickerImpl is ImagePickerAndroid) {
    imagePickerImpl.useAndroidPhotoPicker = true;
  }

  // Шрифт Rubik зашит в сборку (assets google_fonts/) — запрещаем загрузку с
  // fonts.gstatic.com во время работы. Это убирает сетевую зависимость, мерцание
  // шрифта при старте и офлайн-ошибки «Failed to load font».
  GoogleFonts.config.allowRuntimeFetching = false;

  // PocketBase — поднимаем клиент и восстанавливаем сессию из SharedPreferences
  // (миграция Firebase→PB). Сессия переживает перезапуск процесса. signInSilently
  // лишь освежает токен, если он валиден. Firebase пока инициализируется рядом:
  // остальные слои (данные/realtime/медиа/пуш) ещё на нём — его инициализацию,
  // Crashlytics, Messaging и Supabase убираем ПОСЛЕДНИМ шагом cutover'а, когда
  // все слои переведены (см. pocketbase/CUTOVER.md §1, §7).
  await PocketBaseService().init();
  // Офлайн-фундамент: локальный кэш (sembast) + детектор связи. Открываем ДО
  // первых watch*, чтобы экраны читали из кэша мгновенно и работали офлайн.
  // fail-open: при ошибке открытия кэша приложение работает как раньше (онлайн).
  await LocalStore.instance.init();
  unawaited(ConnectivityService.instance.init());
  // signInSilently освежает токен СЕТЕВЫМ запросом (authRefresh) — НЕ блокируем
  // им холодный старт: токен уже восстановлен из SharedPreferences (init выше),
  // запросы пойдут с ним сразу, а refresh идёт в фоне. Раньше старт висел на
  // authRefresh, ожидая медленный/перегруженный сервер (на слабой связи — до
  // таймаута), и UI не показывался даже при наличии локального кэша. userId ниже
  // берётся из persisted-сессии, поэтому в готовности signInSilently не нуждается.
  unawaited(PbAuthService().signInSilently());
  // Привязываем кэш к владельцу: если на устройстве сменился аккаунт — кэш
  // полностью чистится (защита от утечки данных между пользователями).
  await LocalStore.instance.ensureOwner(PocketBaseService().userId);
  // Очередь офлайн-записи: дослать на сервер изменения, сделанные офлайн в
  // прошлой сессии (если уже есть сеть), и реагировать на её появление.
  unawaited(OutboxService.instance.init());
  // Отложенные медиа (созданные офлайн) — дослать в PB при появлении сети.
  unawaited(MediaCache.instance.init());

  // Крашрепортинг — self-hosted Bugsink (Sentry-совместимый, наш VPS), замена
  // Firebase Crashlytics. Перехватываем:
  //  • FlutterError.onError — синхронные ошибки фреймворка (build/layout/paint);
  //  • PlatformDispatcher.onError — необработанные асинхронные ошибки (Future/
  //    Stream), которые иначе молча гасились.
  // В debug DSN пустой → SDK no-op (не шлём тестовые краши на прод-бэкенд).
  await SentryFlutter.init((options) {
    options.dsn = kDebugMode ? '' : SentryConfig.dsn;
    options.environment = kDebugMode ? 'debug' : 'production';
    options.tracesSampleRate = 0.0; // только краши, без performance-трейсинга
    options.attachStacktrace = true;
    // Не шлём транспортный сетевой шум (обрывы сокета, недоступность сервера,
    // плохая сеть пользователя — особенно при блокировках в РФ). Это не баги
    // приложения, а они тонной забивали панель и топили реальные краши.
    options.beforeSend = (event, hint) {
      final t = event.throwable;
      if (t != null &&
          (_isNetworkNoise(t) || _isForegroundServiceRestriction(t))) {
        return null; // выбросить событие
      }
      return event;
    };
  });
  Sentry.configureScope(
    (scope) => scope.setUser(SentryUser(id: PocketBaseService().userId ?? '')),
  );
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    unawaited(Sentry.captureException(details.exception, stackTrace: details.stack));
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    // Возвращаем true → приложение НЕ падает, выполнение продолжается. Часть
    // ошибок здесь — из фоновых операций (presence, фоновая загрузка медиа) и
    // крашами не являются: помечаем их level=warning, остальное — fatal, чтобы
    // не завышать счётчик падений.
    final fatal = !_isBenignBackgroundError(error);
    unawaited(Sentry.captureException(
      error,
      stackTrace: stack,
      withScope: (scope) =>
          scope.level = fatal ? SentryLevel.fatal : SentryLevel.warning,
    ));
    return true;
  };

  // Supabase убран (миграция на PocketBase). Прежний слой Supabase был
  // переходным экспериментом дуал-райта; его инициализация удалена. Все вызовы
  // SupabaseService защищены `isReady` и становятся no-op без init, так что
  // FirebaseService продолжает работать на Firebase до полного перехода на PB.
  // Force-update порог теперь читается из PocketBase (`app_config.min_build`).

  // Google UMP + AdMob — consent должен быть получен ДО инициализации SDK
  if (Platform.isAndroid || Platform.isIOS) {
    await _initConsentAndAds();
  }

  // При первом запуске после установки — принудительно выходим из сессии
  // и очищаем SharedPreferences. На iOS Firebase Auth хранит токен в Keychain,
  // который переживает удаление приложения — поэтому signOut() вызывается
  // безусловно, без проверки isLoggedIn.
  final prefs = await SharedPreferences.getInstance();
  const kInstallKey = 'app_installed_v1';
  if (!prefs.containsKey(kInstallKey)) {
    try {
      PocketBaseService().signOut();
    } catch (_) {}
    await prefs.clear();
    await prefs.setBool(kInstallKey, true);
  }

  // Debug → Release переход: при апгрейде SharedPreferences НЕ очищаются,
  // поэтому kInstallKey уже есть и выхода из аккаунта не происходит.
  // Если предыдущая сессия была debug, а текущая release — делаем signOut,
  // чтобы стейт debug-тестирования не засорял production-окружение.
  const kLastBuildMode = 'last_build_mode_v1';
  final lastBuildMode = prefs.getString(kLastBuildMode) ?? '';
  const currentBuildMode = kDebugMode ? 'debug' : 'release';
  if (lastBuildMode == 'debug' && currentBuildMode == 'release') {
    try {
      if (PocketBaseService().isLoggedIn) {
        PocketBaseService().signOut();
      }
    } catch (_) {}
  }
  await prefs.setString(kLastBuildMode, currentBuildMode);

  // На Samsung One UI / aggressive battery saver путь
  // HomeWidgetBackgroundReceiver -> JobIntentService нестабилен
  // (особенно в home_widget 0.7.x). Для наших Android-виджетов достаточно
  // launch intent + явных updateWidget(), поэтому не регистрируем
  // background interactivity callback и не провоцируем enqueueWork crash.
  if (!Platform.isAndroid) {
    HomeWidget.registerInteractivityCallback(_homeWidgetBackgroundCallback);
  } else {
    // Android: живучий фолбэк обновления виджетов через WorkManager. Foreground-
    // сервис (PushBackgroundService) даёт мгновенность, но его душат OEM-киллеры
    // (Xiaomi/MIUI, Samsung) даже с whitelist батареи. Периодическая задача
    // переживает убийство процесса и Doze → виджет не застревает навсегда.
    // Инициализируем диспетчер здесь; само расписание ставит home_screen при
    // активной паре (там известен контекст). Не блокируем старт.
    unawaited(WidgetBackgroundRefreshService.instance.init());
  }

  // Аналитика отключена (firebase_analytics убран при уходе с Firebase) —
  // AnalyticsService теперь no-op shell. Привязку userId оставляем как заглушку
  // на случай будущей серверной аналитики на PocketBase.
  unawaited(AnalyticsService.instance.setUserId(PocketBaseService().userId));

  // Deep links — инициализация
  DeepLinkService().init();

  // Локальное напоминание, если пользователь долго не открывает приложение
  await MascotInactivityNotificationService.instance.init();
  await MascotInactivityNotificationService.instance.markAppOpened();

  // Locale — инициализация (определяет язык по региону или сохранённым настройкам)
  await LocaleService.instance.init();

  // Восстанавливаем флаг шеринга геопозиции (карта «Где мы»). Сам трекинг
  // стартует из home_screen после привязки к группе (resumeIfEnabled).
  await LiveLocationService.instance.init();

  // Выбранный пак настроений (локальный выбор, как язык) — грузим заранее,
  // чтобы пикер сразу открывался на нужном наборе без мигания.
  await MoodPackService.instance.load();

  // Удалённый каталог контента (паки настроений из Supabase) — поднимаем кэш с
  // диска мгновенно, свежий список тянем фоном. Новые паки/эмоции приезжают без
  // обновления приложения. Офлайн/без credentials — остаются встроенные паки.
  await CatalogService.instance.init();

  // Synchronise Flutter's window with MainActivity's setDecorFitsSystemWindows(false).
  // Without this call Flutter and Android disagree about where gesture exclusion
  // zones are, causing system swipe gestures (back, home) to be intercepted by
  // Flutter's own gesture arena and bounce the user back into the app.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
      // false = don't let Android paint a contrast scrim over the nav bar;
      // that scrim overlaps the gesture zone and can interfere with swipe detection.
      systemNavigationBarContrastEnforced: false,
    ),
  );
  runApp(const LoveApp());
}

class LoveApp extends StatefulWidget {
  const LoveApp({super.key});

  @override
  State<LoveApp> createState() => _LoveAppState();
}

class _LoveAppState extends State<LoveApp> {
  final UserData _userData = UserData();
  bool _loading = true;
  // Установленная сборка ниже минимально поддерживаемой (PocketBase
  // app_config.min_build) → блокирующий экран обновления. fail-open: при любой
  // ошибке/без конфига остаётся false и никого не блокирует.
  bool _forceUpdate = false;
  AppLifecycleListener? _lifecycleListener;

  // Тема пересобирается при смене темы приложения (акцент берётся из активной
  // AppTheme). Кэшируем по акценту, чтобы не пересоздавать на каждый
  // notifyListeners() UserData (монеты, присутствие и т.п.).
  int? _lastThemeIndex;
  ThemeData? _lastTheme;

  ThemeData _themeFor(AppTheme appTheme) {
    if (_lastTheme == null || _lastThemeIndex != appTheme.index) {
      _lastThemeIndex = appTheme.index;
      _lastTheme = _buildTheme(appTheme);
    }
    return _lastTheme!;
  }

  /// Единый стиль для всех меню (диалоги, bottom-sheet, snackbar, popup-меню).
  /// Цвета — от акцента активной темы, форма/скругления — из общих токенов.
  static ThemeData _buildTheme(AppTheme appTheme) {
    final accent = appTheme.primary;
    final brightness = appTheme.brightness;
    final isDark = brightness == Brightness.dark;

    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(primary: accent);

    // Поверхности меню (диалоги/шиты/попапы) и цвета текста — из токенов активной
    // темы. На светлых темах: cardSurface=#FFFFFF, textPrimary/Secondary ≈ прежним
    // тёмным — визуально идентично. На тёмной: тёмная поверхность + светлый текст.
    final menuSurface = appTheme.cardSurface;
    final titleColor = appTheme.textPrimary;
    final bodyColor = appTheme.textSecondary;
    final scaffoldBg =
        isDark ? appTheme.bgGradient.last : const Color(0xFFF7F3F0);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Базовый textTheme нужной яркости → дефолтный цвет текста Material-виджетов
      // (не переопределённый явно) читаем на тёмном фоне.
      textTheme: GoogleFonts.rubikTextTheme(
        isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
      ),
      scaffoldBackgroundColor: scaffoldBg,

      // ── Диалоги ────────────────────────────────────────────────────────
      dialogTheme: DialogThemeData(
        backgroundColor: menuSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: GoogleFonts.rubik(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: titleColor,
        ),
        contentTextStyle: GoogleFonts.rubik(
          fontSize: 15,
          height: 1.4,
          color: bodyColor,
        ),
      ),

      // ── Bottom-sheet ───────────────────────────────────────────────────
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: menuSurface,
        modalBackgroundColor: menuSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        modalElevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),

      // ── SnackBar ───────────────────────────────────────────────────────
      // Тёмная нейтральная подложка — единая и читаемая на всех 20 темах;
      // акцент темы выводим в цвете кнопки действия.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2E2A2C),
        contentTextStyle: GoogleFonts.rubik(
          color: Colors.white,
          fontSize: 14,
        ),
        actionTextColor: scheme.inversePrimary,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),

      // ── Popup-меню ─────────────────────────────────────────────────────
      popupMenuTheme: PopupMenuThemeData(
        color: menuSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _init();
    // Отслеживаем жизненный цикл приложения для обновления статуса присутствия
    _lifecycleListener = AppLifecycleListener(
      onResume: () {
        // Онлайн-презенс ведёт PresenceService (lifecycle-aware).
        MascotInactivityNotificationService.instance.markAppOpened();
      },
      onPause: () {
        MascotInactivityNotificationService.instance
            .scheduleReminderAfterOneDay();
      },
      onDetach: () {
        MascotInactivityNotificationService.instance
            .scheduleReminderAfterOneDay();
      },
      onHide: () {
        MascotInactivityNotificationService.instance
            .scheduleReminderAfterOneDay();
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      // Force-update kill-switch: если сборка ниже min_build из PocketBase
      // (`app_config`) — дальше покажем блокирующий ForceUpdateScreen. Только
      // Android (на iOS обновления гонит App Store). fail-open: minBuild=0 ⇒ не
      // блокируем.
      if (Platform.isAndroid) {
        try {
          // Таймаут: медленный/перегруженный PB НЕ должен морозить сплэш (иначе
          // пользователи перезапускают приложение и добивают сервер). fail-open ⇒ 0.
          final minBuild = await PbDataService()
              .fetchMinSupportedBuild()
              .timeout(const Duration(seconds: 3), onTimeout: () => 0);
          if (minBuild > 0) {
            final info = await PackageInfo.fromPlatform();
            final current = int.tryParse(info.buildNumber) ?? 0;
            _forceUpdate = current < minBuild;
          }
        } catch (_) {
          // Любая ошибка чтения конфига — не блокируем пользователя.
        }
      }

      // Запоминаем, была ли сессия активна ДО loadFromPrefs: внутри него
      // серверная синхронизация коинов/тем выполняется только при уже
      // активной сессии (isLoggedIn). При тихом входе сессия поднимается
      // ниже — поэтому при wasLoggedIn == false синк надо повторить вручную.
      final wasLoggedIn = PocketBaseService().isLoggedIn;

      // Загружаем локальный профиль из SharedPreferences.
      await _userData.loadFromPrefs();

      // Тихий вход в PocketBase уже выполнен в main() до runApp
      // (PbAuthService().signInSilently). Firebase-сессия на cutover не нужна.

      // Сессию подняли только что (loadFromPrefs синк пропустил, т.к. на тот
      // момент мы не были залогинены) → подтягиваем авторитетный баланс/темы
      // с сервера. Без этого весь сеанс показывались бы устаревшие локальные
      // значения, а серверные начисления (реклама, ежедневный вход, покупки)
      // молча применялись бы поверх неактуального состояния — отсюда симптомы
      // «монеты пропадают/возвращаются, награды и покупки не сохраняются».
      if (!wasLoggedIn &&
          _userData.isRegistered &&
          PocketBaseService().isLoggedIn) {
        await _userData.syncFromServer();
      }

      // Онлайн-презенс ведёт PresenceService (стартует на home-экране).

      // Выдаём иконки-награды спонсорам и помощникам.
      // grantSpecialBadge только ДОБАВЛЯЕТ иконку в доступные и закрепляет её
      // лишь если у пользователя ещё нет выбранной иконки — поэтому свободный
      // выбор иконки пользователем больше не перезатирается при каждом запуске.
      const sponsorEmails = {
        'badzoff@gmail.com',
        'alena.petukhova1@gmail.com',
        'romanhilp22@gmail.com',
        'nakotumari@gmail.com',
        'lrt56k@mail.ru',
      };
      const helperEmails = {'ashatilov2008@gmail.com'};
      // Рыбка — награда для любителей рыбалки. Отдельная категория, поэтому
      // выдаётся независимо (не через else if): её можно совмещать со Sponsor/Helper.
      const fishEmails = {
        'vazzxxcc123@gmail.com',
        'glp010409@gmail.com',
        'milkalove12let@gmail.com',
      };
      if (sponsorEmails.contains(_userData.email)) {
        final granted = await _userData.grantSpecialBadge('Sponsor');
        if (granted) {
          await PbPushService().showLocal(
            id: 8801,
            title: '🎉 Вам вручён значок «Спонсор»!',
            body:
                'Спасибо за поддержку — теперь рядом с вашим именем '
                'красуется особый бейдж 💖',
          );
        }
      } else if (helperEmails.contains(_userData.email)) {
        final granted = await _userData.grantSpecialBadge('Helper');
        if (granted) {
          await PbPushService().showLocal(
            id: 8802,
            title: '🎉 Вам вручён значок «Помощник»!',
            body: 'Спасибо за помощь проекту — особый бейдж теперь ваш 💖',
          );
        }
      }
      if (fishEmails.contains(_userData.email)) {
        final granted = await _userData.grantSpecialBadge('Fish');
        if (granted) {
          await PbPushService().showLocal(
            id: 8803,
            title: '🎣 Вам вручён значок «Рыбка»!',
            body: 'Особый бейдж для любителей рыбалки теперь ваш 💖',
          );
        }
      }
    } catch (_) {
      // Даже при ошибке убираем спиннер
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // Слушаем язык И профиль: смена темы (в _userData) пересобирает ThemeData,
      // поэтому единый стиль меню сразу подхватывает новый акцент.
      listenable: Listenable.merge([LocaleService.instance, _userData]),
      builder: (context, _) => MaterialApp(
        title: 'Togetherly',
        debugShowCheckedModeBanner: false,
        theme: _themeFor(_userData.theme),
        navigatorObservers: [AnalyticsService.instance.observer],
        // Глобальная плашка «офлайн / ожидает синхронизации» поверх любого экрана.
        builder: (context, child) => ThemeScope(
          theme: _userData.theme,
          child: OfflineSyncBanner(child: child ?? const SizedBox.shrink()),
        ),
        home: _loading
            ? const Scaffold(body: M3PageLoading(color: Color(0xFFFF7E8B)))
            : _buildInitialScreen(),
      ),
    );
  }

  Widget _buildInitialScreen() {
    // 0. Обязательное обновление — блокирующий экран поверх всего.
    if (_forceUpdate) {
      return const ForceUpdateScreen();
    }
    // 1. Первый запуск — показываем welcome
    if (!_userData.hasSeenWelcome) {
      return WelcomeScreen(userData: _userData);
    }
    // 2. Профиль есть локально.
    if (_userData.isRegistered) {
      // PB-сессия восстановлена в main()/_init() через signInSilently().
      // Если она НЕвалидна (токен протух за 5 дней, потерян, или не долетел до
      // клиента при OAuth-входе) — Home показывать НЕЛЬЗЯ: он будет молча
      // сломан (groups GET → 404 по viewRule, coins → 401, таймер 00:00, синка
      // с партнёром нет — всё уходит с пустым auth-токеном). Тихого
      // восстановления нет (OAuth требует участия пользователя), поэтому мягко
      // ведём на перелогин. LoginScreen.register(isReturningUser: true) НЕ
      // стирает локальный профиль/группу/таймеры — после входа возвращает на
      // Home уже с валидной сессией, и синк сразу оживает.
      //
      // Офлайн не страдает: isLoggedIn = локальная проверка exp JWT, поэтому при
      // живом (непротухшем) токене без сети остаёмся на Home; на перелогин ведём
      // только когда токен реально мёртв и Home всё равно работать не будет.
      if (!PocketBaseService().isLoggedIn) {
        return LoginScreen(userData: _userData);
      }
      return HomeScreen(userData: _userData);
    }
    // 3. Профиль не заполнен — на экран входа
    return WelcomeScreen(userData: _userData);
  }
}
