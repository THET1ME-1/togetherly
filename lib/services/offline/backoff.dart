import 'dart:math';

/// Экспоненциальный backoff с равным джиттером для авто-ретраев (синхронизация,
/// очередь отправки). Перенесено из `PbRealtimeService._backoffMs` в общий
/// модуль, чтобы офлайн-слой и realtime использовали одну формулу.
///
/// Джиттер критичен: без него после рестарта/моргания PB все клиенты ломятся
/// переподключаться синхронно (thundering herd).
final Random _backoffRnd = Random();

/// Задержка перед попыткой [attempt] (с нуля): 1,2,4,…,32с с джиттером [base/2,base].
int backoffMs(int attempt) {
  final base = 1000 * (1 << (attempt > 5 ? 5 : attempt)); // 1,2,4,…,32с
  return base ~/ 2 + _backoffRnd.nextInt(base ~/ 2 + 1);
}
