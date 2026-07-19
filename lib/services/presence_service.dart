import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:pocketbase/pocketbase.dart';
import 'pocketbase_service.dart';
import 'pb_data_service.dart';
import 'pb_realtime_service.dart';

/// Общий онлайн-презенс на PocketBase (heartbeat+TTL — аналога RTDB
/// onDisconnect в PB нет).
///
/// Пока приложение в foreground, шлём heartbeat (обновляем
/// `user_presence.seen_at` своего uid) каждые [_beatInterval]. Партнёр считает
/// нас «в сети», если seen_at свежее [_freshness]. При уходе в фон heartbeat
/// останавливается → seen_at протухает → партнёр видит офлайн через [_freshness].
class PresenceService with WidgetsBindingObserver {
  PresenceService._();
  static final PresenceService instance = PresenceService._();
  factory PresenceService() => instance;

  static const Duration _beatInterval = Duration(seconds: 12);
  static const Duration _freshness = Duration(seconds: 35);

  Timer? _heartbeat;
  bool _started = false;

  /// Запустить heartbeat (после входа/привязки). Идемпотентно.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _beat();
    _heartbeat = Timer.periodic(_beatInterval, (_) => _beat());
  }

  /// Остановить heartbeat (при выходе из аккаунта).
  void stop() {
    _started = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  void _beat() {
    final uid = PocketBaseService().userId;
    if (uid == null || uid.isEmpty) return;
    PbDataService().touchPresence(uid);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) return;
    if (state == AppLifecycleState.resumed) {
      _beat();
      _heartbeat ??= Timer.periodic(_beatInterval, (_) => _beat());
    } else {
      // paused/inactive/hidden/detached — перестаём слать heartbeat; seen_at
      // протухнет и партнёр увидит офлайн через _freshness.
      _heartbeat?.cancel();
      _heartbeat = null;
    }
  }

  /// Онлайн ли [uid] — живой поток. Комбинирует SSE на `user_presence` (seen_at
  /// меняется на каждый heartbeat) с периодической переоценкой свежести — чтобы
  /// точка погасла, когда партнёр перестал слать heartbeat и SSE-событий нет.
  Stream<bool> watchOnline(String uid) {
    if (uid.isEmpty) return Stream.value(false);
    late StreamController<bool> ctrl;
    StreamSubscription<RecordModel?>? sseSub;
    Timer? ticker;
    int? seenAtMs;
    bool? lastEmitted;

    void evaluate() {
      final now = DateTime.now().millisecondsSinceEpoch;
      final online =
          seenAtMs != null && (now - seenAtMs!) < _freshness.inMilliseconds;
      if (online != lastEmitted) {
        lastEmitted = online;
        if (!ctrl.isClosed) ctrl.add(online);
      }
    }

    ctrl = StreamController<bool>(
      onListen: () {
        sseSub = PbRealtimeService().watchPresence(uid).listen((rec) {
          seenAtMs = (rec?.data['seen_at'] as num?)?.toInt();
          evaluate();
        }, onError: (_) {});
        ticker = Timer.periodic(const Duration(seconds: 10), (_) => evaluate());
      },
      onCancel: () {
        sseSub?.cancel();
        ticker?.cancel();
      },
    );
    return ctrl.stream;
  }
}
