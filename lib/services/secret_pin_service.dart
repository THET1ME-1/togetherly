import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PIN для «секретных воспоминаний». В проекте нет secure storage, поэтому
/// храним НЕ сам PIN, а `SHA-256(соль + PIN)` + случайную соль в SharedPreferences
/// (по образцу локальных настроек RateLimiterService/UiPrefs). Этого достаточно,
/// чтобы скрыть воспоминания от случайного взгляда партнёра; PIN локален для
/// устройства (не синкается) — «секретность» на этом устройстве.
class SecretPinService {
  static const _hashKey = 'secret_pin_hash';
  static const _saltKey = 'secret_pin_salt';

  /// Установлен ли PIN на этом устройстве.
  static Future<bool> hasPin() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_hashKey) ?? '').isNotEmpty;
  }

  /// Задать/сменить PIN (генерит новую соль).
  static Future<void> setPin(String pin) async {
    final p = await SharedPreferences.getInstance();
    final salt = _genSalt();
    await p.setString(_saltKey, salt);
    await p.setString(_hashKey, _hash(pin, salt));
  }

  /// Проверить введённый PIN против сохранённого хэша.
  static Future<bool> verify(String pin) async {
    final p = await SharedPreferences.getInstance();
    final salt = p.getString(_saltKey) ?? '';
    final hash = p.getString(_hashKey) ?? '';
    if (salt.isEmpty || hash.isEmpty) return false;
    return _hash(pin, salt) == hash;
  }

  /// Сбросить PIN (напр. при отключении секретности).
  static Future<void> clearPin() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_hashKey);
    await p.remove(_saltKey);
  }

  static String _genSalt() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return base64Url.encode(bytes);
  }

  static String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt::$pin')).toString();
}
