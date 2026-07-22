import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'centrifugo_service.dart';

/// Ядро клиента PocketBase — единая точка доступа к нашему self-hosted бэкенду
/// на VPS (миграция Firebase→PocketBase, Этап 6).
///
/// Никакого Firebase: данные/auth/realtime/медиа идут через этот клиент.
/// Сессия (token + запись юзера) сохраняется в SharedPreferences через
/// [AsyncAuthStore], поэтому вход переживает перезапуск процесса.
class PocketBaseService {
  PocketBaseService._();
  static final PocketBaseService instance = PocketBaseService._();
  factory PocketBaseService() => instance;

  /// Базовый URL PocketBase (HTTPS, Let's Encrypt; домен держит DuckDNS).
  /// Переопределяется под свой бэкенд: `--dart-define=PB_URL=https://...`
  /// По умолчанию — прод-инстанс автора.
  static const String baseUrl = String.fromEnvironment(
    'PB_URL',
    defaultValue: 'https://togetherly.day',
  );

  /// Ключ хранения сериализованной auth-сессии.
  static const String _authPrefsKey = 'pb_auth';

  PocketBase? _pb;
  bool _initialized = false;

  /// Клиент. До [init] обращаться нельзя.
  PocketBase get pb {
    final c = _pb;
    if (c == null) {
      throw StateError('PocketBaseService.init() ещё не вызван');
    }
    return c;
  }

  /// Поднимает клиент и восстанавливает сессию из SharedPreferences.
  /// Идемпотентно — повторные вызовы игнорируются.
  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_authPrefsKey);

    final authStore = AsyncAuthStore(
      initial: stored,
      save: (String data) async {
        final p = await SharedPreferences.getInstance();
        await p.setString(_authPrefsKey, data);
      },
      clear: () async {
        final p = await SharedPreferences.getInstance();
        await p.remove(_authPrefsKey);
      },
    );

    _pb = PocketBase(baseUrl, authStore: authStore);
    _initialized = true;
    debugPrint('PocketBaseService: init, авторизован=$isLoggedIn');
  }

  /// Есть ли валидная сессия.
  bool get isLoggedIn => _pb?.authStore.isValid ?? false;

  /// id текущего юзера = канонический идентификатор в данных (`author_uid`,
  /// `user_uid`, `members[]` ссылаются на него строкой). У мигрированных юзеров
  /// `id` = их прежний uid (через override поля id при импорте), у новых —
  /// авто-id PocketBase. null, если не вошёл.
  String? get userId {
    final id = _pb?.authStore.record?.id;
    if (id != null && id.isNotEmpty) return id;
    // «Полумёртвая» сессия: токен восстановлен и валиден (isValid=true), запросы
    // авторизуются им — загрузка медиа и правки виджета проходят, — но
    // authStore.record не десериализовался (напр. после рестарта/рефреша). Код,
    // гейтящий на userId (в первую очередь MemoryRepository.add), в этом
    // состоянии молча ронял запись: «фото ушло в виджет, но не в воспоминания»,
    // без ошибки. id зашит в payload JWT-токена (claim `id` — тем же полем PB
    // SDK сверяет запись при рефреше), поэтому достаём его оттуда как фолбэк.
    return _uidFromToken();
  }

  /// id из payload JWT-токена сессии (claim `id`), либо null. Fallback для
  /// [userId], когда authStore.record не восстановился, но токен ещё валиден.
  String? _uidFromToken() {
    final token = _pb?.authStore.token;
    if (token == null || token.isEmpty) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = jsonDecode(
        utf8.decode(base64Decode(base64.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final id = payload['id'];
      return (id is String && id.isNotEmpty) ? id : null;
    } catch (_) {
      return null;
    }
  }

  String? get userEmail => _pb?.authStore.record?.data['email'] as String?;

  /// Запись текущего юзера (профиль из коллекции users) или null.
  RecordModel? get currentUser => _pb?.authStore.record;

  /// Сбрасывает сессию (выход). Чистит и persisted-копию (через AsyncAuthStore)
  /// и рвёт WebSocket-соединение Centrifugo (иначе оно бы зациклилось на
  /// рефреше токена с 401 после очистки сессии).
  void signOut() {
    _pb?.authStore.clear();
    unawaited(CentrifugoService.instance.reset());
  }
}
