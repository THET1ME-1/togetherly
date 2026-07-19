import 'dart:async';
import 'dart:io' show Platform;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppWebViewController;
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../../services/locale_service.dart';
import '../../services/pb_auth_service.dart';
import '../../services/pocketbase_service.dart';
import '../../services/together_invite_repository.dart';
import '../../services/together_session_service.dart';

/// Совместный просмотр YouTube. Синхронизация play/pause/seek идёт через RTDB
/// (TogetherSessionService) — ноль Firestore-чтений. Видео стримится с серверов
/// YouTube напрямую на каждое устройство.
class WatchTogetherScreen extends StatefulWidget {
  /// ID группы (пары) — ключ RTDB-сессии.
  final String pairId;

  /// UID партнёра — нужен хосту, чтобы сразу прописать обоих в members.
  final String partnerUid;

  /// YouTube videoId. Для хоста — стартовое видео; гость получит его из RTDB.
  final String videoId;

  /// true — этот клиент создаёт сеанс; false — присоединяется к существующему.
  final bool isHost;

  const WatchTogetherScreen({
    super.key,
    required this.pairId,
    required this.partnerUid,
    required this.videoId,
    required this.isHost,
  });

  @override
  State<WatchTogetherScreen> createState() => _WatchTogetherScreenState();
}

class _WatchTogetherScreenState extends State<WatchTogetherScreen> {
  final _session = TogetherSessionService.instance;
  final _invite = TogetherInviteRepository();

  late YoutubePlayerController _controller;
  StreamSubscription<LiveSessionState?>? _sessionSub;
  StreamSubscription<Set<String>>? _presenceSub;
  Timer? _heartbeat;

  Set<String> _present = {};

  // Громкость видео — локальная (у каждого своя, не синкается → 0 записей).
  int _volume = 100;
  bool _muted = false;

  // Эфемерный чат сеанса (RTDB, 0 Firestore-чтений).
  final TextEditingController _chatCtrl = TextEditingController();
  final ScrollController _chatScroll = ScrollController();
  final List<ChatMessage> _messages = [];
  StreamSubscription<List<ChatMessage>>? _chatSub;

  /// Сообщение, на которое отвечаем (null — обычная отправка).
  ChatMessage? _replyingTo;

  /// Палитра реакций (с 💯).
  static const List<String> _reactionEmojis = [
    '❤️', '😂', '🔥', '💯', '👍', '😮', '😍', '😢',
  ];

  String get _uid => PocketBaseService().userId ?? '';

  // Якорь для расчёта ожидаемой позиции: фиксируем позицию и локальное время
  // её получения — так расчёт не зависит от расхождения часов устройств.
  int _remoteBaseMs = 0;
  int _remoteBaseAt = 0;
  bool _remotePlaying = false;

  String _currentMediaId = '';
  bool _lastIsPlaying = false;
  int _lastPosMs = 0;
  bool _ended = false;

  // Последнее ПРИМЕНЁННОЕ действие партнёра (seq + кто его сделал). pushAction
  // всегда инкрементит seq, а правки presence/chat — нет. Поэтому если seq и
  // контроллер не изменились, пришедший onValue — это всего лишь обновление
  // презенса/чата в том же узле, и трогать плеер не нужно (иначе сообщения в
  // чате вызывают микро-перемотки видео).
  int _lastRemoteSeq = -1;
  String _lastRemoteController = '';

  /// YouTube вернул ошибку встраивания (101/150 — владелец запретил
  /// воспроизведение вне youtube.com). Такое видео не проиграть нигде, кроме
  /// сайта/приложения YouTube — показываем понятное сообщение.
  bool _embedError = false;

  // Сторож готовности плеера: если YouTube-плеер не вышел в ready за окно ниже —
  // почти наверняка WebView/встраивание не поднялось (чёрный экран без явной
  // ошибки 101/150). Показываем тот же fallback-оверлей и логируем в Crashlytics.
  Timer? _readyTimeout;
  static const Duration _readyTimeoutWindow = Duration(seconds: 12);
  // Лог отказа плеера шлём один раз за сеанс (и embed-error, и timeout — это про
  // одну поломку; не хотим дублей в панели).
  bool _failureLogged = false;

  // Эхо-подавление по времени, а не флагом: seekTo/play/pause у плеера
  // применяются АСИНХРОННО (JS round-trip), и их событие приходит уже после
  // того, как синхронный флаг сброшен. Поэтому после применения удалённого
  // состояния глушим локальные пуши на окно времени, иначе устройства
  // зацикливаются, пиная друг друга («срабатывает через раз»).
  DateTime _suppressLocalUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // Кто сейчас «ведущий» — только он шлёт heartbeat, чтобы оба не пушили
  // одновременно и не создавали ping-pong микро-перемоток.
  late bool _iAmController = widget.isHost;

  static const int _driftThresholdMs = 1500;
  static const int _seekJumpMs = 2000; // скачок позиции = пользовательский seek
  static const Duration _suppressWindow = Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    _currentMediaId = widget.videoId;
    _controller = YoutubePlayerController(
      initialVideoId: widget.videoId,
      flags: const YoutubePlayerFlags(
        autoPlay: false,
        enableCaption: false,
        hideControls: false,
      ),
    )..addListener(_onPlayerEvent);

    _readyTimeout = Timer(_readyTimeoutWindow, _onReadyTimeout);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    if (widget.isHost) {
      await _session.startSession(
        pairId: widget.pairId,
        partnerUid: widget.partnerUid,
        activity: TogetherActivity.youtube,
        mediaId: widget.videoId,
      );
      await _invite.set(
        widget.pairId,
        activity: TogetherActivity.youtube.id,
        mediaId: widget.videoId,
        hostName: PbAuthService().currentProfile()?['displayName'] as String? ?? '',
      );
    } else {
      await _session.joinPresence(widget.pairId);
    }
    _sessionSub = _session.watch(widget.pairId).listen(_onRemoteState);
    _presenceSub = _session.watchPresence(widget.pairId).listen((p) {
      if (mounted) setState(() => _present = p);
    });
    // Один live-список (старые сверху): пересобираем _messages и реакции из
    // снапшота. Скроллим вниз только когда появилось НОВОЕ сообщение (рост
    // длины), а не на изменение реакции.
    _chatSub = _session.watchSessionChat(widget.pairId).listen((list) {
      if (!mounted) return;
      final grew = list.length > _messages.length;
      setState(() {
        _messages
          ..clear()
          ..addAll(list);
      });
      if (grew) _scrollChatToBottom();
    });
    _heartbeat = Timer.periodic(const Duration(seconds: 8), (_) => _maybeHeartbeat());
  }

  // ── Применение удалённого состояния к плееру ──────────────────────────────
  void _onRemoteState(LiveSessionState? state) {
    if (!mounted) return;
    if (state == null) {
      // Сеанс завершён партнёром.
      if (!_ended) _exit(closedByPartner: true);
      return;
    }
    // Наш собственный апдейт, вернувшийся через onValue — игнорируем эхо.
    if (state.controllerUid == _uid && state.seq == _session.lastLocalSeq) {
      return;
    }

    // Тот же seq и контроллер, что уже применяли → это правка presence/chat в
    // том же узле, а не новое действие плеера. Не пере-якорим и не дёргаем плеер.
    if (state.seq == _lastRemoteSeq &&
        state.controllerUid == _lastRemoteController) {
      return;
    }
    _lastRemoteSeq = state.seq;
    _lastRemoteController = state.controllerUid;

    // Удалённое состояние пришло от партнёра → ведущий теперь он.
    _iAmController = false;

    // Смена видео.
    if (state.mediaId.isNotEmpty && state.mediaId != _currentMediaId) {
      _currentMediaId = state.mediaId;
      _suppressLocalUntil = DateTime.now().add(_suppressWindow);
      _controller.load(state.mediaId);
    }

    // Якорим позицию по моменту получения (обходит расхождение часов).
    final nowLocal = DateTime.now().millisecondsSinceEpoch;
    _remoteBaseMs = state.positionMs;
    _remoteBaseAt = nowLocal;
    _remotePlaying = state.isPlaying;

    final target = _expectedRemoteMs();
    final curMs = _controller.value.position.inMilliseconds;
    final needSeek = (curMs - target).abs() > _driftThresholdMs;
    final needPlay = state.isPlaying && !_controller.value.isPlaying;
    final needPause = !state.isPlaying && _controller.value.isPlaying;

    // Глушим локальные пуши до того, как применяем — событие плеера придёт
    // асинхронно и попадёт в окно.
    if (needSeek || needPlay || needPause) {
      _suppressLocalUntil = DateTime.now().add(_suppressWindow);
    }
    if (needSeek) {
      _controller.seekTo(Duration(milliseconds: target));
    }
    if (needPlay) {
      _controller.play();
    } else if (needPause) {
      _controller.pause();
    }
    _lastIsPlaying = state.isPlaying;
    _lastPosMs = target;
    if (mounted) setState(() {});
  }

  int _expectedRemoteMs() {
    if (!_remotePlaying) return _remoteBaseMs;
    final elapsed = DateTime.now().millisecondsSinceEpoch - _remoteBaseAt;
    return _remoteBaseMs + (elapsed > 0 ? elapsed : 0);
  }

  // ── Локальные действия пользователя → пуш в RTDB ──────────────────────────
  void _onPlayerEvent() {
    if (_ended) return;
    final v = _controller.value;

    // Плеер вышел в ready → снимаем сторож таймаута (всё нормально загрузилось).
    if (v.isReady) {
      _readyTimeout?.cancel();
      _readyTimeout = null;
    }

    // Ошибки встраивания YouTube: 101 и 150 — владелец запретил
    // воспроизведение вне youtube.com. 100 — видео удалено/приватное.
    final embedBlocked =
        v.errorCode == 101 || v.errorCode == 150 || v.errorCode == 100;
    if (embedBlocked != _embedError && mounted) {
      setState(() => _embedError = embedBlocked);
      if (embedBlocked) {
        _readyTimeout?.cancel();
        _readyTimeout = null;
        // Логируем с телеметрией устройства/WebView (см. _logPlayerFailure).
        unawaited(_logPlayerFailure('embed_error', v.errorCode));
      }
    }

    // Во время буферизации/догрузки YouTube кратко отдаёт isPlaying=false и
    // прыгающую позицию — это НЕ действие пользователя. Реагируем только на
    // устойчивые playing/paused, иначе у партнёра видео дёргается (стоп-старт
    // «играет секунду — встало»). Базовые значения тоже не сдвигаем, чтобы
    // реальный seek, случившийся вокруг буфера, не потерялся.
    final st = v.playerState;
    if (st != PlayerState.playing && st != PlayerState.paused) return;

    final posMs = v.position.inMilliseconds;
    final playing = v.isPlaying;

    final playStateChanged = playing != _lastIsPlaying;
    final seeked = (posMs - _lastPosMs).abs() > _seekJumpMs;

    // Базовые значения обновляем ВСЕГДА (в т.ч. в окне подавления), иначе
    // после окна старый baseline даст ложный «seek».
    _lastIsPlaying = playing;
    _lastPosMs = posMs;

    // В окне подавления (только что применили удалённое состояние) не пушим —
    // это эхо наших же seekTo/play/pause.
    if (DateTime.now().isBefore(_suppressLocalUntil)) return;

    if (playStateChanged || seeked) {
      _push(playing, posMs);
    }
  }

  void _push(bool playing, int posMs) {
    // Любое наше действие делает нас ведущим (heartbeat теперь шлём мы).
    _iAmController = true;
    _session.pushAction(
      pairId: widget.pairId,
      isPlaying: playing,
      positionMs: posMs,
    );
  }

  // Пульс шлёт только ведущий, чтобы оба устройства не пушили одновременно и
  // не создавали ping-pong микро-перемоток. Даёт партнёру свежий якорь дрейфа.
  void _maybeHeartbeat() {
    if (_ended || !mounted || !_iAmController) return;
    if (!_controller.value.isPlaying) return;
    _push(true, _controller.value.position.inMilliseconds);
  }

  // ── Завершение ────────────────────────────────────────────────────────────
  void _exit({bool closedByPartner = false}) {
    if (_ended) return;
    _ended = true;
    _heartbeat?.cancel();
    _sessionSub?.cancel();
    _presenceSub?.cancel();
    // Очистка fire-and-forget — это вызовы синглтон-сервиса/Firestore, не
    // привязаны к жизненному циклу виджета и завершатся после pop.
    if (widget.isHost) {
      _session.endSession(widget.pairId);
      _invite.clear(widget.pairId);
    } else {
      _session.leavePresence(widget.pairId);
    }
    if (!mounted) return;
    if (closedByPartner) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(LocaleService.current.partnerEndedWatchTogether),
        ),
      );
    }
    Navigator.of(context).pop();
  }

  void _sendChat() {
    final t = _chatCtrl.text.trim();
    if (t.isEmpty) return;
    final reply = _replyingTo;
    _session.sendChatMessage(
      pairId: widget.pairId,
      text: t,
      replyToId: reply?.id,
      replyToName: reply?.name,
      replyToText: reply?.text,
    );
    _chatCtrl.clear();
    if (reply != null) setState(() => _replyingTo = null);
  }

  void _startReply(ChatMessage m) {
    HapticFeedback.mediumImpact();
    setState(() => _replyingTo = m);
  }

  void _toggleReaction(ChatMessage m, String emoji) {
    final mine = m.reactions[_uid];
    _session.setChatReaction(
      pairId: widget.pairId,
      messageId: m.id,
      emoji: mine == emoji ? null : emoji,
    );
  }

  /// Пикер реакций — тёмный bottom-sheet с палитрой (включая 💯).
  void _showReactionPicker(ChatMessage m) {
    final mine = m.reactions[_uid];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1B1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 20),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in _reactionEmojis)
                GestureDetector(
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleReaction(m, e);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: mine == e
                          ? const Color(0xFFEC4899).withOpacity(0.30)
                          : Colors.transparent,
                    ),
                    child: Text(e, style: const TextStyle(fontSize: 30)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _readyTimeout?.cancel();
    _sessionSub?.cancel();
    _presenceSub?.cancel();
    _chatSub?.cancel();
    _chatCtrl.dispose();
    _chatScroll.dispose();
    _controller.removeListener(_onPlayerEvent);
    _controller.dispose();
    // Страховка: снимаем презенс/сеанс, если экран закрыли мимо _exit
    // (системный жест/смена роута). Без await — dispose не async.
    if (!_ended) {
      if (widget.isHost) {
        _session.endSession(widget.pairId);
        _invite.clear(widget.pairId);
      } else {
        _session.leavePresence(widget.pairId);
      }
    }
    super.dispose();
  }

  // Сеанс всегда 1-на-1, поэтому «партнёр на месте» = в презенсе есть любой
  // uid, кроме моего. Не завязываемся на конкретный widget.partnerUid: он может
  // прийти пустым/неверным, и тогда висело бы «ожидаем партнёра», хотя оба тут.
  bool get _partnerHere => _present.any((u) => u.isNotEmpty && u != _uid);

  void _setVolume(int v) {
    setState(() {
      _volume = v;
      _muted = v == 0;
    });
    _controller.setVolume(v);
  }

  void _toggleMute() {
    if (_muted) {
      // Восстанавливаем прежний уровень (или 100, если был 0).
      final restore = _volume == 0 ? 100 : _volume;
      setState(() {
        _muted = false;
        _volume = restore;
      });
      _controller.setVolume(restore);
    } else {
      setState(() => _muted = true);
      _controller.setVolume(0);
    }
  }

  Widget _buildEmbedErrorOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.92),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline_rounded,
              color: Colors.white70, size: 40),
          const SizedBox(height: 14),
          Text(
            LocaleService.current.videoCannotWatchTogether,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            LocaleService.current.videoEmbedBlockedHint,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white60, fontSize: 13, height: 1.3),
          ),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: _openCurrentOnYoutube,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: Text(LocaleService.current.openOnYoutube),
              ),
              ElevatedButton.icon(
                onPressed: () => _exit(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.search_rounded, size: 18),
                label: Text(LocaleService.current.chooseAnother),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Открыть текущий ролик в приложении/на сайте YouTube — запасной выход, когда
  /// встраивание заблокировано на этом устройстве (регион/возраст/старый WebView).
  Future<void> _openCurrentOnYoutube() async {
    final id = _currentMediaId;
    if (id.isEmpty) return;
    final uri = Uri.parse('https://www.youtube.com/watch?v=$id');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Плеер не поднялся за окно ожидания. На практике это «чёрный экран» без
  /// кода 101/150 — встроенный YouTube не запустился (старый/выключенный
  /// WebView, VPN/блокировщик, нет сервисов Google). Показываем тот же
  /// fallback-оверлей с «Открыть на YouTube» и логируем телеметрию.
  void _onReadyTimeout() {
    _readyTimeout = null;
    if (_ended || !mounted) return;
    if (_controller.value.isReady) return; // успел — ничего не делаем
    setState(() => _embedError = true);
    unawaited(
      _logPlayerFailure('player_not_ready_timeout', _controller.value.errorCode),
    );
  }

  /// Единая точка логирования отказа co-watch плеера в Crashlytics — с моделью
  /// устройства и ВЕРСИЕЙ системного WebView (её Crashlytics сам не собирает, а
  /// именно она — главная подозреваемая). Шлём один раз за сеанс. Лог не должен
  /// влиять на UI, поэтому всё в try/catch и fire-and-forget.
  Future<void> _logPlayerFailure(String kind, int? errorCode) async {
    if (_failureLogged) return;
    _failureLogged = true;
    try {
      Sentry.configureScope((s) => s.setExtra('cw_failure_kind', kind));
      Sentry.configureScope((s) => s.setExtra('cw_yt_error_code', errorCode ?? -1));
      Sentry.configureScope((s) => s.setExtra('cw_is_host', widget.isHost));
      Sentry.configureScope((s) => s.setExtra('cw_video_id', _currentMediaId));
      if (Platform.isAndroid) {
        final wv = await InAppWebViewController.getCurrentWebViewPackage();
        Sentry.configureScope(
            (s) => s.setExtra('cw_webview_pkg', wv?.packageName ?? 'unknown'));
        Sentry.configureScope((s) => s.setExtra(
              'cw_webview_version',
              wv?.versionName ?? 'unknown',
            ));
        final dev = await DeviceInfoPlugin().androidInfo;
        Sentry.configureScope((s) =>
            s.setExtra('cw_device', '${dev.manufacturer} ${dev.model}'));
        Sentry.configureScope(
            (s) => s.setExtra('cw_android_sdk', dev.version.sdkInt));
      }
    } catch (_) {
      // Сбор телеметрии не критичен — основной captureException ниже всё равно уйдёт.
    }
    await Sentry.captureException(
      'watch_together player failure: $kind (yt code=$errorCode)',
      withScope: (s) {
        s.setExtra('reason', 'co-watch player failure');
        s.level = SentryLevel.warning;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return YoutubePlayerBuilder(
      player: YoutubePlayer(
        controller: _controller,
        showVideoProgressIndicator: true,
      ),
      builder: (context, player) {
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(LocaleService.current.watchingTogether),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => _exit(),
            ),
            actions: [
              // Счётчик участников сеанса.
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Row(
                  children: [
                    Icon(
                      _partnerHere ? Icons.people_alt_rounded : Icons.person_rounded,
                      size: 18,
                      color: _partnerHere ? Colors.greenAccent : Colors.white54,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_present.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Stack(
                children: [
                  player,
                  if (_embedError)
                    Positioned.fill(child: _buildEmbedErrorOverlay()),
                ],
              ),
              const SizedBox(height: 16),
              // Статус подключения партнёра.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _partnerHere ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
                    color: _partnerHere ? Colors.greenAccent : Colors.white54,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _partnerHere
                        ? LocaleService.current.partnerJoined
                        : LocaleService.current.waitingForPartner,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.sync, color: Colors.white38, size: 14),
                  const SizedBox(width: 8),
                  Text(
                    _remotePlaying
                        ? LocaleService.current.syncedPlaying
                        : LocaleService.current.syncedPaused,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // ── Громкость видео (локальная) ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _muted || _volume == 0
                            ? Icons.volume_off_rounded
                            : (_volume < 50
                                ? Icons.volume_down_rounded
                                : Icons.volume_up_rounded),
                        color: Colors.white,
                      ),
                      onPressed: _toggleMute,
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                          overlayColor: Colors.white24,
                        ),
                        child: Slider(
                          value: (_muted ? 0 : _volume).toDouble(),
                          min: 0,
                          max: 100,
                          onChanged: (v) => _setVolume(v.round()),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${_muted ? 0 : _volume}',
                        textAlign: TextAlign.end,
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 16),
              Expanded(child: _buildChatList()),
              _buildChatInput(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChatList() {
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          LocaleService.current.writeFirstMessage,
          style: const TextStyle(color: Colors.white24, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      controller: _chatScroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (context, i) {
        final m = _messages[i];
        final mine = m.uid == _uid;
        return Dismissible(
          key: ValueKey('cw_${m.id}'),
          direction: DismissDirection.endToStart, // свайп влево → ответить
          dismissThresholds: const {DismissDirection.endToStart: 0.25},
          movementDuration: const Duration(milliseconds: 180),
          confirmDismiss: (_) async {
            _startReply(m);
            return false;
          },
          background: const SizedBox.shrink(),
          secondaryBackground: const Padding(
            padding: EdgeInsets.only(right: 24),
            child: Align(
              alignment: Alignment.centerRight,
              child: Icon(Icons.reply_rounded, color: Colors.white70),
            ),
          ),
          child: Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onDoubleTap: () => _showReactionPicker(m),
                  onLongPress: () => _showReactionPicker(m),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.72,
                    ),
                    decoration: BoxDecoration(
                      color: mine ? const Color(0xFFEC4899) : Colors.white12,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (m.replyToId != null) _buildSessionReplyQuote(m),
                        Text(
                          m.text,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
                if (m.reactions.isNotEmpty) _buildSessionReactionChips(m),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSessionReplyQuote(ChatMessage m) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.22),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            m.replyToName ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          Text(
            m.replyToText ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionReactionChips(ChatMessage m) {
    final counts = <String, int>{};
    for (final e in m.reactions.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    if (counts.isEmpty) return const SizedBox.shrink();
    final mine = m.reactions[_uid];
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Wrap(
        spacing: 4,
        children: [
          for (final entry in counts.entries)
            GestureDetector(
              onTap: () => _toggleReaction(m, entry.key),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: mine == entry.key
                        ? const Color(0xFFEC4899)
                        : Colors.transparent,
                    width: 1,
                  ),
                ),
                child: Text(
                  '${entry.key} ${entry.value}',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSessionReplyBanner() {
    final r = _replyingTo!;
    return Container(
      margin: const EdgeInsets.only(left: 4, right: 4, bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply_rounded, color: Color(0xFFEC4899), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  LocaleService.current.chatReplyingTo(r.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFEC4899),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                Text(
                  r.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 12.5),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded,
                color: Colors.white54, size: 20),
            onPressed: () => setState(() => _replyingTo = null),
          ),
        ],
      ),
    );
  }

  Widget _buildChatInput() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyingTo != null) _buildSessionReplyBanner(),
            Row(
          children: [
            Expanded(
              child: TextField(
                controller: _chatCtrl,
                style: const TextStyle(color: Colors.white),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendChat(),
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: LocaleService.current.messageInputHint,
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.white10,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send_rounded, color: Color(0xFFEC4899)),
              onPressed: _sendChat,
            ),
          ],
        ),
          ],
        ),
      ),
    );
  }
}
