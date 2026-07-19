import 'dart:math';

/// Генерация идентификатора в формате PocketBase (15 символов [a-z0-9]).
///
/// PocketBase принимает КЛИЕНТСКИЙ id при create (см. `PbDataService._upsertById`
/// — create с `{'id': id}` на 404). Поэтому офлайн-созданная запись может сразу
/// получить валидный id, который сервер примет при отправке из очереди — без
/// хрупкого ремаппинга временных id на серверные.
const String _pbIdChars = 'abcdefghijklmnopqrstuvwxyz0123456789';
final Random _pbIdRnd = Random.secure();

/// Новый валидный PB-id (15 символов). 36^15 ≈ 2.2e23 — коллизии между
/// устройствами практически исключены.
String newPbId() => List.generate(
      15,
      (_) => _pbIdChars[_pbIdRnd.nextInt(_pbIdChars.length)],
    ).join();
