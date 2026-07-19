import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'locale_service.dart';

/// Надёжность мгновенной фоновой доставки БЕЗ FCM.
///
/// Мгновенные пуши и обновления виджетов при закрытом приложении держатся на
/// живом WebSocket-сокете внутри Android foreground-сервиса
/// ([PushBackgroundService]). Главный враг этого сокета — Doze и «оптимизация
/// батареи»: система усыпляет сеть даже у foreground-сервиса, и тогда сообщения,
/// «я скучаю» и виджеты обновляются ТОЛЬКО при открытии приложения (ровно та
/// жалоба пользователей).
///
/// Единственное системное лекарство без Google — исключить приложение из
/// оптимизации батареи. Этот сервис вежливо, но настойчиво просит пользователя
/// это сделать через системный диалог Android.
class BackgroundReliabilityService {
  BackgroundReliabilityService._();
  static final BackgroundReliabilityService instance =
      BackgroundReliabilityService._();

  static const _kLastPromptMs = 'bg_battery_prompt_last_ms';
  static const _kPromptCount = 'bg_battery_prompt_count';

  // Не клянчим бесконечно: максимум несколько показов, с паузой между ними.
  static const int _maxPrompts = 4;
  static const Duration _minGap = Duration(days: 5);

  /// Уже исключены из оптимизации батареи? (Android; на других платформах true.)
  Future<bool> isExempt() async {
    if (!Platform.isAndroid) return true;
    try {
      return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {
      return true; // не блокируем UX, если проверка недоступна
    }
  }

  /// Показать запрос на исключение из оптимизации батареи, если это уместно:
  /// только Android, ещё не исключены, не слишком часто. Идемпотентно-безопасно
  /// вызывать на каждый вход на главный экран — сам решает, показывать ли.
  Future<void> maybePrompt(BuildContext context) async {
    if (!Platform.isAndroid) return;
    if (await isExempt()) return;

    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(_kPromptCount) ?? 0;
    if (count >= _maxPrompts) return;
    final lastMs = prefs.getInt(_kLastPromptMs) ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (lastMs != 0 && nowMs - lastMs < _minGap.inMilliseconds) return;

    if (!context.mounted) return;
    final accepted = await _showDialog(context);

    await prefs.setInt(_kLastPromptMs, nowMs);
    await prefs.setInt(_kPromptCount, count + 1);

    if (accepted) {
      try {
        // Системный диалог «Не оптимизировать батарею для приложения».
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      } catch (_) {
        // Fallback: открыть экран настроек оптимизации, если прямой запрос недоступен.
        try {
          await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
        } catch (_) {}
      }
      // Если пользователь согласился — больше не клянчим.
      if (await isExempt()) {
        await prefs.setInt(_kPromptCount, _maxPrompts);
      }
    }
  }

  Future<bool> _showDialog(BuildContext context) async {
    final ru = LocaleService.instance.isRussian;
    final scheme = Theme.of(context).colorScheme;
    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.bolt_rounded, color: scheme.primary, size: 32),
        title: Text(
          ru ? 'Мгновенные уведомления и виджеты' : 'Instant notifications & widgets',
          textAlign: TextAlign.center,
        ),
        content: Text(
          ru
              ? 'Чтобы сообщения, «я скучаю» и виджеты обновлялись сразу — даже '
                  'когда приложение закрыто — разрешите Togetherly работать в '
                  'фоне без ограничений батареи.\n\nБез этого Android усыпляет '
                  'связь, и всё приходит только при открытии приложения.'
              : 'To get messages, “miss you” and widget updates instantly — even '
                  'when the app is closed — allow Togetherly to run in the '
                  'background without battery limits.\n\nOtherwise Android '
                  'suspends the connection and everything only arrives when you '
                  'open the app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ru ? 'Позже' : 'Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ru ? 'Разрешить' : 'Allow'),
          ),
        ],
      ),
    );
    return res ?? false;
  }
}
