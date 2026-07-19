import 'dart:async';
import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../../services/level_service.dart';
import '../../services/locale_service.dart';
import '../../services/pocketbase_service.dart';
import '../../services/rewarded_ad_service.dart';
import '../../services/together_invite_repository.dart';
import 'watch_together_screen.dart';

/// Точки входа в совместный просмотр: запуск хостом и баннер-приглашение гостю.
class TogetherLauncher {
  // Rewarded на старте показываем ТОЛЬКО хосту и один раз за запуск сеанса.
  // Гость заходит без рекламы (иначе старт рассинхронится). Просмотр ролика
  // ОБЯЗАТЕЛЕН (без «Позже»); единственное исключение — если рекламы нет вообще
  // (оффлайн / no-fill после ожидания), тогда не запираем фичу и пускаем без неё.
  static final RewardedAdService _ads = RewardedAdService();

  /// Предзагрузка rewarded — звать заранее (напр. при открытии карточки видео),
  /// чтобы к тапу «Смотреть вместе» ролик уже был готов. Идемпотентно.
  static void preloadStartAd() => _ads.load();

  /// ОБЯЗАТЕЛЬНЫЙ rewarded перед стартом (только хост): чтобы открыть совместный
  /// просмотр, нужно досмотреть ролик. Кнопки «Позже» нет — диалог нельзя
  /// закрыть ни тапом мимо, ни «назад». Сам показ ролик инициирует юзер тапом
  /// «Смотреть» (явное согласие, требование политик). Водопад показа — Яндекс
  /// (основная сеть) → AdMob (резерв). Единственное исключение: если рекламы нет
  /// вообще (оффлайн / no-fill даже после ожидания) — фичу НЕ запираем намертво.
  static Future<void> _requireStartAd(BuildContext context) async {
    // Обычно ролик предзагружен (preloadStartAd при открытии экрана). Если ещё
    // не готов — ждём загрузку под спиннером (Яндекс → AdMob).
    if (!_ads.isReady) {
      await _waitForAd(context);
      if (!context.mounted) return;
    }
    // Рекламы так и нет (оффлайн / no-fill) — не блокируем совместный просмотр.
    if (!_ads.isReady) {
      _ads.load(); // на следующий раз
      return;
    }

    final watch = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // нельзя закрыть тапом мимо
      builder: (ctx) => PopScope(
        canPop: false, // и системной кнопкой «назад» тоже
        child: AlertDialog(
          title: Text(LocaleService.current.watchTogether),
          content: Text(LocaleService.current.watchTogetherAdPrompt),
          actions: [
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.play_circle_outline_rounded),
              label: Text(LocaleService.current.watchAction),
            ),
          ],
        ),
      ),
    );
    if (watch == true) {
      final uid = PocketBaseService().userId ?? '';
      await _ads.show(uid: uid);
      unawaited(_ads.load()); // грузим следующий
    }
  }

  /// Ждёт готовности rewarded под неотменяемым спиннером (макс ~8с),
  /// перезапуская каскад загрузки (Яндекс → AdMob) при необходимости.
  static Future<void> _waitForAd(BuildContext context) async {
    _ads.load();
    BuildContext? dialogCtx;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return const PopScope(
          canPop: false,
          child: Center(child: CircularProgressIndicator()),
        );
      },
    );
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (!_ads.isReady && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final dctx = dialogCtx;
    if (dctx != null && dctx.mounted) Navigator.of(dctx).pop(); // закрыть спиннер
  }

  /// Показать диалог вставки YouTube-ссылки и запустить совместный просмотр
  /// как хост.
  static Future<void> startWatchTogether(
    BuildContext context, {
    required String pairId,
    required String partnerUid,
  }) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(LocaleService.current.watchTogether),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: LocaleService.current.youtubeLinkHint,
            prefixIcon: const Icon(Icons.link),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(LocaleService.current.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(LocaleService.current.startAction),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty || !context.mounted) return;

    final videoId = YoutubePlayer.convertUrlToId(url);
    if (videoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(LocaleService.current.youtubeLinkInvalid)),
      );
      return;
    }

    // Навигатор захватываем ДО рекламы. Полноэкранный rewarded пересобирает
    // ленту, и context КАРТОЧКИ видео к возврату часто уже размонтирован —
    // тогда переход на просмотр тихо не происходил (юзер «застревал» в ленте).
    // NavigatorState экрана выше по дереву и переживает показ рекламы.
    final navigator = Navigator.of(context);

    // Rewarded на старте ОБЯЗАТЕЛЕН (только хост); фейл-опен лишь при no-fill.
    await _requireStartAd(context);
    if (!navigator.mounted) return;

    unawaited(LevelService.instance.award(XpAction.watchTogether));
    navigator.push(
      MaterialPageRoute(
        builder: (_) => WatchTogetherScreen(
          pairId: pairId,
          partnerUid: partnerUid,
          videoId: videoId,
          isHost: true,
        ),
      ),
    );
  }

  /// Запустить совместный просмотр конкретного видео как хост (URL уже известен,
  /// диалог не нужен) — напр. из карточки видео-воспоминания.
  static Future<void> hostVideo(
    BuildContext context, {
    required String pairId,
    required String partnerUid,
    required String videoUrl,
  }) async {
    final videoId = YoutubePlayer.convertUrlToId(videoUrl);
    if (videoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(LocaleService.current.youtubeLinkInvalid)),
      );
      return;
    }

    // Навигатор захватываем ДО рекламы. Полноэкранный rewarded пересобирает
    // ленту, и context КАРТОЧКИ видео к возврату часто уже размонтирован —
    // тогда переход на просмотр тихо не происходил (юзер «застревал» в ленте).
    // NavigatorState экрана выше по дереву и переживает показ рекламы.
    final navigator = Navigator.of(context);

    // Rewarded на старте ОБЯЗАТЕЛЕН (только хост); фейл-опен лишь при no-fill.
    await _requireStartAd(context);
    if (!navigator.mounted) return;

    unawaited(LevelService.instance.award(XpAction.watchTogether));
    navigator.push(
      MaterialPageRoute(
        builder: (_) => WatchTogetherScreen(
          pairId: pairId,
          partnerUid: partnerUid,
          videoId: videoId,
          isHost: true,
        ),
      ),
    );
  }

  /// Присоединиться к сеансу, который начал партнёр.
  static void joinSession(
    BuildContext context, {
    required String pairId,
    required String partnerUid,
    required String videoId,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WatchTogetherScreen(
          pairId: pairId,
          partnerUid: partnerUid,
          videoId: videoId,
          isHost: false,
        ),
      ),
    );
  }
}

/// Баннер-приглашение. Слушает activeSessionStream (реюзает hub-листенер
/// group-doc → 0 новых Firestore-чтений) и показывает кнопку «Присоединиться»,
/// когда партнёр начал совместный сеанс.
class TogetherInviteBanner extends StatelessWidget {
  final String pairId;
  final String partnerUid;

  const TogetherInviteBanner({
    super.key,
    required this.pairId,
    required this.partnerUid,
  });

  @override
  Widget build(BuildContext context) {
    if (pairId.isEmpty) return const SizedBox.shrink();
    final myUid = PocketBaseService().userId;

    return StreamBuilder<Map<String, dynamic>?>(
      stream: TogetherInviteRepository().watch(pairId),
      builder: (context, snap) {
        final session = snap.data;
        if (session == null) return const SizedBox.shrink();

        final hostUid = session['hostUid'] as String?;
        // Не показываем баннер хосту — он уже в сеансе.
        if (hostUid == null || hostUid == myUid) return const SizedBox.shrink();

        final mediaId = (session['mediaId'] as String?) ?? '';
        if (mediaId.isEmpty) return const SizedBox.shrink();
        final hostName =
            (session['hostName'] as String?) ?? LocaleService.current.partnerFallback;

        return Material(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => TogetherLauncher.joinSession(
              context,
              pairId: pairId,
              partnerUid: partnerUid,
              videoId: mediaId,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.smart_display, color: Colors.red),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      LocaleService.current.invitesToWatchTogether(hostName),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(LocaleService.current.joinAction),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
