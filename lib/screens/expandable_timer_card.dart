import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../models/timer_item.dart';
import '../services/timer_service.dart';
import '../theme/app_theme.dart';
import '../services/locale_service.dart';
import '../widgets/petal_timer_dial.dart';

/// Карусель таймеров с ИДЕАЛЬНОЙ геометрией радиального меню, адаптированной под размеры контейнера.
class ExpandableTimerCard extends StatefulWidget {
  final AppTheme theme;
  final TimerService timerService;
  final String partnerAvatarUrl;
  final String myAvatarUrl;
  final bool isPaired;
  final ValueChanged<bool>? onExpandChanged;
  final ValueChanged<String>? onPetalTap;

  const ExpandableTimerCard({
    super.key,
    required this.theme,
    required this.timerService,
    required this.partnerAvatarUrl,
    required this.myAvatarUrl,
    required this.isPaired,
    this.onExpandChanged,
    this.onPetalTap,
  });

  @override
  State<ExpandableTimerCard> createState() => _ExpandableTimerCardState();
}

class _ExpandableTimerCardState extends State<ExpandableTimerCard> {
  late PageController _pageController;
  int _currentIndex = 0;
  Timer? _ticker;

  AppTheme get _t => widget.theme;

  @override
  void initState() {
    super.initState();
    final timers = widget.timerService.timers;
    final defaultT = widget.timerService.defaultTimer;
    _currentIndex = timers.indexWhere((t) => t.id == defaultT?.id);
    if (_currentIndex < 0) _currentIndex = 0;

    _pageController = PageController(initialPage: _currentIndex);
    widget.timerService.addListener(_onTimerChanged);
    _startTicker();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _ticker?.cancel();
    widget.timerService.removeListener(_onTimerChanged);
    super.dispose();
  }

  void _onTimerChanged() {
    if (!mounted) return;
    final timers = widget.timerService.timers;
    if (timers.isNotEmpty && _currentIndex >= timers.length) {
      // После удаления — переходим на системный таймер, иначе на последний
      final sysIdx = timers.indexWhere((t) => t.isSystem);
      _currentIndex = sysIdx >= 0 ? sysIdx : timers.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(_currentIndex);
        }
      });
    }
    setState(() {});
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _goToPage(int page) {
    if (page >= 0 && page < widget.timerService.timers.length) {
      _pageController.animateToPage(
        page,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final timers = widget.timerService.timers;
    if (timers.isEmpty) {
      return SizedBox(
        height: 300,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(LocaleService.current.noTimers),
              const SizedBox(height: 16),
              _RadialButton(
                icon: Icons.add_rounded,
                onTap: _showCreateDialog,
                theme: _t,
              ),
              const SizedBox(height: 10),
              Text(
                LocaleService.current.createTimer,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _t.primary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Получаем реальную ширину КОНТЕЙНЕРА, а не экрана
        final actualWidth = constraints.maxWidth;
        // Диаграмма занимает почти всю ширину, кнопки могут "парить" за пределами благодаря Clip.none
        final dialSize = actualWidth * 0.95;

        // Уменьшаем отступ, так как Clip.none позволяет кнопкам парить выше
        final topPadding = 45.0;
        final containerHeight = dialSize + topPadding + 10;

        final centerX = actualWidth / 2;
        final centerY = topPadding + (dialSize / 2);

        return SizedBox(
          height: containerHeight,
          width: actualWidth,
          child: Stack(
            alignment: Alignment.topCenter,
            clipBehavior: Clip.none,
            children: [
              // 1. Carousel
              Positioned(
                top: topPadding,
                child: SizedBox(
                  width: actualWidth,
                  height: dialSize,
                  child: PageView.builder(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (idx) {
                      setState(() => _currentIndex = idx);
                      // setDefault не вызываем здесь — менять основной таймер
                      // должен только явный переключатель в диалоге настроек.
                      // Вызов на каждый свайп приводил к дублям isDefault=true
                      // при race condition с Firestore-слушателем.
                    },
                    itemCount: timers.length,
                    itemBuilder: (context, index) {
                      return Center(
                        child: SizedBox(
                          width: dialSize,
                          height: dialSize,
                          child: PetalTimerDial(
                            theme: _t,
                            startDate: timers[index].startDate,
                            isCountdown: timers[index].isCountdown,
                            onPetalTap: widget.onPetalTap,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

              // 2. Arc Controls
              _buildArcControls(dialSize / 2, centerX, centerY),
            ],
          ),
        );
      },
    );
  }

  Widget _buildArcControls(double radius, double centerX, double centerY) {
    final timers = widget.timerService.timers;
    final timer = timers[_currentIndex];

    final actions = [
      _ArcAction(
        icon: Icons.chevron_left_rounded,
        onTap: () => _goToPage(_currentIndex - 1),
        visible: _currentIndex > 0,
      ),
      _ArcAction(icon: Icons.edit_rounded, onTap: () => _showEditDialog(timer)),
      _ArcAction(icon: Icons.add_rounded, onTap: _showCreateDialog),
      _ArcAction(
        icon: Icons.delete_outline_rounded,
        onTap: () => _showDeleteConfirm(timer),
        visible: !timer.isSystem,
      ),
      _ArcAction(
        icon: Icons.chevron_right_rounded,
        onTap: () => _goToPage(_currentIndex + 1),
        visible: _currentIndex < timers.length - 1,
      ),
    ];

    final visibleActions = actions.where((a) => a.visible).toList();

    const double fixedStep = 15.0;
    // СМЕЩАЕМ КЛАСТЕР НА 12 ЧАСОВ (-90 градусов)
    const double centerAngle = -90.0;
    final double startAngle =
        centerAngle - ((visibleActions.length - 1) * fixedStep / 2);

    // Сдвиг радиуса: диаграмма сама рисуется на radius-2.
    // Увеличено до +32 для существенного зазора.
    final buttonRadius = radius + 32;

    return Stack(
      clipBehavior: Clip.none,
      children: List.generate(visibleActions.length, (i) {
        final angleDeg = startAngle + (fixedStep * i);
        final angleRad = angleDeg * math.pi / 180;

        final x = buttonRadius * math.cos(angleRad);
        final y = buttonRadius * math.sin(angleRad);

        return Positioned(
          left: centerX + x - 18,
          top: centerY + y - 18,
          child: _RadialButton(
            icon: visibleActions[i].icon,
            onTap: visibleActions[i].onTap,
            theme: _t,
          ),
        );
      }),
    );
  }

  // ── Action Handlers ──

  void _showCreateDialog() {
    _showTimerSettingsDialog(
      title: LocaleService.current.createTimer,
      initialTitle: '',
      initialDate: DateTime.now(),
      initialEmoji: '❤️',
      initialIsDefault: widget.timerService.count == 0,
      initialIsCountdown: false,
      onSave: (t, d, e, def, c) => widget.timerService.addTimer(
        title: t,
        startDate: d,
        emoji: e,
        isDefault: def,
        isCountdown: c,
      ),
    );
  }

  void _showEditDialog(TimerItem timer) {
    _showTimerSettingsDialog(
      title: LocaleService.current.editTimer,
      initialTitle: timer.title,
      initialDate: timer.startDate,
      initialEmoji: timer.emoji,
      initialIsDefault: timer.isDefault,
      initialIsCountdown: timer.isCountdown,
      onSave: (t, d, e, def, c) => widget.timerService.updateTimer(
        timer.copyWith(
          title: t,
          startDate: d,
          emoji: e,
          isDefault: def,
          isCountdown: c,
        ),
      ),
    );
  }

  void _showTimerSettingsDialog({
    required String title,
    required String initialTitle,
    required DateTime initialDate,
    required String initialEmoji,
    required bool initialIsDefault,
    required bool initialIsCountdown,
    required void Function(String, DateTime, String, bool, bool) onSave,
  }) {
    final titleCtrl = TextEditingController(text: initialTitle);
    final dateCtrl = TextEditingController(text: _formatDate(initialDate));
    var pickedDate = initialDate;
    var selectedEmoji = initialEmoji;
    var isDefault = initialIsDefault;
    var isCountdown = initialIsCountdown;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Container(
            decoration: BoxDecoration(
              color: _t.cardSurface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            ),
            padding: EdgeInsets.fromLTRB(
              24,
              16,
              24,
              MediaQuery.of(ctx).viewInsets.bottom +
                  MediaQuery.of(ctx).padding.bottom +
                  32,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: _t.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _dialogLabel(LocaleService.current.timerNameLabel),
                  TextField(
                    controller: titleCtrl,
                    decoration: _dialogInputDeco(
                      LocaleService.current.egAnniversary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _dialogLabel(
                    isCountdown
                        ? LocaleService.current.targetDate
                        : LocaleService.current.startDate,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: dateCtrl,
                          keyboardType: TextInputType.datetime,
                          // Ручной ввод даты не трогает pickedDate (его меняют
                          // только пикеры) — перестраиваем лист, чтобы
                          // предупреждение о прошедшей дате считалось по
                          // фактически введённому тексту, а не по pickedDate.
                          onChanged: (_) => setSheetState(() {}),
                          decoration: _dialogInputDeco(
                            '${LocaleService.current.dateFormatHint}  ${LocaleService.current.timeFormatHint}',
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () async {
                          final d = await showDatePicker(
                            context: ctx,
                            initialDate: pickedDate,
                            firstDate: DateTime(1900),
                            lastDate: DateTime(2100),
                          );
                          if (d == null || !ctx.mounted) return;
                          setSheetState(() {
                            pickedDate = DateTime(
                              d.year, d.month, d.day,
                              pickedDate.hour, pickedDate.minute,
                            );
                            dateCtrl.text = _formatDate(pickedDate);
                          });
                        },
                        child: Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            color: _t.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.calendar_today_rounded,
                            color: _t.primary,
                            size: 24,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () async {
                          final t = await showTimePicker(
                            context: ctx,
                            initialTime: TimeOfDay.fromDateTime(pickedDate),
                          );
                          if (t == null || !ctx.mounted) return;
                          setSheetState(() {
                            pickedDate = DateTime(
                              pickedDate.year, pickedDate.month, pickedDate.day,
                              t.hour, t.minute,
                            );
                            dateCtrl.text = _formatDate(pickedDate);
                          });
                        },
                        child: Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            color: _t.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.access_time_rounded,
                            color: _t.primary,
                            size: 24,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isCountdown &&
                      (_parseDate(dateCtrl.text) ?? pickedDate)
                          .isBefore(DateTime.now()))
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              LocaleService.current.countdownPastDateWarning,
                              style: const TextStyle(fontSize: 12, color: Colors.orange),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 20),
                  _dialogLabel(LocaleService.current.symbolLabel),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children:
                        [
                          '❤️',
                          '💕',
                          '💖',
                          '🔥',
                          '⭐',
                          '🌙',
                          '🎂',
                          '🏠',
                          '🎓',
                          '💼',
                          '✈️',
                          '🐾',
                          '🌸',
                          '💍',
                          '👶',
                          '🎯',
                        ].map((e) {
                          final sel = selectedEmoji == e;
                          return GestureDetector(
                            onTap: () => setSheetState(() => selectedEmoji = e),
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: sel
                                    ? _t.primary.withOpacity(0.15)
                                    : _t.surfaceMuted,
                                borderRadius: BorderRadius.circular(14),
                                border: sel
                                    ? Border.all(color: _t.primary, width: 2)
                                    : null,
                              ),
                              child: Center(
                                child: Text(
                                  e,
                                  style: const TextStyle(fontSize: 22),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                  ),
                  const SizedBox(height: 32),
                  _dialogSwitch(
                    LocaleService.current.countdownMode,
                    isCountdown,
                    (v) => setSheetState(() => isCountdown = v),
                  ),
                  _dialogSwitch(
                    LocaleService.current.setAsMain,
                    isDefault,
                    (v) => setSheetState(() => isDefault = v),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: () {
                        if (titleCtrl.text.isEmpty) return;
                        var finalDate = _parseDate(dateCtrl.text) ?? pickedDate;
                        finalDate = _normalizeTimerDate(finalDate);
                        onSave(
                          titleCtrl.text.trim(),
                          finalDate,
                          selectedEmoji,
                          isDefault,
                          isCountdown,
                        );
                        Navigator.pop(ctx);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _t.fillColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        LocaleService.current.saveSettings,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showDeleteConfirm(TimerItem timer) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _t.cardSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Text(
          LocaleService.current.deleteTimerQuestion,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        content: Text(LocaleService.current.timerDeleteConfirm(timer.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              LocaleService.current.cancel,
              style: TextStyle(
                color: _t.textSecondary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              // _timers.removeWhere — синхронная операция внутри deleteTimer,
              // поэтому timers уже обновлён к моменту чтения ниже.
              widget.timerService.deleteTimer(timer.id);
              Navigator.pop(ctx);
              final updatedTimers = widget.timerService.timers;
              if (updatedTimers.isNotEmpty) {
                final sysIdx = updatedTimers.indexWhere((t) => t.isSystem);
                final targetIdx = (sysIdx >= 0 ? sysIdx : 0).clamp(
                  0,
                  updatedTimers.length - 1,
                );
                setState(() => _currentIndex = targetIdx);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _pageController.hasClients) {
                    _pageController.jumpToPage(targetIdx);
                  }
                });
              }
            },
            child: Text(
              LocaleService.current.delete,
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dialogLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w900,
        color: _t.textMuted,
        letterSpacing: 1.5,
      ),
    ),
  );
  InputDecoration _dialogInputDeco(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: _t.surfaceMuted,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
  );
  Widget _dialogSwitch(String label, bool val, ValueChanged<bool> onChanged) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          onTap: () => onChanged(!val),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: val ? _t.fillColor : Colors.transparent,
                  border: Border.all(
                    color: val ? _t.fillColor : _t.textMuted,
                    width: 2,
                  ),
                ),
                child: val
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _t.textPrimary,
                ),
              ),
            ],
          ),
        ),
      );
  String _formatDate(DateTime d) {
    final date =
        '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
    return '$date  ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  DateTime? _parseDate(String s) {
    final parts = s.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return null;
    final dateParts = parts[0].split('.');
    if (dateParts.length != 3) return null;
    final day = int.tryParse(dateParts[0]);
    final month = int.tryParse(dateParts[1]);
    final year = int.tryParse(dateParts[2]);
    if (day == null || month == null || year == null) return null;
    int h = 0, min = 0;
    if (parts.length >= 2) {
      final timeParts = parts[1].split(':');
      h = int.tryParse(timeParts[0]) ?? 0;
      if (timeParts.length >= 2) min = int.tryParse(timeParts[1]) ?? 0;
    }
    return DateTime(year, month, day, h.clamp(0, 23), min.clamp(0, 59));
  }

  DateTime _normalizeTimerDate(DateTime date) => date;
}

class _ArcAction {
  final IconData icon;
  final VoidCallback onTap;
  final bool visible;
  _ArcAction({required this.icon, required this.onTap, this.visible = true});
}

class _RadialButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final AppTheme theme;

  const _RadialButton({
    required this.icon,
    required this.onTap,
    required this.theme,
  });

  @override
  State<_RadialButton> createState() => _RadialButtonState();
}

class _RadialButtonState extends State<_RadialButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.95),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: widget.theme.fillColor,
            shape: BoxShape.circle,
          ),
          child: Icon(widget.icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }
}
