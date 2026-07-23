import 'package:flutter/material.dart';
import '../../services/locale_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common/animations.dart';

/// Нижняя навигационная панель главного экрана.
class HomeBottomNav extends StatelessWidget {
  final int selectedIndex;
  final AppTheme theme;
  final bool isPaired;
  final ValueChanged<int> onTap;
  /// Круглая боковая кнопка справа от навбара. Тап — [onCreatePin]; null прячет
  /// кнопку. На главной морфится в стрелку → (открыть Ленту) либо плюс +
  /// (создать пин) — управляется [sideIsArrow]. В Ленте всегда плюс.
  final VoidCallback? onCreatePin;

  /// true → иконка-стрелка → (открыть Ленту); false → плюс + (создать пин).
  final bool sideIsArrow;

  /// Удержание боковой кнопки — переключить стрелку ↔ плюс. null отключает.
  final VoidCallback? onSideLongPress;

  /// Ключ боковой кнопки — для позиционирования одноразовой подсказки.
  final Key? sideButtonKey;

  const HomeBottomNav({
    super.key,
    required this.selectedIndex,
    required this.theme,
    required this.isPaired,
    required this.onTap,
    this.onCreatePin,
    this.sideIsArrow = false,
    this.onSideLongPress,
    this.sideButtonKey,
  });

  static const String _homeIcon =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-6">\n  <path d="M11.47 3.841a.75.75 0 0 1 1.06 0l8.69 8.69a.75.75 0 1 0 1.06-1.061l-8.689-8.69a2.25 2.25 0 0 0-3.182 0l-8.69 8.69a.75.75 0 1 0 1.061 1.06l8.69-8.689Z" />\n  <path d="m12 5.432 8.159 8.159c.03.03.06.058.091.086v6.198c0 1.035-.84 1.875-1.875 1.875H15a.75.75 0 0 1-.75-.75v-4.5a.75.75 0 0 0-.75-.75h-3a.75.75 0 0 0-.75.75V21a.75.75 0 0 1-.75.75H5.625a1.875 1.875 0 0 1-1.875-1.875v-6.198a2.29 2.29 0 0 0 .091-.086L12 5.432Z" />\n</svg>';

  static const String _widgetsIcon =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-6">\n  <path d="M5.566 4.657A4.505 4.505 0 0 1 6.75 4.5h10.5c.41 0 .806.055 1.183.157A3 3 0 0 0 15.75 3h-7.5a3 3 0 0 0-2.684 1.657ZM2.25 12a3 3 0 0 1 3-3h13.5a3 3 0 0 1 3 3v6a3 3 0 0 1-3 3H5.25a3 3 0 0 1-3-3v-6ZM5.25 7.5c-.41 0-.806.055-1.184.157A3 3 0 0 1 6.75 6h10.5a3 3 0 0 1 2.683 1.657A4.505 4.505 0 0 0 18.75 7.5H5.25Z" />\n</svg>';

  static const String _invitesIcon =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-6">\n  <path d="M4.913 2.658c2.075-.27 4.19-.408 6.337-.408 2.147 0 4.262.139 6.337.408 1.922.25 3.291 1.861 3.405 3.727a4.403 4.403 0 0 0-1.032-.211 50.89 50.89 0 0 0-8.42 0c-2.358.196-4.04 2.19-4.04 4.434v4.286a4.47 4.47 0 0 0 2.433 3.984L7.28 21.53A.75.75 0 0 1 6 21v-4.03a48.527 48.527 0 0 1-1.087-.128C2.905 16.58 1.5 14.833 1.5 12.862V6.638c0-1.97 1.405-3.718 3.413-3.979Z" />\n  <path d="M15.75 7.5c-1.376 0-2.739.057-4.086.169C10.124 7.797 9 9.103 9 10.609v4.285c0 1.507 1.128 2.814 2.67 2.94 1.243.102 2.5.157 3.768.165l2.782 2.781a.75.75 0 0 0 1.28-.53v-2.39l.33-.026c1.542-.125 2.67-1.433 2.67-2.94v-4.286c0-1.505-1.125-2.811-2.664-2.94A49.392 49.392 0 0 0 15.75 7.5Z" />\n</svg>';

  static const String _watchIcon =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-6">\n  <path fill-rule="evenodd" d="M4.5 3.75A2.25 2.25 0 0 0 2.25 6v9A2.25 2.25 0 0 0 4.5 17.25h15A2.25 2.25 0 0 0 21.75 15V6a2.25 2.25 0 0 0-2.25-2.25h-15Zm5.03 3.47a.75.75 0 0 0-1.28.53v5.5a.75.75 0 0 0 1.14.64l4.5-2.75a.75.75 0 0 0 0-1.28l-4.5-2.75a.75.75 0 0 0-.36-.11Z" clip-rule="evenodd" />\n  <path d="M8.25 19.5h7.5a.75.75 0 0 1 0 1.5h-7.5a.75.75 0 0 1 0-1.5Z" />\n</svg>';

  static const String _profileIcon =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-6">\n  <path fill-rule="evenodd" d="M18.685 19.097A9.723 9.723 0 0 0 21.75 12c0-5.385-4.365-9.75-9.75-9.75S2.25 6.615 2.25 12a9.723 9.723 0 0 0 3.065 7.097A9.716 9.716 0 0 0 12 21.75a9.716 9.716 0 0 0 6.685-2.653Zm-12.54-1.285A7.486 7.486 0 0 1 12 15a7.486 7.486 0 0 1 5.855 2.812A8.224 8.224 0 0 1 12 20.25a8.224 8.224 0 0 1-5.855-2.438ZM15.75 9a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0Z" clip-rule="evenodd" />\n</svg>';

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    final activeColor = theme.navActiveIcon;
    final activeBg = theme.navActiveIcon.withValues(alpha:0.12);
    final inactiveColor = Color.lerp(theme.navActiveIcon, theme.cardSurface, 0.5)!; // светлее, ближе к фону карточек
    final primary = theme.primary;

    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 20 + bottomInset),
      child: Row(
        children: [
          Expanded(
            child: Container(
        decoration: BoxDecoration(
          color: theme.cardSurface,
          borderRadius: BorderRadius.circular(100),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 32,
              spreadRadius: 0,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: primary.withValues(alpha: 0.05),
              blurRadius: 12,
              spreadRadius: -2,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                NavBarItem(
                  svgIcon: _homeIcon,
                  index: 0,
                  label: s.home,
                  isActive: selectedIndex == 0,
                  activeColor: activeColor,
                  activeBg: activeBg,
                  inactiveColor: inactiveColor,
                  badgeColor: primary,
                  onTap: () => onTap(0),
                ),
                NavBarItem(
                  svgIcon: _widgetsIcon,
                  index: 1,
                  label: s.widgets,
                  isActive: selectedIndex == 1,
                  activeColor: activeColor,
                  activeBg: activeBg,
                  inactiveColor: inactiveColor,
                  badgeColor: primary,
                  onTap: () => onTap(1),
                ),
                NavBarItem(
                  svgIcon: _watchIcon,
                  index: 4,
                  label: s.watchTogether,
                  isActive: selectedIndex == 4,
                  activeColor: activeColor,
                  activeBg: activeBg,
                  inactiveColor: inactiveColor,
                  badgeColor: primary,
                  onTap: () => onTap(4),
                ),
                NavBarItem(
                  svgIcon: _invitesIcon,
                  index: 2,
                  label: s.connect,
                  isActive: selectedIndex == 2,
                  activeColor: activeColor,
                  activeBg: activeBg,
                  inactiveColor: inactiveColor,
                  badgeColor: primary,
                  showBadge: !isPaired,
                  onTap: () => onTap(2),
                ),
                NavBarItem(
                  svgIcon: _profileIcon,
                  index: 3,
                  label: s.profile,
                  isActive: selectedIndex == 3,
                  activeColor: activeColor,
                  activeBg: activeBg,
                  inactiveColor: inactiveColor,
                  badgeColor: primary,
                  onTap: () => onTap(3),
                ),
              ],
            ),
          ),
            ),
          ),
          if (onCreatePin != null) ...[
            const SizedBox(width: 12),
            // Hero делает кнопку «непрерывной» при переходе главная↔Лента —
            // круг остаётся на месте, пока экраны сменяются, а иконка
            // оказывается уже «плюсом» в Ленте. Тег общий для обоих экранов.
            Hero(
              tag: 'home_side_action_button',
              child: _CreatePinButton(
                buttonKey: sideButtonKey,
                color: theme.fillColor,
                isArrow: sideIsArrow,
                onTap: onCreatePin!,
                onLongPress: onSideLongPress,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Круглая боковая кнопка справа от навбара. Иконка плавно морфится между
/// стрелкой → (открыть Ленту) и плюсом + (создать пин) через AnimatedSwitcher.
class _CreatePinButton extends StatelessWidget {
  final Color color;
  final bool isArrow;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Key? buttonKey;

  const _CreatePinButton({
    required this.color,
    required this.isArrow,
    required this.onTap,
    this.onLongPress,
    this.buttonKey,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      key: buttonKey,
      color: color,
      shape: const CircleBorder(),
      elevation: 6,
      shadowColor: color.withValues(alpha: 0.45),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 56,
          height: 56,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutBack,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) => RotationTransition(
              turns: Tween<double>(begin: 0.7, end: 1.0).animate(anim),
              child: ScaleTransition(
                scale: anim,
                child: FadeTransition(opacity: anim, child: child),
              ),
            ),
            child: Icon(
              isArrow ? Icons.arrow_forward_rounded : Icons.add_rounded,
              key: ValueKey<bool>(isArrow),
              color: Colors.white,
              size: 30,
            ),
          ),
        ),
      ),
    );
  }
}
