import 'dart:async';

import 'centrifugo_service.dart';

/// Канал комнаты совместного просмотра.
///
/// Говорит теми же сообщениями, что сайт: `play`, `pause`, `sync`, `source`,
/// `chat`, `hello`, `state`. Поэтому нативный плеер приложения и вкладка
/// браузера сидят в одной комнате и понимают друг друга.
class WatchChannel {
  WatchChannel(this.room, this.me);

  /// Код комнаты пары (выдаёт сервер по связи).
  final String room;

  /// Кто мы в этой комнате: свои же сообщения обратно не применяем.
  final String me;

  String get channel => 'watch:$room';

  RtUnsub? _unsub;

  /// Подписывается на комнату. [onMessage] получает разобранное сообщение.
  Future<void> connect(void Function(Map<String, dynamic>) onMessage) async {
    _unsub = await CentrifugoService.instance.subscribeRaw(channel, (data) {
      if ((data['from'] ?? '') == me) return; // эхо своих команд
      onMessage(data);
    });
  }

  Future<void> send(String type, {double at = 0, Map<String, dynamic>? extra}) async {
    final payload = <String, dynamic>{'t': type, 'at': at, 'from': me, ...?extra};
    try {
      await CentrifugoService.instance.publish(channel, payload);
    } catch (_) {
      // Обрыв связи лечит переподключение centrifuge: команда просто пропадёт,
      // а расхождение подтянет ближайший sync.
    }
  }

  Future<void> dispose() async {
    final u = _unsub;
    _unsub = null;
    if (u != null) await u();
  }
}
