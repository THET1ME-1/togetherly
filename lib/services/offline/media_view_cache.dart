import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Долгоживущий кэш картинок для ГАРАНТИРОВАННОГО офлайн-просмотра.
///
/// Дефолтный кэш `cached_network_image` вытесняет файлы по LRU (~200 объектов /
/// 30 дней), поэтому давно виденное фото офлайн могло показать заглушку. Этот
/// менеджер с большими лимитами практически не вытесняет (потолок задан, чтобы
/// диск не рос бесконечно). Используется в [StorageImage].
class OfflineImageCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'offlineImageCacheV1';

  static final OfflineImageCacheManager instance = OfflineImageCacheManager._();

  OfflineImageCacheManager._()
      : super(Config(
          key,
          stalePeriod: const Duration(days: 3650),
          maxNrOfCacheObjects: 5000,
        ));
}
