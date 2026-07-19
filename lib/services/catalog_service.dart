import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/level.dart';
import '../models/mascot.dart';
import '../models/mood_entry.dart';
import '../models/mood_pack.dart';
import 'pb_data_service.dart';

/// Удалённый КАТАЛОГ контента (паки настроений + маскоты-награды за уровень).
///
/// Позволяет добавлять новые паки/эмоции/маскотов БЕЗ релиза приложения: список
/// лежит в PocketBase-коллекции `catalog_items` (публичное чтение), картинки —
/// публичные file-URL PB. При старте:
///   1. мгновенно поднимаем последний КЭШ с диска (офлайн-safe),
///   2. фоном тянем свежий каталог из PocketBase, кэшируем, обновляем UI.
///
/// Встроенные паки (classic/pink) всегда доступны как офлайн-дефолт; каталог
/// лишь ДОБАВЛЯЕТ к ним. Элементы с `min_app` выше текущей версии пропускаются
/// (старые сборки не видят то, что не умеют рендерить).
class CatalogService extends ChangeNotifier {
  CatalogService._();
  static final CatalogService _instance = CatalogService._();
  static CatalogService get instance => _instance;

  static const String _cacheKey = 'content_catalog_cache_v1';

  List<MoodPack> _remotePacks = const [];
  List<Mascot> _mascots = const [];
  bool _initialized = false;

  /// Бандл + удалённые паки (бандл первым — порядок в пикере стабилен).
  List<MoodPack> get allPacks => [...MoodPack.all, ..._remotePacks];

  /// Маскоты из удалённого каталога (рендер-онли, поверх галереи группы).
  List<Mascot> get mascots => _mascots;

  /// Пак по id среди всех (бандл+каталог); неизвестный → классический.
  MoodPack packById(String? id) {
    for (final p in allPacks) {
      if (p.id == id) return p;
    }
    return MoodPack.classic;
  }

  /// Поднять кэш с диска и (если возможно) обновить из PocketBase. Идемпотентно.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // 1) Мгновенный кэш с диска — каталог доступен сразу и офлайн.
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null) {
        _apply(jsonDecode(cached) as List, await _appVersion());
      }
    } catch (_) {}

    // 2) Свежий каталог из PocketBase — В ФОНЕ, не блокируем старт приложения.
    //    Ошибки/офлайн — тихо остаёмся на кэше/бандле.
    unawaited(refresh());
  }

  /// Подтянуть свежий каталог из PocketBase и закэшировать. Безопасно при офлайне.
  Future<void> refresh() async {
    try {
      final recs = await PbDataService.instance.loadCatalogAll();
      // RecordModel → плоская карта (как раньше строка Supabase): кастомные поля
      // в `rec.data`, первичный id — отдельно. `data` (json-поле) уже Map.
      final list = <Map<String, dynamic>>[
        for (final r in recs) {...r.data, 'id': r.id},
      ];
      _apply(list, await _appVersion());
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, jsonEncode(list));
      } catch (_) {}
    } catch (e) {
      debugPrint('CatalogService.refresh failed (using cache/bundled): $e');
    }
  }

  // ── Парсинг манифеста ───────────────────────────────────────────────────────

  void _apply(List rows, String appVersion) {
    final packs = <MoodPack>[];
    final remoteMoods = <MoodOption>[];
    final mascots = <Mascot>[];

    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = raw.cast<String, dynamic>();
      if (!_appAtLeast(appVersion, row['min_app'] as String?)) continue;

      if (row['kind'] == 'mascot') {
        final mascot = _parseMascot(row);
        if (mascot != null) mascots.add(mascot);
        continue;
      }
      if (row['kind'] != 'mood_pack') continue;

      final data = (row['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final moods = <MoodOption>[];
      for (final m in (data['moods'] as List? ?? const [])) {
        if (m is! Map) continue;
        final mo = _parseMood(m.cast<String, dynamic>());
        if (mo != null) {
          moods.add(mo);
          remoteMoods.add(mo);
        }
      }
      if (moods.isEmpty) continue;

      packs.add(MoodPack(
        id: row['id'] as String? ?? '',
        isFree: row['is_free'] as bool? ?? true,
        nameRu: row['name_ru'] as String? ?? '',
        nameEn: row['name_en'] as String? ?? '',
        moods: moods,
        tileGradient: _parseGradient(data['tileGradient']),
        unlock: _parseUnlock(row, data),
      ));
    }

    _remotePacks = List.unmodifiable(packs);
    _mascots = List.unmodifiable(mascots);
    MoodOption.registerRemoteMoods(remoteMoods);
    notifyListeners();
  }

  /// Маскот из строки каталога (kind='mascot', data={url}).
  Mascot? _parseMascot(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    final data = (row['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final url = data['url'] as String?;
    if (id == null || id.isEmpty || url == null || url.isEmpty) return null;
    return Mascot.fromCatalog(
      id: id,
      nameRu: row['name_ru'] as String? ?? id,
      nameEn: row['name_en'] as String? ?? id,
      url: url,
      unlock: _parseUnlock(row, data),
    );
  }

  /// Требование разблокировки: поле `unlock` в data, иначе по `is_free`.
  Unlock _parseUnlock(Map<String, dynamic> row, Map<String, dynamic> data) {
    final u = data['unlock'];
    if (u is Map) return Unlock.fromJson(u.cast<String, dynamic>());
    final free = row['is_free'] as bool? ?? true;
    return free ? const Unlock.free() : const Unlock.premium();
  }

  /// Одно настроение из манифеста. Для известных id цвет/метку берём из сборки,
  /// для НОВЫХ — из манифеста (нужны color/labelRu/labelEn/score).
  MoodOption? _parseMood(Map<String, dynamic> m) {
    final id = m['id'] as String?;
    final url = m['url'] as String?;
    if (id == null || id.isEmpty || url == null || url.isEmpty) return null;

    final known = MoodOption.byId(id); // встроенный канон, если есть
    return MoodOption(
      id: id,
      imagePath: url,
      label: m['labelRu'] as String? ?? known?.label ?? id,
      labelEn: m['labelEn'] as String?,
      color: _parseColor(m['color']) ?? known?.color ?? const Color(0xFF9CA3AF),
      scoreOverride: (m['score'] as num?)?.toInt(),
    );
  }

  List<Color>? _parseGradient(dynamic v) {
    if (v is! List) return null;
    final colors = <Color>[];
    for (final c in v) {
      final parsed = _parseColor(c);
      if (parsed != null) colors.add(parsed);
    }
    return colors.length >= 2 ? colors : null;
  }

  /// '#RRGGBB' или '#AARRGGBB' → Color.
  Color? _parseColor(dynamic v) {
    if (v is! String) return null;
    var hex = v.replaceAll('#', '').trim();
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    final value = int.tryParse(hex, radix: 16);
    return value == null ? null : Color(value);
  }

  // ── Версия приложения / semver-гейт ─────────────────────────────────────────

  String? _cachedVersion;
  Future<String> _appVersion() async {
    if (_cachedVersion != null) return _cachedVersion!;
    try {
      _cachedVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      _cachedVersion = '0.0.0';
    }
    return _cachedVersion!;
  }

  /// true, если текущая версия приложения ≥ [minApp] (null/мусор → допускаем).
  bool _appAtLeast(String current, String? minApp) {
    if (minApp == null || minApp.isEmpty) return true;
    final cur = _semver(current);
    final min = _semver(minApp);
    for (var i = 0; i < 3; i++) {
      if (cur[i] != min[i]) return cur[i] > min[i];
    }
    return true;
  }

  List<int> _semver(String v) {
    final parts = v.split('+').first.split('.');
    return [
      for (var i = 0; i < 3; i++)
        (i < parts.length ? int.tryParse(parts[i]) : 0) ?? 0,
    ];
  }
}
