import 'package:flutter/material.dart';

import '../services/locale_service.dart';
import '../theme/theme_scope.dart';

/// Поле выбора даты/времени воспоминания.
///
/// Используется во всех формах создания пина (фото/видео/музыка/
/// локация/книга/текст/ссылка). Если пользователь выбрал дату в
/// прошлом — пин уезжает на ленте в нужную временную точку.
/// По умолчанию — `null` (то есть «сейчас», момент создания).
class MemoryDateField extends StatelessWidget {
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final Color accent;
  /// Прятать ли кнопку сброса (×). По умолчанию `true` — нужна при создании
  /// пина, чтобы вернуться к «сейчас». В режиме редактирования её лучше
  /// прятать (`false`), так как семантика «очистить до дефолта» там неясна:
  /// дефолтом является уже существующая дата воспоминания.
  final bool showReset;

  const MemoryDateField({
    super.key,
    required this.value,
    required this.onChanged,
    this.accent = const Color(0xFF8B5CF6),
    this.showReset = true,
  });

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final initial = value ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: now,
      // Локализованные подписи берём из стандартного Material локали,
      // но кнопка OK / Cancel уже переведены в системе.
    );
    if (picked == null) return;
    // Сохраняем время из текущего value (или now), но обновляем дату.
    final cur = value ?? now;
    onChanged(DateTime(
      picked.year,
      picked.month,
      picked.day,
      cur.hour,
      cur.minute,
    ));
  }

  Future<void> _pickTime(BuildContext context) async {
    final now = DateTime.now();
    final cur = value ?? now;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur.hour, minute: cur.minute),
    );
    if (picked == null) return;
    final base = value ?? now;
    onChanged(DateTime(
      base.year,
      base.month,
      base.day,
      picked.hour,
      picked.minute,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final t = context.appTheme;
    final hasValue = value != null;
    final formatted = hasValue ? _format(value!) : s.memoryDateNow;
    final isBackdated = hasValue &&
        value!.isBefore(DateTime.now().subtract(const Duration(minutes: 1)));

    return Container(
      decoration: BoxDecoration(
        color: hasValue
            ? accent.withValues(alpha: 0.05)
            : t.cardSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: hasValue
              ? accent.withValues(alpha: 0.35)
              : t.divider,
          width: hasValue ? 1.4 : 1.0,
        ),
      ),
      child: Column(
        children: [
          // Заголовок
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: hasValue
                        ? accent.withValues(alpha: 0.12)
                        : t.surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.event_rounded,
                    size: 16,
                    color: hasValue ? accent : t.textSecondary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.memoryDateLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: hasValue
                              ? t.textPrimary
                              : t.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        formatted,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: isBackdated
                              ? accent
                              : (hasValue
                                  ? t.textSecondary
                                  : t.textMuted),
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasValue && showReset)
                  IconButton(
                    onPressed: () => onChanged(null),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: t.textMuted,
                    ),
                    tooltip: s.memoryDateClear,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
              ],
            ),
          ),
          // Кнопки выбора даты / времени
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: _DateTimeButton(
                    icon: Icons.calendar_today_rounded,
                    label: s.memoryDatePickDate,
                    onTap: () => _pickDate(context),
                    accent: accent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _DateTimeButton(
                    icon: Icons.access_time_rounded,
                    label: s.memoryDatePickTime,
                    onTap: () => _pickTime(context),
                    accent: accent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _format(DateTime d) {
    final months = LocaleService.current.monthAbbrev;
    final dd = d.day.toString().padLeft(2, '0');
    final mm = months[d.month - 1];
    final yyyy = d.year;
    final hh = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    return '$dd $mm $yyyy · $hh:$min';
  }
}

class _DateTimeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color accent;

  const _DateTimeButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: accent),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
