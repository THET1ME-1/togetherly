import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Один вариант launcher-иконки приложения. Цвета совпадают с ассетами,
/// сгенерированными `tool/gen_app_icons.py` (фон = primaryLight темы, буквы
/// «TY» = тёмный акцент темы), чтобы превью в приложении было «как на столе».
class AppIconOption {
  final String id; // совпадает с alias-id в MainActivity.kt / манифесте
  final String nameRu;
  final String nameEn;
  final Color background;
  final Color letters;

  const AppIconOption({
    required this.id,
    required this.nameRu,
    required this.nameEn,
    required this.background,
    required this.letters,
  });
}

/// Смена иконки приложения через activity-alias (только Android).
///
/// На Android нет нативного «alternate icon» API: в манифесте заведены
/// `<activity-alias>` (по одному на тему), а нативный код через
/// `PackageManager.setComponentEnabledSetting` включает выбранный и гасит
/// остальные. Канал — `app_icon`, метод `setIcon`.
class AppIconService {
  AppIconService._();
  static final AppIconService instance = AppIconService._();

  static const MethodChannel _channel = MethodChannel('app_icon');
  static const String _prefKey = 'app_icon_id';
  static const String defaultId = 'pink';

  /// Тестовый набор (5 тем). Расширяется добавлением alias в манифест +
  /// ассетов в `tool/gen_app_icons.py` + записи здесь.
  static const List<AppIconOption> options = [
    AppIconOption(
      id: 'pink',
      nameRu: 'Розовая',
      nameEn: 'Pink',
      background: Color(0xFFFEEAF1),
      letters: Color(0xFF3E1F3E),
    ),
    AppIconOption(
      id: 'purple',
      nameRu: 'Фиолетовая',
      nameEn: 'Purple',
      background: Color(0xFFE6E6FA),
      letters: Color(0xFF352F44),
    ),
    AppIconOption(
      id: 'blue',
      nameRu: 'Голубая',
      nameEn: 'Blue',
      background: Color(0xFFEAF2FA),
      letters: Color(0xFF4D7099),
    ),
    AppIconOption(
      id: 'green',
      nameRu: 'Шалфейная',
      nameEn: 'Sage',
      background: Color(0xFFEBF5E6),
      letters: Color(0xFF4E7649),
    ),
    AppIconOption(
      id: 'midnight',
      nameRu: 'Полуночная',
      nameEn: 'Midnight',
      background: Color(0xFFE5E9F2),
      letters: Color(0xFF1B1F3A),
    ),
    AppIconOption(
      id: 'orange',
      nameRu: 'Персиковая',
      nameEn: 'Peach',
      background: Color(0xFFFDF3EE),
      letters: Color(0xFFCF7E5E),
    ),
    AppIconOption(
      id: 'lavender',
      nameRu: 'Лавандовая',
      nameEn: 'Lavender',
      background: Color(0xFFF5EFFB),
      letters: Color(0xFF8E6FB8),
    ),
    AppIconOption(
      id: 'cherry',
      nameRu: 'Вишнёвая',
      nameEn: 'Cherry',
      background: Color(0xFFFBEAEF),
      letters: Color(0xFF7E2A45),
    ),
    AppIconOption(
      id: 'mint',
      nameRu: 'Мятная',
      nameEn: 'Mint',
      background: Color(0xFFE6F7F0),
      letters: Color(0xFF4A9A80),
    ),
    AppIconOption(
      id: 'sunset',
      nameRu: 'Закатная',
      nameEn: 'Sunset',
      background: Color(0xFFFFEBE2),
      letters: Color(0xFFFF6F61),
    ),
    AppIconOption(
      id: 'monochrome',
      nameRu: 'Монохром',
      nameEn: 'Monochrome',
      background: Color(0xFFEFEFEF),
      letters: Color(0xFF3A3A3A),
    ),
    AppIconOption(
      id: 'forest',
      nameRu: 'Лесная',
      nameEn: 'Forest',
      background: Color(0xFFE4EFE5),
      letters: Color(0xFF284C32),
    ),
    AppIconOption(
      id: 'ocean',
      nameRu: 'Океан',
      nameEn: 'Ocean',
      background: Color(0xFFE1F1F4),
      letters: Color(0xFF1F5A6E),
    ),
  ];

  /// Поддерживается ли смена иконки на текущей платформе.
  bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Текущая выбранная иконка (из локального хранилища; дефолт — pink).
  Future<String> currentIconId() async {
    if (!isSupported) return defaultId;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKey) ?? defaultId;
  }

  /// Применяет иконку: переключает alias нативно и запоминает выбор.
  /// Возвращает true при успехе.
  Future<bool> setIcon(String id) async {
    if (!isSupported) return false;
    if (options.every((o) => o.id != id)) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setIcon', {'id': id});
      if (ok == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefKey, id);
        return true;
      }
      return false;
    } on PlatformException catch (e) {
      debugPrint('AppIconService.setIcon failed: ${e.message}');
      return false;
    }
  }
}
