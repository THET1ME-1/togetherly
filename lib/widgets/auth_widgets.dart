import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/theme_scope.dart';
import '../theme/profile_theme.dart';

/// Общие виджеты экранов входа/регистрации (единый стиль «карточка + поля с
/// плавающей подписью + ряд соц-иконок»). [accent] берётся из вызывающего
/// экрана (вход — розовый, регистрация — по полу), чтобы рамка/подпись поля
/// и кнопки красились темой.

/// Поле с плавающей подписью: подпись всегда на верхней границе, плейсхолдер
/// внутри. Для пароля — встроенный тоггл видимости.
class AuthField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final Color accent;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final bool isPassword;
  final ValueChanged<String>? onChanged;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  const AuthField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    required this.accent,
    this.keyboardType = TextInputType.text,
    this.inputFormatters,
    this.isPassword = false,
    this.onChanged,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
  });

  @override
  State<AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<AuthField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    final cs = ProfileTheme.themeFor(t).colorScheme;
    // M3: поле-таблетка, filled тональным, без рамки (только тонкий фокус-ринг).
    return TextField(
      controller: widget.controller,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      obscureText: widget.isPassword && _obscure,
      onChanged: widget.onChanged,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      cursorColor: cs.primary,
      style: TextStyle(
        fontFamily: 'Onest',
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: cs.onSurface,
      ),
      decoration: InputDecoration(
        labelText: widget.label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        labelStyle: TextStyle(
          fontFamily: 'Onest',
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: cs.onSurfaceVariant,
        ),
        floatingLabelStyle: TextStyle(
          fontFamily: 'Onest',
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: cs.primary,
        ),
        hintText: widget.hint,
        hintStyle: TextStyle(
          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
          fontWeight: FontWeight.w400,
          fontSize: 14,
        ),
        filled: true,
        fillColor: cs.surfaceContainerHighest,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        suffixIcon: widget.isPassword
            ? GestureDetector(
                onTap: () => setState(() => _obscure = !_obscure),
                child: Icon(
                  _obscure
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  color: cs.onSurfaceVariant,
                  size: 20,
                ),
              )
            : null,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(999)),
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(999)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(999)),
          borderSide: BorderSide(color: cs.primary, width: 1.6),
        ),
      ),
    );
  }
}

/// «Войти через …» — разделитель + ряд соц-иконок. Показываются те провайдеры,
/// для которых передан колбэк (Apple обычно только на iOS). Перенос на новую
/// строку — через Wrap, чтобы 4-5 иконок не вылезали на узких экранах.
class AuthSocialRow extends StatelessWidget {
  final String label;
  final VoidCallback? onGoogle;
  final VoidCallback? onApple;
  final VoidCallback? onYandex;
  final VoidCallback? onVk;
  final VoidCallback? onFacebook;

  const AuthSocialRow({
    super.key,
    required this.label,
    this.onGoogle,
    this.onApple,
    this.onYandex,
    this.onVk,
    this.onFacebook,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    final icons = <Widget>[
      if (onGoogle != null)
        AuthSocialIcon(onTap: onGoogle, child: const GoogleLogo(size: 22)),
      if (onYandex != null)
        AuthSocialIcon(onTap: onYandex, child: const _YandexGlyph()),
      if (onVk != null) AuthSocialIcon(onTap: onVk, child: const _VkGlyph()),
      if (onFacebook != null)
        AuthSocialIcon(
          onTap: onFacebook,
          child: const Icon(Icons.facebook, size: 28, color: Color(0xFF1877F2)),
        ),
      if (onApple != null)
        AuthSocialIcon(
          onTap: onApple,
          child: Icon(Icons.apple, size: 26, color: t.textPrimary),
        ),
    ];

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: Divider(color: t.divider)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: t.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(child: Divider(color: t.divider)),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 14,
          runSpacing: 12,
          children: icons,
        ),
      ],
    );
  }
}

/// Круглая соц-кнопка-иконка.
class AuthSocialIcon extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  const AuthSocialIcon({super.key, required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    final cs = ProfileTheme.themeFor(t).colorScheme;
    // Плоский круг без рамки: та же тональная поверхность, что у полей-таблеток.
    return Material(
      color: cs.surfaceContainerHighest,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 50, height: 50, child: Center(child: child)),
      ),
    );
  }
}

/// Бренд-глиф Яндекса: красный кругляш-квадрат с белой «Я».
class _YandexGlyph extends StatelessWidget {
  const _YandexGlyph();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: const Color(0xFFFC3F1D),
        borderRadius: BorderRadius.circular(7),
      ),
      alignment: Alignment.center,
      child: const Text(
        'Я',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 16,
          height: 1,
        ),
      ),
    );
  }
}

/// Бренд-глиф ВКонтакте: синий бейдж «VK».
class _VkGlyph extends StatelessWidget {
  const _VkGlyph();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 21,
      decoration: BoxDecoration(
        color: const Color(0xFF0077FF),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: const Text(
        'VK',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 11,
          height: 1,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Многоцветный логотип Google (без сетевых ассетов).
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleLogoPainter()),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = Offset(r, r);
    final sw = r * 0.22;
    final arcRect = Rect.fromCircle(center: center, radius: r - sw / 2);

    double rad(double deg) => deg * math.pi / 180;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..isAntiAlias = true;

    paint.color = const Color(0xFF34A853);
    canvas.drawArc(arcRect, rad(28), rad(54), false, paint);

    paint.color = const Color(0xFFFBBC05);
    canvas.drawArc(arcRect, rad(82), rad(90), false, paint);

    paint.color = const Color(0xFFEA4335);
    canvas.drawArc(arcRect, rad(172), rad(92), false, paint);

    paint.color = const Color(0xFF4285F4);
    canvas.drawArc(arcRect, rad(264), rad(66), false, paint);

    paint
      ..style = PaintingStyle.fill
      ..color = const Color(0xFF4285F4);
    canvas.drawRect(
      Rect.fromLTRB(r - sw * 0.15, r - sw / 2, r * 2 - sw * 0.5, r + sw / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(_GoogleLogoPainter oldDelegate) => false;
}
