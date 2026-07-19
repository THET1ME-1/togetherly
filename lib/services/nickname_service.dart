import 'package:shared_preferences/shared_preferences.dart';

/// Хранит локальные псевдонимы для партнёров.
/// Ключ: 'nickname_<uid>' — строка, которую видит только этот пользователь.
/// Изменения НЕ синхронизируются с Firebase.
class NicknameService {
  NicknameService._();
  static final NicknameService instance = NicknameService._();

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  String _key(String uid) => 'nickname_$uid';

  /// Возвращает псевдоним для [uid], или пустую строку если не задан.
  String get(String uid) {
    if (uid.isEmpty) return '';
    return _prefs?.getString(_key(uid)) ?? '';
  }

  /// Возвращает [nickname] если задан, иначе [fallback].
  String resolve(String uid, String fallback) {
    final nick = get(uid);
    return nick.isNotEmpty ? nick : fallback;
  }

  /// Сохраняет псевдоним. Если [nickname] пустой — удаляет.
  Future<void> set(String uid, String nickname) async {
    if (_prefs == null) await init();
    final trimmed = nickname.trim();
    if (trimmed.isEmpty) {
      await _prefs!.remove(_key(uid));
    } else {
      await _prefs!.setString(_key(uid), trimmed);
    }
  }

  /// Удаляет псевдоним.
  Future<void> clear(String uid) async {
    if (_prefs == null) await init();
    await _prefs!.remove(_key(uid));
  }
}
