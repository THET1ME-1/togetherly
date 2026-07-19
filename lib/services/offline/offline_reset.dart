import 'local_store.dart';
import 'media_cache.dart';
import 'media_view_cache.dart';
import 'outbox_service.dart';

/// Полная очистка офлайн-состояния при выходе/смене пользователя.
///
/// КРИТИЧНО: данные оседают на диске (кэш + очередь отправки), поэтому без этой
/// очистки новый/другой пользователь на том же устройстве увидел бы данные
/// предыдущего, а его несработавшие офлайн-правки ушли бы под чужой сессией.
/// Вызывать из всех точек смены личности (logout, несовпадение uid, первый
/// запуск). По мере роста офлайн-слоя сюда добавится очистка медиа-кэша (Фаза 4).
Future<void> resetOfflineState() async {
  await OutboxService.instance.clear(); // гасим очередь (и pendingCount)
  await MediaCache.instance.clearPending(); // и отложенные медиа-файлы
  await OfflineImageCacheManager.instance.emptyCache(); // кэш просмотра медиа
  await LocalStore.instance.clearAll();
}
