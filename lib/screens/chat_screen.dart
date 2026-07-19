import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image_picker/image_picker.dart';
import '../utils/safe_pick.dart';
import '../utils/safe_text.dart';
import 'package:path_provider/path_provider.dart';

import '../models/chat_msg.dart';
import '../models/memory.dart';
import '../models/pair_data.dart';
import '../models/user_data.dart';
import '../services/chat_service.dart';
import '../services/pb_push_service.dart';
import '../services/locale_service.dart';
import '../services/pocketbase_service.dart';
import '../services/pb_data_service.dart';
import '../services/presence_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common/app_dialog.dart';
import '../widgets/md_message_text.dart';
import '../widgets/storage_image.dart';
import 'memory_lane_screen.dart';

/// Цена смены фона чата в монетах (зеркало CONSUMABLE_PRICES на сервере).
const int _kChatBgPrice = 20;
const String _kChatBgAction = 'chat_background';

/// Детерминированный псевдо-рандом [0..1) из seed+salt — стабилен при
/// перерисовке (форма/наклон бабла не «прыгают» между кадрами).
double _seededUnit(int seed, int salt) {
  var x = (seed ^ (salt * 0x9E3779B1)) & 0x7fffffff;
  x = (x * 1103515245 + 12345) & 0x7fffffff;
  return (x % 100000) / 100000.0;
}

/// true — кодпоинт принадлежит эмодзи (символы, пиктограммы, флаги, стрелки-
/// символы). Грубо по диапазонам — достаточно, чтобы отличить «только эмодзи».
bool _isEmojiRune(int r) =>
    (r >= 0x1F000 && r <= 0x1FAFF) || // основной блок эмодзи
    (r >= 0x2600 && r <= 0x27BF) || // символы и дингбаты (☀❤✨…)
    (r >= 0x2B00 && r <= 0x2BFF) || // звёзды/стрелки-символы (⭐⬆…)
    (r >= 0x2300 && r <= 0x23FF) || // ⌚⏰⏳…
    (r >= 0x1F1E6 && r <= 0x1F1FF) || // региональные индикаторы (флаги)
    r == 0x2122 ||
    r == 0x2139 ||
    r == 0x2764; // ❤

/// Если текст состоит ТОЛЬКО из эмодзи (1–3 шт., пробелы допустимы) — вернуть
/// крупный размер шрифта для отрисовки без пузыря; иначе null.
double? _emojiOnlySize(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  var count = 0;
  for (final ch in t.characters) {
    if (ch.trim().isEmpty) continue; // пробелы между эмодзи допускаем
    var hasEmoji = false;
    var hasText = false;
    for (final r in ch.runes) {
      if (_isEmojiRune(r)) {
        hasEmoji = true;
      } else if (r == 0x200D || // ZWJ
          r == 0xFE0F || // вариативный селектор
          r == 0x20E3 || // комбинирующий keycap
          (r >= 0x1F3FB && r <= 0x1F3FF)) {
        // модификаторы тона кожи — нейтральны
      } else {
        hasText = true; // обычная буква/цифра/знак → это не «только эмодзи»
      }
    }
    if (hasText || !hasEmoji) return null;
    count++;
    if (count > 3) return null; // больше трёх — обычный пузырь
  }
  if (count == 0) return null;
  return count == 1
      ? 56.0
      : count == 2
          ? 48.0
          : 40.0;
}

/// Выражение мордочки на пузыре.
enum _FaceExpr { happy, love, wink, playful, sad, calm }

/// Постоянный текстовый чат пары. История целиком в RTDB → ноль Firestore-чтений.
class ChatScreen extends StatefulWidget {
  final PairData pairData;
  final AppTheme theme;
  final String myDisplayName;
  final UserData? userData;

  const ChatScreen({
    super.key,
    required this.pairData,
    required this.theme,
    required this.myDisplayName,
    this.userData,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ChatService _chat = ChatService.instance;
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  String get _groupId => widget.pairData.pairId;
  // Личность из PocketBase: чат отличает свои сообщения по userId
  // (выравнивание/удаление).
  String get _myUid => PocketBaseService().userId ?? '';
  AppTheme get _t => widget.theme;

  /// Пины для @-подсказок (грузятся один раз, cache-first → 0 серверных чтений).
  List<Memory> _pins = [];

  /// Сообщение, которое сейчас редактируем (null — обычная отправка).
  ChatMsg? _editing;

  /// Сообщение, на которое отвечаем (null — обычная отправка).
  ChatMsg? _replyingTo;

  /// «Печатает…»: таймер авто-сброса и троттлинг пингов.
  Timer? _typingStopTimer;
  DateTime _lastTypingPing = DateTime.fromMillisecondsSinceEpoch(0);

  /// Прикреплённый к набираемому сообщению пин.
  Memory? _attachedPin;

  /// Выбранное отправителем выражение мордочки (липкое между сообщениями;
  /// null — без лица). Ставит автор сам — лицо больше не угадывается по тексту.
  _FaceExpr? _selectedFace = _FaceExpr.happy;
  /// Выбранный цвет пузыря (null — цвет темы). Липкий между сообщениями.
  Color? _selectedColor;
  /// Позиция мордочки (доли 0..1), по умолчанию низ-центр. Липкая.
  double _selectedFaceX = 0.5;
  double _selectedFaceY = 0.78;
  /// До 5 недавних цветов (глобально, из prefs).
  List<Color> _recentColors = const [];

  /// Снимок липкого оформления на время редактирования. Пока правим сообщение,
  /// _selected* временно держат стиль ИМЕННО этого сообщения (чтобы лист
  /// оформления показывал и менял его); после выхода из правки восстанавливаем
  /// липкий выбор для новых сообщений — правка старого не должна его сбивать.
  Color? _snapColor;
  _FaceExpr? _snapFace;
  double _snapFaceX = 0.5;
  double _snapFaceY = 0.78;
  bool _hasStyleSnap = false;

  /// Текущий @-запрос для подсказок (null — подсказок нет).
  String? _mentionQuery;
  int _lastMessageTs = 0;

  /// Путь к локальному фону чата (null — фон не задан).
  String? _bgPath;

  /// Окно подгрузки истории. Не грузим всю переписку сразу — стартуем с
  /// небольшого окна и расширяем его при прокрутке к началу (экономит трафик
  /// RTDB: onValue иначе тянул бы весь срез на каждое новое сообщение).
  static const int _kPageSize = 30;
  int _limit = _kPageSize;
  late Stream<List<ChatMsg>> _messagesStream;
  bool _loadingMore = false;
  bool _hasMore = true;
  double? _retainFromBottom;
  bool _didInitialScroll = false;
  bool _lastIsMine = false;
  // ts последнего сообщения, под которое уже автоскроллили вниз. Чтобы любой
  // ребилд (ответ, «печатает», баннер композера) НЕ дёргал камеру вниз —
  // вниз прыгаем только при ДЕЙСТВИТЕЛЬНО новом сообщении.
  int _autoScrolledTs = 0;
  // GlobalKey каждого бабла по id — для перехода к оригиналу по тапу на цитату.
  final Map<String, GlobalKey> _msgKeys = {};
  // Сообщение, кратковременно подсвеченное после перехода по цитате.
  String? _highlightMsgId;
  // Окно «влёта» сообщений со сторон: true при открытии чата (изначально
  // видимые баблы анимируются), затем выключается — при скролле без анимации.
  bool _playEntrance = true;
  // Эпоха «влёта»: кнопка ↻ в шапке инкрементит её → ключи _EntranceSlide
  // меняются → виджеты перемонтируются и проигрывают анимацию заново.
  int _entranceEpoch = 0;

  /// Идёт отправка — блокирует повторный тап, чтобы не уехал дубликат при плохой сети.
  bool _sending = false;

  /// Ключ маркера «Новые сообщения» — чтобы открыть чат на месте остановки чтения.
  final GlobalKey _unreadKey = GlobalKey();
  bool _hasUnreadMarker = false;

  /// ts последнего прочтения на момент ОТКРЫТИЯ чата — фиксируем до markRead,
  /// чтобы отрисовать разделитель «Новые сообщения» над первым непрочитанным.
  int _openLastRead = -1;

  /// Последний полученный срез — фолбэк, пока пересоздаём поток при пагинации
  /// (иначе StreamBuilder на миг показал бы спиннер вместо списка).
  List<ChatMsg> _lastMessages = const [];

  /// Минимальный ts прочтения среди остальных участников. Своё сообщение
  /// «прочитано» (✓✓), если его ts ≤ этого значения, иначе «отправлено» (✓).
  int _partnerReadTs = 0;
  StreamSubscription<Map<String, int>>? _readsSub;

  /// Кнопка «вниз» показывается, когда заметно отлистали вверх от низа.
  bool _showScrollDown = false;
  /// Сохранённая позиция прокрутки (восстанавливаем при открытии чата).
  double? _savedScrollOffset;
  /// Троттлинг сохранения позиции — чтобы не писать prefs на каждый кадр.
  DateTime _lastScrollSave = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // Пока этот чат открыт — foreground-пуш о новом сообщении не дублируем.
    PbPushService.activeChatGroupId = _groupId;
    _messagesStream = _chat.watchMessages(_groupId, limit: _limit);
    _captureUnreadAnchor();
    _watchPartnerReads();
    _chat.ensureMember(_groupId);
    _loadPins();
    _loadBackground();
    _loadSavedScroll();
    _loadRecentColors();
    _controller.addListener(_onTextChanged);
    _scrollController.addListener(_onScroll);
  }

  /// Подтягиваем сохранённую позицию прокрутки до первой раскладки списка.
  Future<void> _loadSavedScroll() async {
    final px = await _chat.loadScrollOffset(_groupId);
    if (mounted) _savedScrollOffset = px;
  }

  Future<void> _loadRecentColors() async {
    final ints = await _chat.loadRecentColors();
    if (mounted) {
      setState(() => _recentColors = ints.map((i) => Color(i)).toList());
    }
  }

  /// Фиксируем ts последнего прочтения ДО того, как markRead его перезапишет —
  /// нужно для разделителя «Новые сообщения».
  Future<void> _captureUnreadAnchor() async {
    final ts = await _chat.lastReadTs(_groupId);
    if (mounted) setState(() => _openLastRead = ts);
  }

  /// Слушаем статусы прочтения партнёра(ов) для галочек ✓/✓✓ на своих
  /// сообщениях. «Прочитано» = минимальный ts среди всех, кроме меня.
  void _watchPartnerReads() {
    _readsSub = _chat.watchReads(_groupId).listen(
      (reads) {
        if (!mounted) return;
        int? minOthers;
        reads.forEach((uid, ts) {
          if (uid == _myUid) return;
          minOthers = (minOthers == null || ts < minOthers!) ? ts : minOthers;
        });
        final next = minOthers ?? 0;
        if (next != _partnerReadTs) setState(() => _partnerReadTs = next);
      },
      onError: (e) => debugPrint('watchReads error: $e'),
    );
  }

  Future<void> _loadBackground() async {
    final path = await _chat.backgroundPath(_groupId);
    if (!mounted) return;
    if (path != null && File(path).existsSync()) {
      setState(() => _bgPath = path);
    } else if (path != null) {
      // Файл пропал (очистка кэша/переустановка) — сбрасываем.
      await _chat.clearBackground(_groupId);
    }
  }

  @override
  void dispose() {
    if (PbPushService.activeChatGroupId == _groupId) {
      PbPushService.activeChatGroupId = null;
    }
    _readsSub?.cancel();
    _typingStopTimer?.cancel();
    _chat.setTyping(_groupId, false);
    // Сохраняем точную позицию выхода — вернёмся ровно сюда при перезаходе.
    if (_scrollController.hasClients) {
      _chat.saveScrollOffset(_groupId, _scrollController.position.pixels);
    }
    _scrollController.removeListener(_onScroll);
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    if (_lastMessageTs > 0) _chat.markRead(_groupId, _lastMessageTs);
    super.dispose();
  }

  // ── Пагинация истории ───────────────────────────────────────────────────────

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // Кнопка «вниз» — когда заметно отлистали от низа.
    final show = (pos.maxScrollExtent - pos.pixels) > 320;
    if (show != _showScrollDown) setState(() => _showScrollDown = show);
    // Сохраняем позицию (троттлинг) — чтобы при перезаходе вернуть ровно сюда.
    final now = DateTime.now();
    if (now.difference(_lastScrollSave).inMilliseconds >= 400) {
      _lastScrollSave = now;
      _chat.saveScrollOffset(_groupId, pos.pixels);
    }
    // Пагинация: у начала ленты подгружаем старые.
    if (_loadingMore || !_hasMore) return;
    if (pos.pixels <= pos.minScrollExtent + 80) _loadMore();
  }

  /// Плавно вернуться к последнему сообщению (кнопка-стрелка «вниз»).
  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController
        .animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        )
        .then((_) {
      // Контент мог дорасти за время анимации (подгрузка/раскрытие пузырей) —
      // добиваем до фактического низа, чтобы остановиться ровно на последнем
      // сообщении, а не «где-то рядом».
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _loadMore() {
    _loadingMore = true;
    // Запоминаем расстояние от низа: контент добавится сверху, и так вьюпорт
    // не «прыгнет» после расширения окна.
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      _retainFromBottom = pos.maxScrollExtent - pos.pixels;
    }
    setState(() {
      _limit += _kPageSize;
      _messagesStream = _chat.watchMessages(_groupId, limit: _limit);
    });
  }

  /// Управление прокруткой после отрисовки очередного среза сообщений.
  void _afterMessagesLayout() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;

    // Подгрузили старые — восстанавливаем позицию (держим расстояние от низа).
    if (_loadingMore) {
      if (_retainFromBottom != null) {
        final target = (pos.maxScrollExtent - _retainFromBottom!)
            .clamp(0.0, pos.maxScrollExtent);
        _scrollController.jumpTo(target);
      }
      _loadingMore = false;
      _retainFromBottom = null;
      return;
    }

    // Первая отрисовка: восстанавливаем сохранённую позицию — ровно туда, где
    // человек вышел. Нет сохранённой → встаём в самый низ (+ маркер «Новые»).
    if (!_didInitialScroll) {
      _didInitialScroll = true;
      _autoScrolledTs = _lastMessageTs;
      final saved = _savedScrollOffset;
      if (saved != null && saved > 0) {
        _scrollController.jumpTo(saved.clamp(0.0, pos.maxScrollExtent));
      } else {
        _scrollController.jumpTo(pos.maxScrollExtent);
        if (_hasUnreadMarker) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _scrollToUnread());
        }
      }
      // Изначально видимые баблы уже проиграли «влёт» — дальше (при скролле)
      // сообщения появляются без анимации.
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) _playEntrance = false;
      });
      return;
    }

    // Только при ДЕЙСТВИТЕЛЬНО новом сообщении. Иначе любой ребилд (ответ на
    // старое сообщение, «печатает», баннер композера, клавиатура) дёргал бы
    // камеру вниз — сравниваем ts последнего сообщения с тем, под который уже
    // скроллили.
    if (_lastMessageTs <= _autoScrolledTs) return;
    _autoScrolledTs = _lastMessageTs;

    // Новое сообщение: прокручиваем вниз, только если пользователь уже у низа
    // или это его собственное сообщение (как в мессенджерах).
    final nearBottom = pos.maxScrollExtent - pos.pixels < 160;
    if (nearBottom || _lastIsMine) {
      _scrollController.jumpTo(pos.maxScrollExtent);
    }
  }

  /// Плавно показывает маркер «Новые сообщения» у верхнего края, если он
  /// уже построен (находится близко к низу — обычный случай при паре непрочитанных).
  void _scrollToUnread() {
    final ctx = _unreadKey.currentContext;
    if (ctx == null || !_scrollController.hasClients) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.12, // маркер чуть ниже верхнего края вьюпорта
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Future<void> _loadPins() async {
    if (_groupId.isEmpty) return;
    final recs = await PbDataService().loadMemories(_groupId, limit: 50);
    if (!mounted) return;
    setState(() => _pins = recs.map((r) => Memory.fromPb(r)).toList());
  }

  String _memoryLabel(Memory m) {
    final title = (m.title ?? '').trim();
    if (title.isNotEmpty) return title;
    final caption = (m.caption ?? '').trim();
    if (caption.isNotEmpty) {
      return caption.truncateGraphemes(30, ellipsis: '…');
    }
    final loc = (m.locationName ?? '').trim();
    if (loc.isNotEmpty) return loc;
    final mus = (m.musicTitle ?? '').trim();
    if (mus.isNotEmpty) return mus;
    return m.typeLabel;
  }

  // ── @-подсказки ────────────────────────────────────────────────────────────

  void _onTextChanged() {
    _emitTyping();
    final text = _controller.text;
    final sel = _controller.selection.baseOffset;
    if (sel < 0) {
      if (_mentionQuery != null) setState(() => _mentionQuery = null);
      return;
    }
    // Ищем последний '@' перед курсором без пробела после него.
    final upToCursor = text.substring(0, sel);
    final atIndex = upToCursor.lastIndexOf('@');
    if (atIndex == -1) {
      if (_mentionQuery != null) setState(() => _mentionQuery = null);
      return;
    }
    final afterAt = upToCursor.substring(atIndex + 1);
    if (afterAt.contains(' ') || afterAt.contains('\n')) {
      if (_mentionQuery != null) setState(() => _mentionQuery = null);
      return;
    }
    setState(() => _mentionQuery = afterAt.toLowerCase());
  }

  List<Memory> get _mentionResults {
    final q = _mentionQuery;
    if (q == null) return const [];
    final matches = _pins.where((m) {
      final label = _memoryLabel(m).toLowerCase();
      return q.isEmpty || label.contains(q);
    }).toList();
    return matches.take(6).toList();
  }

  /// Вставляет '@' в конец и открывает список пинов (кнопка-скрепка).
  void _triggerPinPicker() {
    final text = _controller.text;
    final needsAt = !text.endsWith('@');
    if (needsAt) {
      _controller.text = text.isEmpty || text.endsWith(' ')
          ? '$text@'
          : '$text @';
    }
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    _focusNode.requestFocus();
    setState(() => _mentionQuery = '');
  }

  void _selectMention(Memory m) {
    // Убираем '@query' из поля и прикрепляем пин.
    final text = _controller.text;
    final sel = _controller.selection.baseOffset;
    final upToCursor = text.substring(0, sel);
    final atIndex = upToCursor.lastIndexOf('@');
    if (atIndex != -1) {
      final newText = text.substring(0, atIndex) + text.substring(sel);
      _controller.text = newText;
      _controller.selection = TextSelection.collapsed(offset: atIndex);
    }
    setState(() {
      _attachedPin = m;
      _mentionQuery = null;
    });
  }

  // ── Отправка / редактирование ───────────────────────────────────────────────

  Future<void> _send() async {
    // Защита от повторной отправки: при плохой сети await может «висеть»,
    // и повторный тап по кнопке отправил бы дубликат.
    if (_sending) return;
    final text = _controller.text.trim();
    final editing = _editing;
    final pin = _attachedPin;
    final reply = _replyingTo;
    if (text.isEmpty && pin == null) return;

    // Оптимистично очищаем ввод СРАЗУ (до сети). RTDB с offline-persistence
    // ставит одну запись в очередь и доставит её ровно один раз при реконнекте,
    // поэтому очистка до await безопасна и исключает дубликаты.
    _sending = true;
    _controller.clear();
    _stopTyping();
    setState(() {
      _editing = null;
      _attachedPin = null;
      _replyingTo = null;
      _mentionQuery = null;
    });

    try {
      if (editing != null) {
        await _chat.edit(
          groupId: _groupId,
          messageId: editing.id,
          newText: text,
          face: _selectedFace?.name,
          color: _selectedColor?.toARGB32(),
          faceX: _selectedFace == null ? null : _selectedFaceX,
          faceY: _selectedFace == null ? null : _selectedFaceY,
        );
        if (mounted) setState(_restoreStyleSnap);
      } else {
        final ok = await _chat.send(
          groupId: _groupId,
          senderName: widget.myDisplayName,
          text: text.isEmpty ? '📌' : text,
          pinId: pin?.id,
          pinTitle: pin != null ? _memoryLabel(pin) : null,
          pinThumb: pin != null ? _memoryThumb(pin) : null,
          replyToId: reply?.id,
          replyToName: reply?.name,
          replyToText: reply == null
              ? null
              : (reply.deleted
                  ? LocaleService.current.chatDeletedPlaceholder
                  : (reply.text.isNotEmpty
                      ? reply.text
                      : (reply.pinTitle ?? '📌'))),
          face: _selectedFace?.name, // выбранное автором лицо (липкое)
          color: _selectedColor?.toARGB32(),
          faceX: _selectedFace == null ? null : _selectedFaceX,
          faceY: _selectedFace == null ? null : _selectedFaceY,
        );
        if (!ok && mounted) {
          // Сообщение не сохранилось (у мигрированной группы Supabase —
          // единственное хранилище, офлайн-очереди как у RTDB нет). Возвращаем
          // ввод, чтобы текст не потерялся и можно было повторить отправку.
          _controller.text = text;
          _controller.selection =
              TextSelection.collapsed(offset: text.length);
          setState(() {
            _attachedPin = pin;
            _replyingTo = reply;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(LocaleService.current.chatSendFailed)),
          );
        }
      }
    } finally {
      _sending = false;
    }
  }

  void _startEdit(ChatMsg msg) {
    setState(() {
      _editing = msg;
      _attachedPin = null;
      _replyingTo = null;
      _mentionQuery = null;
      // Подхватываем оформление редактируемого сообщения (сняв снимок липкого),
      // чтобы лист стиля показал и дал поменять цвет/мордочку/позицию ровно
      // у этого сообщения.
      if (!_hasStyleSnap) {
        _snapColor = _selectedColor;
        _snapFace = _selectedFace;
        _snapFaceX = _selectedFaceX;
        _snapFaceY = _selectedFaceY;
        _hasStyleSnap = true;
      }
      _selectedColor = msg.color != null ? Color(msg.color!) : null;
      _selectedFace = _faceFromName(msg.face);
      _selectedFaceX = msg.faceX ?? 0.5;
      _selectedFaceY = msg.faceY ?? 0.78;
    });
    _controller.text = msg.text;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    _focusNode.requestFocus();
  }

  /// Восстановить липкое оформление новых сообщений после выхода из правки.
  void _restoreStyleSnap() {
    if (!_hasStyleSnap) return;
    _selectedColor = _snapColor;
    _selectedFace = _snapFace;
    _selectedFaceX = _snapFaceX;
    _selectedFaceY = _snapFaceY;
    _hasStyleSnap = false;
  }

  /// Стабильный GlobalKey бабла [id] — чтобы перейти к оригиналу по тапу на
  /// цитату (через Scrollable.ensureVisible).
  GlobalKey _keyFor(String id) => _msgKeys.putIfAbsent(id, () => GlobalKey());

  /// Переход к оригинальному сообщению по тапу на цитату «в ответ на …».
  /// Если бабл уже на экране — доводим в зону видимости. Если укатился за экран
  /// (ListView его не построил) — прыгаем примерно к его позиции по индексу в
  /// ленте, затем доводим точно, когда бабл построится.
  void _scrollToMessage(String? id) {
    if (id == null || !_scrollController.hasClients) return;
    final ctx = _msgKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.35,
      );
      _flashHighlight(id);
      return;
    }
    // Не построен — оцениваем позицию по индексу сообщения и подскролливаем.
    final msgs = _lastMessages;
    final idx = msgs.indexWhere((m) => m.id == id);
    if (idx < 0) {
      HapticFeedback.lightImpact(); // не в загруженной ленте
      return;
    }
    final pos = _scrollController.position;
    final approx = (idx / msgs.length) * pos.maxScrollExtent;
    _scrollController
        .animateTo(
          approx.clamp(0.0, pos.maxScrollExtent),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
      // После прокрутки бабл уже должен быть построен — доводим точно.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _msgKeys[id]?.currentContext;
        if (c != null) {
          Scrollable.ensureVisible(
            c,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: 0.35,
          );
        }
        _flashHighlight(id);
      });
    });
  }

  /// Кратко подсветить сообщение [id] (после перехода — чтобы было заметно).
  void _flashHighlight(String id) {
    setState(() => _highlightMsgId = id);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted && _highlightMsgId == id) {
        setState(() => _highlightMsgId = null);
      }
    });
  }

  /// Кнопка ↻ в шапке — проиграть «влёт» сообщений заново. Меняем эпоху (ключи
  /// _EntranceSlide обновляются → перемонтаж → анимация с нуля) и открываем окно.
  // _replayEntrance удалён вместе с кнопкой ↻ в шапке (чат realtime).

  /// Имя варианта мордочки → enum (или null — без лица / неизвестно).
  _FaceExpr? _faceFromName(String? name) {
    if (name == null) return null;
    for (final e in _FaceExpr.values) {
      if (e.name == name) return e;
    }
    return null;
  }

  /// Оформление сообщения (цвет + мордочка + её позиция). Выбор липкий —
  /// держится для следующих сообщений, пока не сменишь.
  void _showStyleSheet() {
    showModalBottomSheet<_MsgStyle>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _t.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _StyleSheet(
        theme: _t,
        initialColor: _selectedColor,
        initialFace: _selectedFace,
        initialFx: _selectedFaceX,
        initialFy: _selectedFaceY,
        initialText: _controller.text,
        recent: _recentColors,
        // Превью повторяет настоящий пузырь: при правке — его форма/время,
        // у нового — текущее время (размер от времени одинаков — 5 символов).
        seed: _editing?.id.hashCode ?? 0,
        time: _formatTime(_editing?.ts ?? DateTime.now().millisecondsSinceEpoch),
        isEdited: _editing != null,
      ),
    ).then((result) {
      if (result == null || !mounted) return;
      setState(() {
        _selectedColor = result.color;
        _selectedFace = result.face;
        _selectedFaceX = result.fx;
        _selectedFaceY = result.fy;
        // Текст из превью — источник истины: что напечатали/правили в листе,
        // то и уходит в композер (двусторонняя синхронизация).
        if (result.text != _controller.text) {
          _controller.text = result.text;
          _controller.selection =
              TextSelection.collapsed(offset: _controller.text.length);
        }
        // Недавние (до 5), новый цвет первым (без дублей).
        final c = result.color;
        if (c != null) {
          _recentColors = [
            c,
            ..._recentColors.where((x) => x.toARGB32() != c.toARGB32()),
          ].take(5).toList();
          _chat.saveRecentColors(
              _recentColors.map((x) => x.toARGB32()).toList());
        }
      });
    });
  }

  void _startReply(ChatMsg msg) {
    HapticFeedback.mediumImpact();
    setState(() {
      _replyingTo = msg;
      _editing = null;
      _restoreStyleSnap();
    });
    _focusNode.requestFocus();
  }

  /// Пингуем «печатаю» не чаще раза в 3с; через 4с молчания — авто-сброс.
  void _emitTyping() {
    if (_controller.text.trim().isEmpty) {
      _stopTyping();
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastTypingPing).inSeconds >= 3) {
      _lastTypingPing = now;
      _chat.setTyping(_groupId, true);
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(seconds: 4), _stopTyping);
  }

  void _stopTyping() {
    _typingStopTimer?.cancel();
    _typingStopTimer = null;
    _lastTypingPing = DateTime.fromMillisecondsSinceEpoch(0);
    _chat.setTyping(_groupId, false);
  }

  Future<void> _confirmDelete(ChatMsg msg) async {
    final s = LocaleService.current;
    final ok = await AppDialog.confirm(
      context,
      message: s.chatDeleteConfirm(msg.text),
      confirmLabel: s.chatDeleteMessage,
      destructive: true,
    );
    if (ok) {
      await _chat.delete(groupId: _groupId, messageId: msg.id);
    }
  }

  void _openPin(String pinId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MemoryLaneScreen(
          pairData: widget.pairData,
          theme: _t,
          initialMemoryId: pinId,
          userData: widget.userData,
        ),
        settings: const RouteSettings(name: '/memory_lane'),
      ),
    );
  }

  // ── Фон чата ────────────────────────────────────────────────────────────────

  Future<void> _changeBackground() async {
    final s = LocaleService.current;
    final hasBg = _bgPath != null;

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _t.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _t.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      'assets/images/logo/logo.jpg',
                      width: 30,
                      height: 30,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    s.chatBgTitle,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.image_outlined, color: _t.primary),
              title: Text(hasBg ? s.chatBgChange : s.chatBgSet),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/images/icons/coin.webp',
                      width: 18, height: 18),
                  const SizedBox(width: 3),
                  Text('$_kChatBgPrice',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
              onTap: () => Navigator.pop(ctx, 'change'),
            ),
            if (hasBg)
              ListTile(
                leading: Icon(Icons.delete_outline_rounded,
                    color: Colors.red.shade400),
                title: Text(s.chatBgRemove),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (action == 'remove') {
      await _chat.clearBackground(_groupId);
      if (mounted) setState(() => _bgPath = null);
      return;
    }
    if (action != 'change') return;

    final ud = widget.userData;
    if (ud == null) return;

    if (ud.coins < _kChatBgPrice) {
      _toast(s.notEnoughCoins);
      return;
    }

    // Подтверждение с предупреждением о цене каждой смены.
    final confirmed = await AppDialog.confirm(
      context,
      title: s.chatBgTitle,
      message: s.chatBgConfirmBody(_kChatBgPrice),
      confirmLabel: s.buyThemeConfirm,
    );
    if (!confirmed) return;

    // Сначала выбираем фото — если пользователь отменит, списания не будет.
    final picked = await safePick(
      () => ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1600,
      ),
    );
    if (picked == null) return;

    // Списываем монеты на сервере (каждый раз).
    final ok = await ud.spendCoins(_kChatBgAction);
    if (!ok) {
      _toast(s.notEnoughCoins);
      return;
    }

    // Копируем во внутреннюю папку приложения, чтобы фон пережил очистку кэша.
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ext = picked.path.contains('.')
          ? picked.path.substring(picked.path.lastIndexOf('.'))
          : '.jpg';
      final dest =
          '${dir.path}/chat_bg_${_groupId}_${DateTime.now().millisecondsSinceEpoch}$ext';
      await File(picked.path).copy(dest);
      // Удаляем прежний фон-файл, чтобы не копить мусор.
      final old = _bgPath;
      await _chat.setBackgroundPath(_groupId, dest);
      if (old != null && old != dest) {
        try {
          final f = File(old);
          if (f.existsSync()) await f.delete();
        } catch (_) {}
      }
      if (mounted) {
        setState(() => _bgPath = dest);
        _toast(s.chatBgCharged);
      }
    } catch (e) {
      _toast(s.chatBgSaveFailed);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showMessageMenu(ChatMsg msg) {
    final s = LocaleService.current;
    showModalBottomSheet(
      context: context,
      backgroundColor: _t.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _t.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(Icons.reply_rounded, color: _t.primary),
              title: Text(s.chatReply),
              onTap: () {
                Navigator.pop(ctx);
                _startReply(msg);
              },
            ),
            if (msg.uid == _myUid) ...[
              ListTile(
                leading: Icon(Icons.edit_rounded, color: _t.primary),
                title: Text(s.chatEditMessage),
                onTap: () {
                  Navigator.pop(ctx);
                  _startEdit(msg);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline_rounded,
                    color: Colors.red.shade400),
                title: Text(s.chatDeleteMessage),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDelete(msg);
                },
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Набор системных эмодзи-реакций (тёплый, для пары).
  static const List<String> _reactionEmojis = [
    '❤️', '🥰', '😍', '😘', '😂', '🤗', '👍', '👏',
    '🔥', '🎉', '😮', '😢', '🙏', '💯', '😡', '👎',
  ];

  /// Пикер реакций (по двойному тапу). Тап по уже выбранному эмодзи — снимает.
  void _showReactionPicker(ChatMsg msg) {
    final mine = msg.reactions[_myUid];
    showModalBottomSheet(
      context: context,
      backgroundColor: _t.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _t.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final e in _reactionEmojis)
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        _chat.setReaction(
                          groupId: _groupId,
                          messageId: msg.id,
                          emoji: mine == e ? null : e,
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: mine == e
                              ? _t.primary.withOpacity(0.18)
                              : Colors.transparent,
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 30)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Баннер «В ответ {имя}» над полем ввода (двухстрочный, как в Telegram).
  Widget _buildReplyComposerBanner(AppStrings s) {
    final r = _replyingTo!;
    final preview = r.deleted
        ? s.chatDeletedPlaceholder
        : (r.text.isNotEmpty ? r.text : (r.pinTitle ?? '📌'));
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: _t.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.reply_rounded, color: _t.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.chatReplyingTo(r.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _t.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _t.textSecondary, fontSize: 12.5),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded,
                color: _t.textMuted, size: 20),
            onPressed: () => setState(() => _replyingTo = null),
          ),
        ],
      ),
    );
  }

  /// Цитата «в ответ на …» внутри бабла (имя + снимок текста оригинала).
  Widget _buildReplyQuote(ChatMsg msg, bool isMine) {
    final accent = isMine ? Colors.white : _t.primary;
    final nameColor = isMine ? Colors.white : _t.primary;
    final textColor =
        isMine ? Colors.white.withOpacity(0.85) : _t.textSecondary;
    // Тап по цитате — переход к оригинальному сообщению (если оно в ленте).
    return GestureDetector(
      onTap: () => _scrollToMessage(msg.replyToId),
      child: Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: accent.withOpacity(0.8)),
            const SizedBox(width: 6),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    msg.replyToName ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: nameColor,
                    ),
                  ),
                  Text(
                    msg.replyToText ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: textColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// Чипы-реакции СБОКУ от бабла (вертикальной стопкой, со стороны центра).
  /// Тап по своей реакции снимает её, по чужой — ставит такую же себе.
  /// Белая пилюля с рамкой/тенью; своя реакция — акцентная заливка.
  Widget _buildReactionChips(ChatMsg msg, bool isMine) {
    final counts = <String, int>{};
    for (final e in msg.reactions.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    if (counts.isEmpty) return const SizedBox.shrink();
    final mine = msg.reactions[_myUid];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        for (final entry in counts.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: GestureDetector(
              onTap: () => _chat.setReaction(
                groupId: _groupId,
                messageId: msg.id,
                emoji: mine == entry.key ? null : entry.key,
              ),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: mine == entry.key
                      ? _t.primary.withOpacity(0.14)
                      : _t.cardSurface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color:
                        mine == entry.key ? _t.primary : _t.divider,
                    width: mine == entry.key ? 1.5 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(entry.key, style: const TextStyle(fontSize: 14)),
                    if (entry.value > 1) ...[
                      const SizedBox(width: 3),
                      Text(
                        '${entry.value}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: mine == entry.key
                              ? _t.primary
                              : _t.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _formatTime(int ts) {
    if (ts <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Хедер чата: аватар партнёра с точкой онлайн + имя с сердечком + статус
  /// «в сети · печатает…». Presence и «печатает» — живые стримы.
  Widget _buildHeaderTitle(AppStrings s) {
    final name = widget.pairData.partnerDisplayName;
    return StreamBuilder<bool>(
      stream: PresenceService().watchOnline(widget.pairData.partnerUid),
      builder: (context, presSnap) {
        final online = presSnap.data == true;
        final hasPres = presSnap.hasData;
        return Row(
          children: [
            _headerAvatar(online),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.favorite_border_rounded,
                          size: 13, color: _t.primary),
                    ],
                  ),
                  // Статус: «печатает…» (анимированный) приоритетнее presence.
                  StreamBuilder<bool>(
                    stream: _chat.watchTyping(_groupId),
                    builder: (context, tSnap) {
                      final typing = tSnap.data == true;
                      if (typing) {
                        return _TypingStatus(
                          prefix: online ? '${s.chatOnline} · ' : '',
                          label: s.chatTypingShort,
                          color: _t.primary,
                        );
                      }
                      final text =
                          online ? s.chatOnline : (hasPres ? s.offline : '');
                      return Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: online ? _t.primary : _t.textMuted,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Круглый аватар партнёра (картинка или буква-инициал) с зелёной точкой
  /// «онлайн» в правом нижнем углу.
  Widget _headerAvatar(bool online) {
    final url = widget.pairData.partnerAvatarUrl;
    final name = widget.pairData.partnerDisplayName.trim();
    final initial = name.firstGraphemeUpper('♥');
    final fallback = Container(
      color: _t.primary.withOpacity(0.15),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: _t.primary,
          fontWeight: FontWeight.w800,
          fontSize: 16,
        ),
      ),
    );
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipOval(
            child: SizedBox(
              width: 38,
              height: 38,
              child: url.isEmpty
                  ? fallback
                  : StorageImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      memCacheWidth: 120,
                      memCacheHeight: 120,
                      errorWidget: (_, _, _) => fallback,
                    ),
            ),
          ),
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: const Color(0xFF4CAF50),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    return Scaffold(
      backgroundColor: _t.bgGradient.last,
      appBar: AppBar(
        backgroundColor: _t.cardSurface,
        elevation: 0.5,
        foregroundColor: _t.textPrimary,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded, size: 30),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        // Аватар партнёра + имя с сердечком + статус «в сети · печатает…».
        title: _buildHeaderTitle(s),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz_rounded, color: _t.textSecondary),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            onSelected: (v) {
              if (v == 'bg') _changeBackground();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem<String>(
                value: 'bg',
                child: Row(
                  children: [
                    Icon(Icons.wallpaper_rounded, color: _t.primary, size: 20),
                    const SizedBox(width: 10),
                    Text(s.chatBgTitle),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          // Свой фон чата (локальный, у каждого свой).
          if (_bgPath != null)
            Positioned.fill(
              child: Image.file(
                File(_bgPath!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          // Лёгкая вуаль для читаемости пузырей поверх любого фото.
          if (_bgPath != null)
            Positioned.fill(
              child: Container(color: Colors.black.withOpacity(0.06)),
            ),
          Column(
            children: [
              Expanded(
            child: Stack(
              children: [
                StreamBuilder<List<ChatMsg>>(
              stream: _messagesStream,
              builder: (context, snap) {
                // Во время пересоздания потока (пагинация) держим прошлый срез.
                if (snap.data != null) _lastMessages = snap.data!;
                final messages = snap.data ?? _lastMessages;
                if (messages.isNotEmpty) {
                  _lastMessageTs = messages.last.ts;
                  _lastIsMine = messages.last.uid == _myUid;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _chat.markRead(_groupId, _lastMessageTs);
                  });
                }
                // Меньше, чем просили → достигли начала истории.
                _hasMore = messages.length >= _limit;

                if (snap.connectionState == ConnectionState.waiting &&
                    messages.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (messages.isEmpty) {
                  return Center(
                    child: Text(
                      s.chatEmpty,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _t.textMuted),
                    ),
                  );
                }
                // Без своего uid выравнивание «моё/чужое» неверно — ВСЕ пузыри
                // уехали бы на одну сторону. Если PocketBase ещё не отдал
                // userId (восстановление сессии), ждём, а не рисуем криво.
                if (_myUid.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }

                final items = _buildItems(messages);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _afterMessagesLayout();
                });
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
                  itemCount: items.length,
                  itemBuilder: (context, i) =>
                      _buildItem(items[i], i, items.length),
                );
              },
                ),
                // FAB «вниз» — в области списка, НАД композером (не перекрывает
                // кнопку отправки). Виден, когда отлистали заметно вверх.
                Positioned(
                  right: 14,
                  bottom: 8,
                  child: IgnorePointer(
                    ignoring: !_showScrollDown,
                    child: AnimatedScale(
                      scale: _showScrollDown ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: GestureDetector(
                        onTap: _jumpToBottom,
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: _t.cardSurface,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.15),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: _t.primary,
                            size: 26,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
              if (_mentionQuery != null && _mentionResults.isNotEmpty)
                _buildMentionList(),
              // «Печатает…» теперь в хедере (см. _buildHeaderTitle).
              _buildComposer(s),
            ],
          ),
        ],
      ),
    );
  }

  /// Превращает плоский список сообщений в список элементов с разделителями:
  /// заголовки дат (как в Telegram) и маркер «Новые сообщения».
  List<Object> _buildItems(List<ChatMsg> messages) {
    final items = <Object>[];
    DateTime? lastDay;
    bool unreadShown = false;
    for (final m in messages) {
      final d = DateTime.fromMillisecondsSinceEpoch(m.ts);
      final day = DateTime(d.year, d.month, d.day);
      if (lastDay == null || day != lastDay) {
        items.add(_DateHeader(day));
        lastDay = day;
      }
      // Разделитель — над первым непрочитанным сообщением партнёра.
      if (!unreadShown &&
          _openLastRead > 0 &&
          m.ts > _openLastRead &&
          m.uid != _myUid) {
        items.add(const _UnreadMarker());
        unreadShown = true;
      }
      items.add(m);
    }
    _hasUnreadMarker = unreadShown;
    return items;
  }

  Widget _buildItem(Object item, int index, int total) {
    if (item is _DateHeader) return _buildDateHeader(item.day);
    if (item is _UnreadMarker) return _buildUnreadMarker();
    final msg = item as ChatMsg;
    // Влёт со стороны при открытии чата: своё — справа, партнёр — слева.
    // Только для изначально видимых (пока открыто окно _playEntrance); при
    // скролле сообщения появляются без анимации. Стаггер — снизу вверх.
    // Эпоха в ключе → кнопка ↻ перезапускает анимацию.
    return _EntranceSlide(
      key: ValueKey('enter_${msg.id}_$_entranceEpoch'),
      fromRight: msg.uid == _myUid,
      animate: _playEntrance,
      delay: Duration(milliseconds: (total - 1 - index).clamp(0, 6) * 60),
      child: _buildBubble(msg),
    );
  }

  Widget _buildDateHeader(DateTime day) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          LocaleService.current.chatDateHeader(day),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildUnreadMarker() {
    return Container(
      key: _unreadKey,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(vertical: 4),
      color: _t.primary.withOpacity(0.12),
      child: Center(
        child: Text(
          LocaleService.current.chatNewMessages,
          style: TextStyle(
            color: _t.primary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(ChatMsg msg) {
    final isMine = msg.uid == _myUid;
    final s = LocaleService.current;
    final seed = msg.id.hashCode;

    // Цвет пузыря: выбранный автором (msg.color) приоритетнее. Иначе — тема:
    // своё — насыщенный primary, партнёр — пастельный тон. Текст/лицо — авто-
    // контраст по яркости фона (белый на тёмном, тёмный на светлом).
    final Color bg;
    if (msg.deleted) {
      bg = _t.isDark ? _t.surfaceMuted : Colors.grey.shade300;
    } else if (msg.color != null) {
      bg = Color(msg.color!);
    } else if (isMine) {
      bg = _t.primary;
    } else {
      bg = _t.isDark
          ? _t.cardSurface
          : Color.lerp(_t.primary, Colors.white, 0.62)!;
    }
    final fg = msg.deleted
        ? _t.textSecondary
        : (bg.computeLuminance() > 0.55 ? _t.textPrimary : Colors.white);
    final metaColor = fg.withOpacity(0.65);

    // Кривые углы + лёгкий наклон (детерминированный псевдо-рандом по id —
    // стабильно между кадрами, двух одинаковых пузырей нет).
    final corners = BorderRadius.only(
      topLeft: Radius.circular(15 + _seededUnit(seed, 1) * 17),
      topRight: Radius.circular(15 + _seededUnit(seed, 2) * 17),
      bottomLeft: Radius.circular(15 + _seededUnit(seed, 3) * 17),
      bottomRight: Radius.circular(15 + _seededUnit(seed, 4) * 17),
    );
    final tilt = (_seededUnit(seed, 5) - 0.5) * 0.045; // ±~1.3°
    // Выражение мордочки — то, что ВЫБРАЛ отправитель (msg.face). Нет → без лица.
    final expr = _faceFromName(msg.face);

    // Сообщение из одних эмодзи (1–3) рисуем крупно и БЕЗ пузыря (как в
    // мессенджерах). Не трогаем удалённые, с пином, ответом или своей мордочкой.
    final double? bigEmoji = (msg.deleted ||
            msg.pinId != null ||
            msg.replyToId != null ||
            expr != null)
        ? null
        : _emojiOnlySize(msg.text);

    Widget content;
    if (msg.deleted) {
      content = Text(
        s.chatDeletedPlaceholder,
        style: TextStyle(color: fg, fontStyle: FontStyle.italic, fontSize: 14),
      );
    } else if (bigEmoji != null) {
      // Крупные эмодзи + мета снизу. Цвета меты — серые (фон-то не пузырь).
      final meta = _t.textMuted;
      content = Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(msg.text, style: TextStyle(fontSize: bigEmoji, height: 1.05)),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (msg.isEdited) ...[
                Text(s.chatEdited,
                    style: TextStyle(
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                        color: meta)),
                const SizedBox(width: 5),
              ],
              Text(_formatTime(msg.editedTs ?? msg.ts),
                  style: TextStyle(fontSize: 10, color: meta)),
              if (isMine) ...[
                const SizedBox(width: 4),
                Icon(
                  msg.ts <= _partnerReadTs
                      ? Icons.done_all_rounded
                      : Icons.done_rounded,
                  size: 14,
                  color: msg.ts <= _partnerReadTs ? _t.primary : meta,
                ),
              ],
            ],
          ),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (msg.replyToId != null) _buildReplyQuote(msg, isMine),
          if (msg.pinId != null) _buildPinChip(msg, isMine),
          if (msg.text.isNotEmpty)
            MdMessageText(
              msg.text,
              style: TextStyle(color: fg, fontSize: 15, height: 1.25),
            ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (msg.isEdited) ...[
                Text(
                  s.chatEdited,
                  style: TextStyle(
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                    color: metaColor,
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Text(
                _formatTime(msg.editedTs ?? msg.ts),
                style: TextStyle(fontSize: 10, color: metaColor),
              ),
              if (isMine && !msg.deleted) ...[
                const SizedBox(width: 4),
                Icon(
                  msg.ts <= _partnerReadTs
                      ? Icons.done_all_rounded
                      : Icons.done_rounded,
                  size: 14,
                  color: msg.ts <= _partnerReadTs
                      ? const Color(0xFF8FD3FF)
                      : metaColor,
                ),
              ],
            ],
          ),
        ],
      );
    }

    const tailDrop = 9.0;
    final hasReactions = msg.reactions.isNotEmpty;

    final Widget tilted;
    if (bigEmoji != null) {
      // Крупные эмодзи без пузыря: тот же тап-таргет (двойной тап — реакция,
      // долгий — меню), но без фона/хвоста/наклона.
      tilted = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => _showReactionPicker(msg),
        onLongPress: () => _showMessageMenu(msg),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: content,
        ),
      );
    } else {
      // Пузырь: форма (кривые углы + хвостик-клювик со стороны отправителя)
      // рисуется painter'ом, текст/лицо — поверх. Тап — реакции, долгое — меню.
      final core = CustomPaint(
        painter: _BubblePainter(
          color: bg,
          corners: corners,
          tailLeft: !isMine,
          tailDrop: tailDrop,
        ),
        child: Container(
          constraints: BoxConstraints(
            maxWidth:
                MediaQuery.of(context).size.width * (hasReactions ? 0.6 : 0.72),
          ),
          // С мордочкой — заметно больше воздуха вокруг текста, чтобы лицу было
          // куда встать; без неё — компактно (низ = padding + tailDrop 9).
          padding: expr == null
              ? const EdgeInsets.fromLTRB(14, 10, 14, 19)
              : const EdgeInsets.fromLTRB(18, 22, 18, 31),
          child: content,
        ),
      );
      final bubble = GestureDetector(
        onDoubleTap: msg.deleted ? null : () => _showReactionPicker(msg),
        onLongPress: msg.deleted ? null : () => _showMessageMenu(msg),
        // Мордочка — оверлеем в выбранной автором позиции (доли 0..1), по
        // умолчанию низ-центр. IgnorePointer — чтобы не перехватывала тапы.
        child: expr == null
            ? core
            : Stack(
                children: [
                  core,
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment(
                        (msg.faceX ?? 0.5) * 2 - 1,
                        (msg.faceY ?? 0.78) * 2 - 1,
                      ),
                      child: IgnorePointer(
                        child: CustomPaint(
                          size: const Size(30, 16),
                          painter: _FacePainter(color: fg, expr: expr),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      );

      // Лёгкий наклон — «криво расположены».
      tilted = Transform.rotate(angle: tilt, child: bubble);
    }

    // Реакции — сбоку (со стороны центра).
    final chips = hasReactions ? _buildReactionChips(msg, isMine) : null;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: isMine
          ? [
              if (chips != null) ...[chips, const SizedBox(width: 6)],
              Flexible(child: tilted),
            ]
          : [
              Flexible(child: tilted),
              if (chips != null) ...[const SizedBox(width: 6), chips],
            ],
    );

    return _SwipeToReply(
      key: ValueKey('swipe_${msg.id}'),
      enabled: !msg.deleted,
      iconColor: _t.primary,
      onReply: () => _startReply(msg), // вибрация — внутри _startReply
      child: AnimatedContainer(
        // Ключ — для перехода по цитате + подсветки. Спокойные отступы между
        // пузырями (без налезания).
        key: _keyFor(msg.id),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: _highlightMsgId == msg.id
              ? _t.primary.withOpacity(0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Align(
          alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
          child: row,
        ),
      ),
    );
  }

  /// URL миниатюры пина: обложка для музыки/книги, кадр/фото для остального.
  String? _memoryThumb(Memory m) {
    if (m.type == MemoryType.music) return m.musicCoverUrl;
    if (m.type == MemoryType.book) return m.bookCoverUrl;
    if (m.type == MemoryType.movie) return m.moviePosterUrl;
    return m.imageUrl ??
        (m.imageUrls?.isNotEmpty == true ? m.imageUrls!.first : null);
  }

  /// Квадратная миниатюра пина: картинка по [thumb], иначе [emoji].
  Widget _pinThumbView({
    required String? thumb,
    required String emoji,
    required double size,
    double radius = 6,
    double emojiSize = 20,
  }) {
    final fallback = Center(
      child: Text(emoji, style: TextStyle(fontSize: emojiSize)),
    );
    if (thumb == null || thumb.isEmpty) {
      return SizedBox(width: size, height: size, child: fallback);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: StorageImage(
          imageUrl: thumb,
          fit: BoxFit.cover,
          memCacheWidth: 120,
          memCacheHeight: 120,
          errorWidget: (_, _, _) => fallback,
        ),
      ),
    );
  }

  /// Чип прикреплённого пина внутри сообщения — с миниатюрой предпросмотра.
  Widget _buildPinChip(ChatMsg msg, bool isMine) {
    // Миниатюра: из самого сообщения, иначе ищем пин в загруженном списке.
    Memory? mem;
    for (final p in _pins) {
      if (p.id == msg.pinId) {
        mem = p;
        break;
      }
    }
    final thumb = msg.pinThumb ?? (mem != null ? _memoryThumb(mem) : null);
    final emoji = mem?.typeEmoji ?? '📌';
    return GestureDetector(
      onTap: () => _openPin(msg.pinId!),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: isMine ? Colors.white.withOpacity(0.20) : _t.primaryLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pinThumbView(
              thumb: thumb,
              emoji: emoji,
              size: 36,
              radius: 8,
              emojiSize: 18,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                msg.pinTitle ?? 'Pin',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: isMine ? Colors.white : _t.primary,
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildMentionList() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      color: _t.cardSurface,
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: _mentionResults.map((m) {
          return ListTile(
            dense: true,
            leading: _pinThumbView(
              thumb: _memoryThumb(m),
              emoji: m.typeEmoji,
              size: 40,
            ),
            title: Text(
              _memoryLabel(m),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(m.typeLabel,
                style: TextStyle(fontSize: 11, color: _t.textMuted)),
            onTap: () => _selectMention(m),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildComposer(AppStrings s) {
    return Container(
      decoration: BoxDecoration(
        color: _t.cardSurface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      // Когда клавиатура открыта, Scaffold уже поднимает композер над ней —
      // добавлять инсет системной навигации не нужно (иначе двойной отступ
      // и большой зазор между полем и клавиатурой).
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 +
            (MediaQuery.of(context).viewInsets.bottom > 0
                ? 0
                : MediaQuery.of(context).viewPadding.bottom),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Баннеры (ответ/редактирование/пин) появляются и схлопываются плавно.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_replyingTo != null) _buildReplyComposerBanner(s),
                if (_editing != null)
                  _buildBanner(
                    icon: Icons.edit_rounded,
                    label: '${s.chatEditMessage}: ${_editing!.text}',
                    onClose: () {
                      setState(() {
                        _editing = null;
                        _restoreStyleSnap();
                      });
                      _controller.clear();
                    },
                  ),
                if (_attachedPin != null)
                  _buildBanner(
                    icon: Icons.push_pin_rounded,
                    label: _memoryLabel(_attachedPin!),
                    onClose: () => setState(() => _attachedPin = null),
                  ),
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Прикрепить пин — вставляет '@' и открывает подсказки
              GestureDetector(
                onTap: _triggerPinPicker,
                child: Container(
                  width: 40,
                  height: 44,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.push_pin_rounded,
                    color: _t.primary,
                    size: 22,
                  ),
                ),
              ),
              // Оформление сообщения: цвет + мордочка + её позиция (выбор автора).
              GestureDetector(
                onTap: _showStyleSheet,
                child: Container(
                  width: 40,
                  height: 44,
                  alignment: Alignment.center,
                  child: Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _selectedColor ?? _t.primary,
                      shape: BoxShape.circle,
                    ),
                    child: _selectedFace == null
                        ? null
                        : CustomPaint(
                            size: const Size(20, 12),
                            painter: _FacePainter(
                              color: (_selectedColor ?? _t.primary)
                                          .computeLuminance() >
                                      0.55
                                  ? _t.textPrimary
                                  : Colors.white,
                              expr: _selectedFace!,
                            ),
                          ),
                  ),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: s.chatHint,
                    hintMaxLines: 1,
                    filled: true,
                    fillColor: _t.surfaceMuted,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 11),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _send,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _t.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _editing != null
                        ? Icons.check_rounded
                        : Icons.send_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBanner({
    required IconData icon,
    required String label,
    required VoidCallback onClose,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: _t.primaryLight,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: _t.primary, width: 3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: _t.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: _t.textSecondary),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            color: _t.textMuted,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Элемент-разделитель: заголовок даты в ленте чата.
class _DateHeader {
  final DateTime day;
  const _DateHeader(this.day);
}

/// Элемент-разделитель: маркер «Новые сообщения».
class _UnreadMarker {
  const _UnreadMarker();
}

/// Форма пузыря: прямоугольник с кривыми (детерминированными) углами + хвостик-
/// клювик, свисающий из нижнего угла со стороны отправителя (левый бабл → слева,
/// правый → справа). Плоская заливка, без тени.
class _BubblePainter extends CustomPainter {
  final Color color;
  final BorderRadius corners;
  final bool tailLeft;
  final double tailDrop;
  const _BubblePainter({
    required this.color,
    required this.corners,
    required this.tailLeft,
    required this.tailDrop,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bodyH = size.height - tailDrop;
    final body = Path()
      ..addRRect(RRect.fromRectAndCorners(
        Rect.fromLTWH(0, 0, size.width, bodyH),
        topLeft: corners.topLeft,
        topRight: corners.topRight,
        bottomLeft: corners.bottomLeft,
        bottomRight: corners.bottomRight,
      ));
    final tail = Path();
    final by = bodyH;
    if (tailLeft) {
      final cx = corners.bottomLeft.x.clamp(8.0, 26.0);
      tail.moveTo(cx, by - 5);
      tail.quadraticBezierTo(2, by + tailDrop, cx + 11, by);
      tail.close();
    } else {
      final cx = size.width - corners.bottomRight.x.clamp(8.0, 26.0);
      tail.moveTo(cx, by - 5);
      tail.quadraticBezierTo(size.width - 2, by + tailDrop, cx - 11, by);
      tail.close();
    }
    final full = Path.combine(PathOperation.union, body, tail);
    canvas.drawPath(
      full,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.color != color ||
      old.corners != corners ||
      old.tailLeft != tailLeft ||
      old.tailDrop != tailDrop;
}

/// Милая мордочка под текстом: две точки-глаза + выражение рта (в тон текста).
/// Влюблённость добавляет щёчки, подмигивание — глаз-чёрточку, playful — язычок.
class _FacePainter extends CustomPainter {
  final Color color;
  final _FaceExpr expr;
  const _FacePainter({required this.color, required this.expr});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final fill = Paint()
      ..color = color
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final eyeY = h * 0.30;
    final lx = w * 0.30;
    final rx = w * 0.70;

    // Глаза.
    canvas.drawCircle(Offset(lx, eyeY), 1.8, fill);
    if (expr == _FaceExpr.wink) {
      canvas.drawLine(Offset(rx - 3, eyeY), Offset(rx + 3, eyeY), stroke);
    } else {
      canvas.drawCircle(Offset(rx, eyeY), 1.8, fill);
    }

    // Щёчки у влюблённости.
    if (expr == _FaceExpr.love) {
      final cheek = Paint()..color = const Color(0xFFFF7A93).withOpacity(0.55);
      canvas.drawCircle(Offset(lx - 4, h * 0.58), 2.4, cheek);
      canvas.drawCircle(Offset(rx + 4, h * 0.58), 2.4, cheek);
    }

    // Рот.
    final my = h * 0.64;
    final mouth = Path();
    switch (expr) {
      case _FaceExpr.happy:
      case _FaceExpr.love:
        mouth.moveTo(w * 0.40, my);
        mouth.quadraticBezierTo(w * 0.50, my + 4.5, w * 0.60, my);
        canvas.drawPath(mouth, stroke);
        break;
      case _FaceExpr.wink:
        mouth.moveTo(w * 0.42, my);
        mouth.quadraticBezierTo(w * 0.50, my + 3.5, w * 0.58, my);
        canvas.drawPath(mouth, stroke);
        break;
      case _FaceExpr.playful:
        canvas.drawCircle(Offset(w * 0.50, my + 1), 2.4, fill);
        break;
      case _FaceExpr.sad:
        mouth.moveTo(w * 0.40, my + 3);
        mouth.quadraticBezierTo(w * 0.50, my - 2, w * 0.60, my + 3);
        canvas.drawPath(mouth, stroke);
        break;
      case _FaceExpr.calm:
        mouth.moveTo(w * 0.43, my + 1);
        mouth.lineTo(w * 0.57, my + 1);
        canvas.drawPath(mouth, stroke);
        break;
    }
  }

  @override
  bool shouldRepaint(_FacePainter old) =>
      old.color != color || old.expr != expr;
}

/// Влёт сообщения со своей стороны при открытии чата: горизонтальный сдвиг
/// от края к месту (FractionalTranslation — на свою ширину) + проявление.
/// Анимация одноразовая; при [animate]=false бабл сразу на месте (скролл/новые).
class _EntranceSlide extends StatefulWidget {
  final Widget child;
  final bool fromRight; // своё влетает справа, партнёра — слева
  final bool animate;
  final Duration delay;
  const _EntranceSlide({
    super.key,
    required this.child,
    required this.fromRight,
    required this.animate,
    required this.delay,
  });

  @override
  State<_EntranceSlide> createState() => _EntranceSlideState();
}

class _EntranceSlideState extends State<_EntranceSlide>
    with SingleTickerProviderStateMixin {
  // Контроллер создаётся ТОЛЬКО когда нужна анимация — при скролле/новых
  // сообщениях (animate=false) виджет показан сразу, без тикера.
  AnimationController? _c;
  Animation<double>? _t;

  @override
  void initState() {
    super.initState();
    if (!widget.animate) return;
    final c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _c = c;
    _t = CurvedAnimation(parent: c, curve: Curves.easeOutCubic);
    Future.delayed(widget.delay, () {
      if (mounted) c.forward();
    });
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (t == null) return widget.child; // без анимации — сразу на месте
    return AnimatedBuilder(
      animation: t,
      builder: (_, child) {
        final p = 1 - t.value; // 1 → 0 по ходу анимации
        final dx = p * (widget.fromRight ? 1.0 : -1.0);
        // Лёгкий поворот вокруг «своей стены» — сообщение как бы выезжает из неё.
        final angle = p * (widget.fromRight ? 0.05 : -0.05);
        return Transform.rotate(
          angle: angle,
          alignment:
              widget.fromRight ? Alignment.centerRight : Alignment.centerLeft,
          child: FractionalTranslation(
            translation: Offset(dx, 0),
            child: Opacity(opacity: t.value.clamp(0.0, 1.0), child: child),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Анимированный статус «печатает…» в хедере: к слову циклично добавляются
/// 1→3 точки. [prefix] — напр. «в сети · » (или пусто), [label] — «печатает».
class _TypingStatus extends StatefulWidget {
  final String prefix;
  final String label;
  final Color color;
  const _TypingStatus({
    required this.prefix,
    required this.label,
    required this.color,
  });

  @override
  State<_TypingStatus> createState() => _TypingStatusState();
}

class _TypingStatusState extends State<_TypingStatus>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final n = 1 + (_c.value * 3).floor().clamp(0, 2); // 1..3 точки
        return Text(
          '${widget.prefix}${widget.label}${'.' * n}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: widget.color,
          ),
        );
      },
    );
  }
}

/// Свайп-влево по сообщению, чтобы ответить (как в Telegram).
///
/// Резисторный свайп: бабл визуально сдвигается максимум на [_kMaxVisual] px и
/// НЕ уезжает по экрану — сколько бы ни тянули. Срабатывание ответа привязано к
/// реальному ходу пальца ([_kTriggerRaw] px), а не к смещению бабла, поэтому
/// случайный короткий свайп не триггерит. По отпусканию — плавный пружинный
/// возврат на место. Иконка ответа справа проявляется/растёт по ходу свайпа.
class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final VoidCallback onReply;
  final Color iconColor;
  const _SwipeToReply({
    super.key,
    required this.child,
    required this.enabled,
    required this.onReply,
    required this.iconColor,
  });

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  // Бабл визуально сдвигается максимум на столько px (rubber-band асимптота).
  static const double _kMaxVisual = 22;
  // Сколько пройти пальцем влево (px), чтобы сработал ответ.
  static const double _kTriggerRaw = 64;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final Animation<double> _curve =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);

  double _raw = 0; // накопленный ход пальца влево, >= 0
  double _springFrom = 0; // с какого _raw начался пружинный возврат
  bool _armed = false; // достигнут ли порог ответа

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      setState(() => _raw = _springFrom * (1 - _curve.value));
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Смещение бабла: rubber-band — растёт всё медленнее, упираясь в _kMaxVisual.
  double get _visual => -_kMaxVisual * (_raw / (_raw + _kMaxVisual));

  void _onStart(DragStartDetails _) => _ctrl.stop();

  void _onUpdate(DragUpdateDetails d) {
    final next = (_raw - d.primaryDelta!).clamp(0.0, 400.0);
    final crossed = next >= _kTriggerRaw;
    if (crossed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _raw = next;
      _armed = crossed;
    });
  }

  void _onEnd(DragEndDetails _) {
    if (_armed) widget.onReply();
    _armed = false;
    _springFrom = _raw;
    _ctrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    // Стрелка-иконка ответа убрана по требованию — остаётся сам свайп с лёгким
    // сдвигом пузыря и срабатыванием ответа по достижении порога.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onStart,
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      child: Transform.translate(
        offset: Offset(_visual, 0),
        child: widget.child,
      ),
    );
  }
}

/// Результат листа оформления сообщения.
class _MsgStyle {
  final Color? color; // null — цвет темы
  final _FaceExpr? face;
  final double fx;
  final double fy;
  final String text; // текст из превью (правится прямо в листе)
  const _MsgStyle(this.color, this.face, this.fx, this.fy, this.text);
}

/// Лист «оформление сообщения»: HSV-пикер цвета (любой оттенок) + 5 недавних +
/// выбор мордочки + перетаскивание её позиции на превью пузыря.
class _StyleSheet extends StatefulWidget {
  final AppTheme theme;
  final Color? initialColor;
  final _FaceExpr? initialFace;
  final double initialFx;
  final double initialFy;
  final String initialText;
  final List<Color> recent;
  // Для точного совпадения превью с настоящим пузырём: сид формы (углы+наклон),
  // время в мете и флаг «изменено».
  final int seed;
  final String time;
  final bool isEdited;
  const _StyleSheet({
    required this.theme,
    required this.initialColor,
    required this.initialFace,
    required this.initialFx,
    required this.initialFy,
    required this.initialText,
    required this.recent,
    required this.seed,
    required this.time,
    required this.isEdited,
  });

  @override
  State<_StyleSheet> createState() => _StyleSheetState();
}

class _StyleSheetState extends State<_StyleSheet> {
  late HSVColor _hsv;
  late bool _useTheme; // true → цвет темы (color = null)
  late _FaceExpr? _face;
  late double _fx;
  late double _fy;
  late final TextEditingController _textCtrl;
  // Ключ пузыря-превью — чтобы перевести глобальные координаты перетаскивания
  // мордочки в доли 0..1 (мордочка тащится поверх редактируемого текста).
  final GlobalKey _bubbleKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _useTheme = widget.initialColor == null;
    _hsv = HSVColor.fromColor(widget.initialColor ?? widget.theme.primary);
    _face = widget.initialFace;
    _fx = widget.initialFx;
    _fy = widget.initialFy;
    _textCtrl = TextEditingController(text: widget.initialText);
    // Пузырь меряется по содержимому (TextPainter) — пересчитываем на каждый
    // ввод, чтобы ширина/перенос совпадали с настоящим сообщением вживую.
    _textCtrl.addListener(_onTextChanged);
  }

  void _onTextChanged() => setState(() {});

  @override
  void dispose() {
    _textCtrl.removeListener(_onTextChanged);
    _textCtrl.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor();
  Color get _bg => _useTheme ? widget.theme.primary : _color;
  Color get _fg =>
      _bg.computeLuminance() > 0.55 ? widget.theme.textPrimary : Colors.white;

  Widget _thumb() => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: widget.theme.isDark ? widget.theme.cardSurface : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
              color: widget.theme.isDark
                  ? widget.theme.cardBorder
                  : Colors.black26),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
        ),
      );

  Widget _circleBtn({
    required bool selected,
    required VoidCallback onTap,
    required Widget child,
  }) {
    final accent = widget.theme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? accent.withOpacity(0.12) : widget.theme.surfaceMuted,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? accent : widget.theme.divider,
            width: selected ? 2 : 1,
          ),
        ),
        child: child,
      ),
    );
  }

  Widget _label(String t) => Align(
        alignment: Alignment.centerLeft,
        child: Text(t,
            style: TextStyle(
                fontWeight: FontWeight.w700, color: widget.theme.textPrimary)),
      );

  Widget _preview() {
    // Перетаскивание мордочки: глобальная точка → доли 0..1 от РЕАЛЬНОГО размера
    // пузыря (он обнимает текст, размер плавающий — берём его из RenderBox).
    void moveFace(Offset global) {
      final box = _bubbleKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return;
      final p = box.globalToLocal(global);
      final sz = box.size;
      setState(() {
        _fx = (p.dx / sz.width).clamp(0.0, 1.0);
        _fy = (p.dy / sz.height).clamp(0.0, 1.0);
      });
    }

    // Та же геометрия, что у настоящего пузыря: кривые углы + наклон по сиду.
    final seed = widget.seed;
    final corners = BorderRadius.only(
      topLeft: Radius.circular(15 + _seededUnit(seed, 1) * 17),
      topRight: Radius.circular(15 + _seededUnit(seed, 2) * 17),
      bottomLeft: Radius.circular(15 + _seededUnit(seed, 3) * 17),
      bottomRight: Radius.circular(15 + _seededUnit(seed, 4) * 17),
    );
    final tilt = (_seededUnit(seed, 5) - 0.5) * 0.045;
    final metaColor = _fg.withOpacity(0.65);
    final s = LocaleService.current;
    const tailDrop = 9.0;
    final maxW = MediaQuery.of(context).size.width * 0.72;

    // Текст меряем РОВНО как настоящий пузырь (тот же стиль, тот же потолок
    // ширины и тот же textScaler) — и задаём полю эту точную ширину. Так перенос
    // строк и итоговая ширина пузыря совпадают 1:1 с отправленным сообщением,
    // а раз размер совпал — мордочка (доля от размера) встаёт туда же.
    // Шрифт наследуем из темы (как настоящий Text — он берёт Rubik из textTheme).
    // Иначе TextPainter/поле мерили бы дефолтным Roboto и ширина не совпала бы.
    final textStyle = DefaultTextStyle.of(context)
        .style
        .merge(TextStyle(color: _fg, fontSize: 15, height: 1.25));
    // Те же отступы, что у настоящего пузыря: с мордочкой — просторнее.
    final bubblePad = _face == null
        ? const EdgeInsets.fromLTRB(14, 10, 14, 19)
        : const EdgeInsets.fromLTRB(18, 22, 18, 31);
    final contentMaxW = maxW - (bubblePad.left + bubblePad.right);
    // Пусто → меряем по тексту-подсказке, чтобы «Сообщение…» влезло в одну строку
    // (а не «Сообщени\nе…»); иначе — по самому тексту.
    final measureText = _textCtrl.text.isEmpty ? s.chatHint : _textCtrl.text;
    final tp = TextPainter(
      text: TextSpan(text: measureText, style: textStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: null,
    )..layout(maxWidth: contentMaxW);
    // +3px — запас под курсор: TextField резервирует место под него в конце
    // строки, и без запаса последний символ переносится раньше настоящего Text.
    // На итоговый размер пузыря влияет незаметно (округляем вверх для надёжности).
    final textW = tp.width.ceilToDouble() + 3;

    final core = CustomPaint(
      painter: _BubblePainter(
        color: _bg,
        corners: corners,
        tailLeft: false, // своё сообщение — хвостик справа
        tailDrop: tailDrop,
      ),
      child: Container(
        key: _bubbleKey,
        constraints: BoxConstraints(maxWidth: maxW),
        padding: bubblePad,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: textW.clamp(0.0, contentMaxW),
              child: TextField(
                controller: _textCtrl,
                maxLines: null,
                cursorColor: _fg,
                style: textStyle,
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: _textCtrl.text.isEmpty ? s.chatHint : null,
                  hintStyle: TextStyle(
                      color: _fg.withOpacity(0.55), fontSize: 15, height: 1.25),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.isEdited) ...[
                  Text(
                    s.chatEdited,
                    style: TextStyle(
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                      color: metaColor,
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                Text(widget.time,
                    style: TextStyle(fontSize: 10, color: metaColor)),
                const SizedBox(width: 4),
                Icon(Icons.done_rounded, size: 14, color: metaColor),
              ],
            ),
          ],
        ),
      ),
    );

    return Align(
      alignment: Alignment.centerRight,
      child: Transform.rotate(
        angle: tilt,
        child: _face == null
            ? core
            : Stack(
                children: [
                  core,
                  // Мордочка поверх (как в _buildBubble), но перетаскиваемая.
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment(_fx * 2 - 1, _fy * 2 - 1),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) => moveFace(d.globalPosition),
                        onPanUpdate: (d) => moveFace(d.globalPosition),
                        // Размер 1:1 как в _buildBubble (30×16) и без отступа —
                        // иначе центр лица смещается от настоящей позиции.
                        child: CustomPaint(
                          size: const Size(30, 16),
                          painter: _FacePainter(color: _fg, expr: _face!),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _svSquare() {
    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth;
      const h = 150.0;
      void upd(Offset p) => setState(() {
            _useTheme = false;
            _hsv = _hsv
                .withSaturation((p.dx / w).clamp(0.0, 1.0))
                .withValue((1 - p.dy / h).clamp(0.0, 1.0));
          });
      return GestureDetector(
        onPanDown: (d) => upd(d.localPosition),
        onPanUpdate: (d) => upd(d.localPosition),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                      color: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor()),
                ),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                          colors: [Colors.white, Colors.transparent]),
                    ),
                  ),
                ),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: _hsv.saturation * w - 7,
                  top: (1 - _hsv.value) * h - 7,
                  child: _thumb(),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _hueSlider() {
    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth;
      const h = 22.0;
      void upd(Offset p) => setState(() {
            _useTheme = false;
            _hsv = _hsv.withHue((p.dx / w).clamp(0.0, 1.0) * 360);
          });
      return GestureDetector(
        onPanDown: (d) => upd(d.localPosition),
        onPanUpdate: (d) => upd(d.localPosition),
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            gradient: const LinearGradient(colors: [
              Color(0xFFFF0000),
              Color(0xFFFFFF00),
              Color(0xFF00FF00),
              Color(0xFF00FFFF),
              Color(0xFF0000FF),
              Color(0xFFFF00FF),
              Color(0xFFFF0000),
            ]),
          ),
          child: Stack(children: [
            Positioned(
                left: (_hsv.hue / 360) * w - 7, top: h / 2 - 7, child: _thumb()),
          ]),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.theme.primary;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 10, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: widget.theme.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              _preview(),
              const SizedBox(height: 16),
              _label('Мордочка'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _FaceExpr.values)
                    _circleBtn(
                      selected: _face == e,
                      onTap: () => setState(() => _face = e),
                      child: CustomPaint(
                        size: const Size(30, 18),
                        painter:
                            _FacePainter(color: widget.theme.textPrimary, expr: e),
                      ),
                    ),
                  _circleBtn(
                    selected: _face == null,
                    onTap: () => setState(() => _face = null),
                    child: Icon(Icons.block_rounded,
                        color: widget.theme.textMuted, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _label('Цвет'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _circleBtn(
                    selected: _useTheme,
                    onTap: () => setState(() => _useTheme = true),
                    child:
                        Icon(Icons.palette_outlined, color: accent, size: 20),
                  ),
                  for (final col in widget.recent)
                    GestureDetector(
                      onTap: () => setState(() {
                        _useTheme = false;
                        _hsv = HSVColor.fromColor(col);
                      }),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: col,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: !_useTheme &&
                                    col.toARGB32() == _color.toARGB32()
                                ? accent
                                : widget.theme.divider,
                            width: !_useTheme &&
                                    col.toARGB32() == _color.toARGB32()
                                ? 3
                                : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _svSquare(),
              const SizedBox(height: 12),
              _hueSlider(),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.pop(
                    context,
                    _MsgStyle(_useTheme ? null : _color, _face, _fx, _fy,
                        _textCtrl.text),
                  ),
                  child: const Text('Готово',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
