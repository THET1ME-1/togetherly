import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Детектор связи поверх `connectivity_plus` (пакет был в зависимостях, но не
/// использовался). Даёт офлайн-слою сигнал «появилась/пропала сеть» для запуска
/// дельта-синхронизации и слива очереди отправки.
///
/// ВАЖНО: `connectivity_plus` сообщает о наличии ИНТЕРФЕЙСА, а не о реальной
/// достижимости сервера (captive-portal, сервер лежит, блокировки в РФ). Поэтому
/// [isOnline] — это ПОДСКАЗКА: переход false→true ЗАПУСКАЕТ попытку
/// синхронизации/слива, но не блокирует сетевые запросы (их успех/провал решает
/// сам PB-клиент). fail-open: при ошибке считаем, что сеть есть.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();
  factory ConnectivityService() => instance;

  final Connectivity _conn = Connectivity();
  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _online = true; // fail-open по умолчанию

  /// Текущая подсказка о связи (см. оговорку в шапке класса).
  bool get isOnline => _online;

  /// Поток смен состояния (только при РЕАЛЬНОМ изменении, distinct).
  Stream<bool> get onOnlineChanged => _controller.stream;

  Future<void> init() async {
    try {
      _online = _isOnline(await _conn.checkConnectivity());
    } catch (e) {
      debugPrint('ConnectivityService.checkConnectivity failed: $e');
      _online = true; // fail-open
    }
    _sub = _conn.onConnectivityChanged.listen((res) {
      final now = _isOnline(res);
      if (now != _online) {
        _online = now;
        if (!_controller.isClosed) _controller.add(now);
      }
    }, onError: (Object e) {
      debugPrint('ConnectivityService.onConnectivityChanged error: $e');
    });
  }

  // connectivity_plus v7: и checkConnectivity, и поток отдают List<...>.
  static bool _isOnline(List<ConnectivityResult> res) =>
      res.any((r) => r != ConnectivityResult.none);

  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}
