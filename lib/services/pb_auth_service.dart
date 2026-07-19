import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'pocketbase_service.dart';

/// Аутентификация через PocketBase (миграция Firebase→PB, Этап 6, слой Auth).
///
/// Заменяет Firebase Auth. Поддерживает:
///  • email/пароль (регистрация + вход) — работает сразу;
///  • Google OAuth2 (web-flow PB) — требует настройки провайдера `google` в
///    панели PocketBase (Client ID/Secret + redirect `…/api/oauth2-redirect`).
///
/// Идентичность в данных завязана на `users.id`: `author_uid`/`user_uid`/
/// `members[]` хранят его строкой. У мигрированных юзеров `id` = их прежний uid
/// (проставляется через override поля id при импорте, Этап 5), у НОВЫХ — обычный
/// авто-id PocketBase. Отдельного «uid»-поля нет — id и есть ключ.
class PbAuthService {
  PbAuthService._();
  static final PbAuthService instance = PbAuthService._();
  factory PbAuthService() => instance;

  final PocketBaseService _svc = PocketBaseService();
  PocketBase get _pb => _svc.pb;

  /// Коллекция аккаунтов.
  static const String _usersCol = 'users';

  /// «Мой uid» для слоя данных = `users.id`.
  String? get currentUid => _svc.userId;

  bool get isLoggedIn => _svc.isLoggedIn;

  /// Регистрация по email/паролю. Создаёт запись в `users`, входит, проставляет
  /// `firebase_uid`. Возвращает запись профиля или null.
  Future<RecordModel?> signUpWithEmail({
    required String email,
    required String password,
    required String displayName,
  }) async {
    // Таймаут на сетевые вызовы: на iOS наблюдалась «бесконечная загрузка» —
    // если запрос повисал без таймаута, спиннер регистрации крутился вечно.
    // По таймауту бросаем → экран входа покажет ошибку (а не вечный спиннер).
    const netTimeout = Duration(seconds: 20);
    try {
      await _pb.collection(_usersCol).create(body: {
        'email': email,
        'password': password,
        'passwordConfirm': password,
        'name': displayName,
        'display_name': displayName,
        'emailVisibility': true,
      }).timeout(netTimeout);
      // Сразу входим (create не авторизует).
      await _pb
          .collection(_usersCol)
          .authWithPassword(email, password)
          .timeout(netTimeout);
      await _ensureProfile(displayName: displayName);
      return _svc.currentUser;
    } on ClientException catch (e) {
      // Если пользователь уже создан (create прошёл), но authWithPassword
      // упал — выходим, чтобы не оставаться в частичном state.
      if (e.statusCode == 400 || e.statusCode == 403) {
        try { _svc.signOut(); } catch (_) {}
      }
      debugPrint('PbAuth.signUpWithEmail failed: $e');
      rethrow;
    } catch (e, st) {
      debugPrint('PbAuth.signUpWithEmail failed: $e');
      debugPrintStack(stackTrace: st);
      unawaited(Sentry.captureException(e, stackTrace: st, withScope: (s) {
        s.setExtra('reason', 'signUpWithEmail failed');
      }));
      rethrow;
    }
  }

  /// Вход по email/паролю.
  Future<RecordModel?> signInWithEmail({
    required String email,
    required String password,
  }) async {
    // Таймаут: на iOS «бесконечная загрузка» при повисшем без таймаута запросе.
    const netTimeout = Duration(seconds: 20);
    try {
      await _pb
          .collection(_usersCol)
          .authWithPassword(email, password)
          .timeout(netTimeout);
      await _ensureProfile();
      return _svc.currentUser;
    } catch (e, st) {
      final cred = e is ClientException &&
          (e.statusCode == 400 || e.statusCode == 403);
      // Мигрированный из Firebase юзер: scrypt-хеш в PB не переносится, поэтому
      // первый вход паролем падает (cred-ошибка). «Мост» просит сервер проверить
      // пароль в Firebase Auth и, если верный, перенести его в PB → повторяем
      // вход. Ноль писем/сброса для основной массы юзеров (см. migrate_bridge).
      if (cred && await _tryFirebaseBridge(email, password)) {
        await _pb
            .collection(_usersCol)
            .authWithPassword(email, password)
            .timeout(netTimeout);
        await _ensureProfile();
        return _svc.currentUser;
      }
      debugPrint('PbAuth.signInWithEmail failed: $e');
      // Неверный пароль/почта (400/403) — пользовательская ошибка, не баг:
      // не шумим в Bugsink. Остальное (5xx, сеть, неожиданное) — репортим.
      if (!cred) {
        unawaited(Sentry.captureException(e, stackTrace: st, withScope: (s) {
          s.setExtra('reason', 'signInWithEmail failed');
        }));
      }
      rethrow;
    }
  }

  /// «Мост» миграции паролей Firebase→PB: при первом входе мигрированного юзера
  /// (в PB ещё нет пароля) сервер (pb_hook `/api/migrate/verify-password`)
  /// проверяет email+пароль в Firebase Auth и при успехе записывает пароль в
  /// PB-запись. true → пароль перенесён, можно повторить authWithPassword.
  /// Никаких писем/сброса. См. pocketbase/pb_hooks/migrate_bridge.pb.js.
  Future<bool> _tryFirebaseBridge(String email, String password) async {
    try {
      final res = await _pb.send(
        '/api/migrate/verify-password',
        method: 'POST',
        body: {'email': email, 'password': password},
      ).timeout(const Duration(seconds: 15));
      return res is Map && res['ok'] == true;
    } catch (e) {
      debugPrint('PbAuth._tryFirebaseBridge failed: $e');
      return false;
    }
  }

  /// Универсальный OAuth2-вход (web-flow PocketBase): открывает страницу
  /// провайдера в in-app браузере, PB ловит редирект и возвращает сессию по
  /// realtime. [provider] — ключ провайдера в панели PB: `google` / `apple` /
  /// `yandex` / `vk` / `facebook`. Требует настроенного провайдера (Client
  /// ID/Secret + redirect `<host>/api/oauth2-redirect`).
  Future<RecordModel?> signInWithOAuth2(String provider) async {
    try {
      final auth = await _pb.collection(_usersCol).authWithOAuth2(
        provider,
        (url) async {
          // In-app браузер держит приложение на переднем плане → realtime-
          // websocket OAuth-флоу PB выживает и сессия возвращается в приложение
          // (externalApplication уводил Flutter в фон → Completer висел).
          await launchUrl(url, mode: LaunchMode.inAppBrowserView);
        },
      );
      // OAuth завершён — закрыть in-app вьюху (iOS: SFSafariViewController;
      // Android Custom Tabs: no-op, фокус и так возвращается).
      try {
        await closeInAppWebView();
      } catch (_) {}
      // Профиль из OAuth-меты (имя/аватар), если в записи ещё пусто.
      final meta = auth.meta;
      await _ensureProfile(
        displayName: meta['name']?.toString(),
        avatarUrl: meta['avatarUrl']?.toString() ?? meta['avatarURL']?.toString(),
      );
      return _svc.currentUser;
    } catch (e, st) {
      debugPrint('PbAuth.signInWithOAuth2($provider) failed: $e');
      debugPrintStack(stackTrace: st);
      unawaited(Sentry.captureException(e, stackTrace: st, withScope: (s) {
        s.setExtra('reason', 'signInWithOAuth2($provider) failed');
        s.level = SentryLevel.warning; // часть — отмена пользователем, не баг
      }));
      rethrow;
    }
  }

  /// Вход через Google. Требует настроенного провайдера `google` в панели PB.
  Future<RecordModel?> signInWithGoogle() => signInWithOAuth2('google');

  /// Вход через Apple. Требует провайдера `apple` в панели PB (Services ID +
  /// ключ; секрет авто-обновляется кроном на VPS — см. pocketbase/apple_secret.py).
  Future<RecordModel?> signInWithApple() => signInWithOAuth2('apple');

  /// Письмо для сброса пароля (email-провайдер PB).
  Future<void> sendPasswordReset(String email) async {
    try {
      await _pb.collection(_usersCol).requestPasswordReset(email);
    } catch (e) {
      debugPrint('PbAuth.sendPasswordReset failed: $e');
      rethrow;
    }
  }

  /// Профиль текущего юзера в формате camelCase — совместимо с прежним
  /// `FirebaseService.loadUserProfile` (чтобы экраны входа почти не менялись).
  /// null, если сессии нет. gender может быть null (новый OAuth-юзер до setup).
  Map<String, dynamic>? currentProfile() {
    final rec = _svc.currentUser;
    if (rec == null) return null;
    final d = rec.data;
    String s(dynamic v) => v is String ? v : '';
    final name =
        s(d['display_name']).isNotEmpty ? s(d['display_name']) : s(d['name']);
    return {
      'displayName': name,
      'email': s(d['email']).isNotEmpty ? s(d['email']) : (_svc.userEmail ?? ''),
      'gender': d['gender'],
      'avatarUrl': s(d['avatar_url']),
    };
  }

  /// «Тихий вход» — сессия уже персистится в authStore (SharedPreferences).
  /// Если валидна, освежаем токен; иначе возвращаем null.
  Future<RecordModel?> signInSilently() async {
    if (!_svc.isLoggedIn) return null;
    try {
      // Таймаут: на перегруженном/медленном сервере authRefresh мог висеть очень
      // долго. По таймауту бросаем — это НЕ 401/403, значит ниже трактуется как
      // транзиент: валидная сессия сохраняется, запросы продолжают слать токен.
      await _pb
          .collection(_usersCol)
          .authRefresh()
          .timeout(const Duration(seconds: 8));
    } catch (e, st) {
      // КЛЮЧЕВОЕ: выходим (рвём persisted-сессию) ТОЛЬКО при реальной ошибке
      // авторизации — токен отозван/протух/невалиден (401/403). Транзиентные
      // сбои (нет сети, таймаут, DNS, 5xx, captive-portal на старте) НЕ должны
      // уничтожать ещё валидную сессию: иначе один сетевой «чих» при запуске
      // молча разлогинивает, и приложение каждый раз стартует БЕЗ токена —
      // groups GET → 404 (правило viewRule), coins → 401, таймер 0, синка нет —
      // до ручного перелогина. Это и есть «всё сбросилось». При транзиентном
      // сбое держим текущий токен: он всё ещё валиден, запросы продолжат его
      // слать и заработают, как только вернётся связь.
      final isAuthError = e is ClientException &&
          (e.statusCode == 401 || e.statusCode == 403);
      debugPrint(
          'PbAuth.authRefresh failed (authError=$isAuthError): $e');
      if (isAuthError) {
        unawaited(Sentry.captureException(e, stackTrace: st, withScope: (s) {
          s.setExtra('reason', 'authRefresh 401/403 → sign-out');
          s.level = SentryLevel.warning;
        }));
        _svc.signOut();
        return null;
      }
      // Транзиент — сессию сохраняем как есть.
      return _svc.isLoggedIn ? _svc.currentUser : null;
    }
    return _svc.isLoggedIn ? _svc.currentUser : null;
  }

  void signOut() => _svc.signOut();

  /// Дозаполняет имя/аватар в профиле, если там пусто (id юзер не трогает —
  /// им управляет PocketBase). Патчит только недостающее.
  Future<void> _ensureProfile({String? displayName, String? avatarUrl}) async {
    final rec = _svc.currentUser;
    if (rec == null) return;
    final patch = <String, dynamic>{};

    final curName = rec.data['display_name'];
    if ((curName is! String || curName.isEmpty) &&
        displayName != null &&
        displayName.isNotEmpty) {
      patch['display_name'] = displayName;
    }
    final curAvatar = rec.data['avatar_url'];
    if ((curAvatar is! String || curAvatar.isEmpty) &&
        avatarUrl != null &&
        avatarUrl.isNotEmpty) {
      patch['avatar_url'] = avatarUrl;
    }
    if (patch.isEmpty) return;
    try {
      final updated = await _pb.collection(_usersCol).update(rec.id, body: patch);
      // AUTH-8: update() возвращает свежую запись, но НЕ трогает authStore.record,
      // поэтому _svc.currentUser/currentProfile() продолжали отдавать старые
      // имя/аватар до следующего authRefresh. Кладём обновлённую запись в стор с
      // тем же токеном — профиль становится актуальным сразу.
      _pb.authStore.save(_pb.authStore.token, updated);
    } catch (e) {
      // AUTH-3: глотание здесь НАМЕРЕННОЕ — дозаполнение имени/аватара это
      // best-effort обогащение, и сбой патча (напр. сетевой) не должен ронять
      // успешный вход. Профиль до-патчится при следующем входе (_ensureProfile
      // вызывается каждый раз). Ошибка видна в debug-логе.
      debugPrint('PbAuth._ensureProfile patch failed (best-effort, ignored): $e');
    }
  }
}
