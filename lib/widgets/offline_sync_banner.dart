import 'dart:async';

import 'package:flutter/material.dart';

import '../services/locale_service.dart';
import '../services/offline/connectivity_service.dart';
import '../services/offline/outbox_service.dart';

/// Глобальная тонкая плашка состояния синхронизации поверх любого экрана
/// (через `MaterialApp.builder`). Показывается, только когда есть что показать:
/// • офлайн — некликабельная подсказка (сразу);
/// • идёт синхронизация — мягкая плашка со спиннером, но с ДЕБАУНСОМ: появляется
///   лишь если отправка висит дольше [_syncDebounce] (быстрые синки не мигают
///   плашкой и не раздражают);
/// • есть «ядовитые» операции (сервер упорно отверг) — КЛИКАБЕЛЬНАЯ плашка
///   «повторить» (вызывает [OutboxService.retryPoison]), показывается сразу.
/// Цвета берутся из текущей темы. Пустые зоны прозрачны для касаний.
class OfflineSyncBanner extends StatelessWidget {
  const OfflineSyncBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              // Material (прозрачный) даёт корректный DefaultTextStyle/Directionality
              // оверлею поверх MaterialApp.builder — иначе Flutter рисует текст с
              // «жёлтым подчёркиванием» (нет Material-предка).
              child: Material(
                type: MaterialType.transparency,
                child: _SyncChips(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SyncChips extends StatefulWidget {
  @override
  State<_SyncChips> createState() => _SyncChipsState();
}

class _SyncChipsState extends State<_SyncChips> {
  /// Сколько «висящая» синхронизация должна продержаться, прежде чем показать
  /// плашку. Короткие отправки (доли секунды) проходят незаметно.
  static const Duration _syncDebounce = Duration(seconds: 3);

  StreamSubscription<bool>? _connSub;
  Timer? _debounce;

  /// Прошёл ли дебаунс «идёт синхронизация» — только тогда показываем плашку.
  bool _showSyncing = false;

  @override
  void initState() {
    super.initState();
    // Спиннер реагирует на activeCount (свежие записи), а не на pendingCount —
    // запись в backoff после провала больше не крутит «вечную синхронизацию».
    OutboxService.instance.activeCount.addListener(_onChange);
    OutboxService.instance.poisonCount.addListener(_onChange);
    _connSub =
        ConnectivityService.instance.onOnlineChanged.listen((_) => _onChange());
    _reconcile();
  }

  void _onChange() {
    if (!mounted) return;
    _reconcile();
    setState(() {});
  }

  /// Управляет дебаунс-таймером показа «Синхронизация…».
  void _reconcile() {
    final active = OutboxService.instance.activeCount.value;
    final online = ConnectivityService.instance.isOnline;
    final syncing = online && active > 0;
    if (syncing) {
      // запустить таймер, если ещё не показываем и не запущен
      if (!_showSyncing && _debounce == null) {
        _debounce = Timer(_syncDebounce, () {
          _debounce = null;
          if (!mounted) return;
          // показываем, только если к моменту срабатывания всё ещё синкаем
          if (ConnectivityService.instance.isOnline &&
              OutboxService.instance.activeCount.value > 0) {
            setState(() => _showSyncing = true);
          }
        });
      }
    } else {
      _debounce?.cancel();
      _debounce = null;
      _showSyncing = false;
    }
  }

  @override
  void dispose() {
    OutboxService.instance.activeCount.removeListener(_onChange);
    OutboxService.instance.poisonCount.removeListener(_onChange);
    _connSub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = OutboxService.instance.activeCount.value;
    final poison = OutboxService.instance.poisonCount.value;
    final online = ConnectivityService.instance.isOnline;
    final ru = LocaleService.instance.isRussian;
    final scheme = Theme.of(context).colorScheme;

    final chips = <Widget>[];

    if (!online) {
      // Офлайн — показываем сразу (важное состояние).
      chips.add(IgnorePointer(
        child: _chip(
          context,
          icon: Icons.cloud_off_rounded,
          text: ru ? 'Нет сети' : 'Offline',
          bg: scheme.surfaceContainerHighest,
          fg: scheme.onSurfaceVariant,
        ),
      ));
    } else if (_showSyncing && active > 0) {
      // Идёт синхронизация — мягкая плашка со спиннером, без сырого счётчика,
      // и только после дебаунса (длительная отправка).
      chips.add(IgnorePointer(
        child: _chip(
          context,
          spinner: true,
          text: ru ? 'Синхронизация…' : 'Syncing…',
          bg: scheme.surfaceContainerHighest,
          fg: scheme.onSurfaceVariant,
        ),
      ));
    }

    // «Ядовитые» операции — кликабельно: повторить отправку. Показываем сразу.
    if (poison > 0) {
      chips.add(GestureDetector(
        onTap: () => OutboxService.instance.retryPoison(),
        child: _chip(
          context,
          icon: Icons.refresh_rounded,
          text: ru ? 'Не сохранилось — повторить' : "Didn't sync — retry",
          bg: scheme.errorContainer,
          fg: scheme.onErrorContainer,
        ),
      ));
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SizeTransition(
            sizeFactor: anim, axisAlignment: -1, child: child),
      ),
      child: chips.isEmpty
          ? const SizedBox.shrink()
          : Padding(
              key: ValueKey('${!online}-$_showSyncing-${poison > 0}'),
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in chips)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 4), child: c),
                ],
              ),
            ),
    );
  }

  Widget _chip(
    BuildContext context, {
    IconData? icon,
    bool spinner = false,
    required String text,
    required Color bg,
    required Color fg,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: bg.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (spinner)
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            else if (icon != null)
              Icon(icon, size: 15, color: fg),
            const SizedBox(width: 7),
            Text(
              text,
              style: TextStyle(
                color: fg,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      );
}
