import 'dart:async';
import 'package:flutter/material.dart';
import '../../main.dart';
import '../../services/locale_service.dart';
import '../../services/pocketbase_service.dart';
import '../../services/rewarded_ad_service.dart';
import '../../services/watch_room_service.dart';
import 'watch_room_screen.dart';

/// Вход в совместный просмотр.
///
/// Комната одна на пару: её код выдаёт сервер, поэтому ни хоста, ни приглашений
/// больше нет — оба просто заходят. Внутри работает тот же движок, что на сайте
/// (Centrifugo), а прежняя синхронизация на Firebase RTDB убрана вместе с
/// экраном `watch_together_screen.dart`.
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
  /// Показывает нижний лист с предложением посмотреть рекламу.
  ///
  /// Возвращает true, если в комнату можно: человек досмотрел ролик, либо
  /// рекламы нет вовсе (оффлайн, no-fill) — тогда фичу не запираем. Лист
  /// закрывается свайпом и кнопкой «назад»: закрыл — значит передумал, и
  /// комната не открывается.
  static Future<bool> _requireStartAd(BuildContext context) async {
    if (!_ads.isReady) {
      await _waitForAd(context);
      if (!context.mounted) return false;
    }
    if (!_ads.isReady) {
      _ads.load(); // на следующий раз
      return true; // рекламы нет — не запираем просмотр
    }

    final s = LocaleService.current;
    final cs = Theme.of(context).colorScheme;

    final agreed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: cs.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.play_circle_outline_rounded,
                  color: cs.onPrimaryContainer,
                  size: 30,
                ),
              ),
              const SizedBox(height: 16),
              Text(s.watchTogether, style: Theme.of(ctx).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                s.watchTogetherAdPrompt,
                style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(s.watchAction),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(s.cancel),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (agreed != true) return false;

    final uid = PocketBaseService().userId ?? '';
    await _ads.show(uid: uid);
    unawaited(_ads.load()); // грузим следующий
    return true;
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

  /// Открыть комнату пары. [videoUrl] — ссылка из карточки воспоминания,
  /// её подставят в комнату сразу после открытия.
  static Future<void> open(
    BuildContext context, {
    required String pairId,
    String? videoUrl,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final s = LocaleService.current;

    final room = await WatchRoomService.roomCode(pairId);
    if (room.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(s.error), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    if (!context.mounted) return;

    // Полноэкранная реклама пересобирает дерево, поэтому локальный контекст
    // после неё мёртв — открываем комнату корневым навигатором приложения.
    final allowed = await _requireStartAd(context);
    if (!allowed) return;

    final navigator = LoveApp.rootNavigatorKey.currentState;
    if (navigator == null) return;

    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => WatchRoomScreen(
          room: room,
          pairId: pairId,
          videoUrl: videoUrl,
        ),
      ),
    );
  }

  /// Старое имя точки входа: ленту воспоминаний переучивать не нужно.
  static Future<void> hostVideo(
    BuildContext context, {
    required String pairId,
    required String partnerUid,
    required String videoUrl,
  }) =>
      open(context, pairId: pairId, videoUrl: videoUrl);
}
