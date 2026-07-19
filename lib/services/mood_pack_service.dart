import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mood_pack.dart';
import 'catalog_service.dart';

/// Хранит выбранный пользователем пак настроений (локально, как выбор языка).
///
/// Это чисто клиентский выбор «из какого набора я выбираю своё настроение» —
/// он не синхронизируется с партнёром (партнёр видит сохранённую картинку
/// настроения, а не пак). Синглтон по образцу [LocaleService].
class MoodPackService extends ChangeNotifier {
  MoodPackService._();
  static final MoodPackService _instance = MoodPackService._();
  static MoodPackService get instance => _instance;

  static const String _key = 'selected_mood_pack';

  String _packId = MoodPack.classic.id;
  bool _loaded = false;

  String get selectedPackId => _packId;
  MoodPack get selectedPack => CatalogService.instance.packById(_packId);

  /// Загрузить сохранённый выбор (идемпотентно).
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      // Не валидируем против списка жёстко: удалённый пак мог ещё не загрузиться
      // из каталога. packById() безопасно отдаёт classic, пока пак не появится.
      if (saved != null && saved.isNotEmpty) {
        _packId = saved;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setSelectedPack(String id) async {
    if (_packId == id) return;
    _loaded = true;
    _packId = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, id);
    } catch (_) {}
  }
}
