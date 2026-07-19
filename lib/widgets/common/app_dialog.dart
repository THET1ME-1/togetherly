import 'package:flutter/material.dart';

import '../../services/locale_service.dart';

/// Единый стиль для всех меню приложения: диалоги, подтверждения и снэкбары.
///
/// Форма/скругления/цвета наследуются от глобальной темы (`dialogTheme`,
/// `snackBarTheme` в [main]), а акцент по умолчанию берётся из активной темы
/// через `Theme.of(context).colorScheme.primary`. Поэтому все меню выглядят
/// одинаково и автоматически перекрашиваются при смене темы.
abstract final class AppDialog {
  /// Диалог-подтверждение с заголовком, текстом и двумя кнопками.
  ///
  /// Возвращает `true`, если пользователь подтвердил действие.
  /// Для деструктивных действий (удаление/сброс) передай [destructive] = true —
  /// кнопка подтверждения станет красной.
  static Future<bool> confirm(
    BuildContext context, {
    String? title,
    required String message,
    String? confirmLabel,
    String? cancelLabel,
    bool destructive = false,
    IconData? icon,
  }) async {
    final accent = Theme.of(context).colorScheme.primary;
    final confirmColor = destructive ? const Color(0xFFE5484D) : accent;
    final s = LocaleService.current;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: icon != null ? Icon(icon, color: confirmColor, size: 30) : null,
        title: title != null ? Text(title) : null,
        content: Text(message),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelLabel ?? s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: confirmColor),
            child: Text(confirmLabel ?? s.confirm),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Информационный диалог с одной кнопкой «ОК».
  static Future<void> info(
    BuildContext context, {
    required String title,
    required String message,
    String? buttonLabel,
    IconData? icon,
  }) {
    final accent = Theme.of(context).colorScheme.primary;
    final s = LocaleService.current;
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: icon != null ? Icon(icon, color: accent, size: 30) : null,
        title: Text(title),
        content: Text(message),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(foregroundColor: accent),
            child: Text(buttonLabel ?? s.ok),
          ),
        ],
      ),
    );
  }
}

/// Снэкбары в едином стиле (форма/поведение — из `snackBarTheme`).
///
/// Слева — иконка-статус, справа от текста — опциональное действие.
abstract final class AppSnack {
  static void _show(
    BuildContext context, {
    required String message,
    required IconData icon,
    required Color iconColor,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        action: (actionLabel != null && onAction != null)
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ),
    );
  }

  /// Успех (зелёная галочка).
  static void success(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      _show(
        context,
        message: message,
        icon: Icons.check_circle_rounded,
        iconColor: const Color(0xFF4CAF50),
        actionLabel: actionLabel,
        onAction: onAction,
      );

  /// Ошибка (красный крест).
  static void error(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      _show(
        context,
        message: message,
        icon: Icons.error_rounded,
        iconColor: const Color(0xFFE5484D),
        actionLabel: actionLabel,
        onAction: onAction,
      );

  /// Нейтральное сообщение (иконка в цвете активной темы).
  static void info(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      _show(
        context,
        message: message,
        icon: Icons.info_rounded,
        iconColor: Theme.of(context).colorScheme.primary,
        actionLabel: actionLabel,
        onAction: onAction,
      );
}
