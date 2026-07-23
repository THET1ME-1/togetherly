import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

/// Набор символов кода-приглашения (== Connection.generateLocalCode: без 0/1/I/O,
/// чтобы не путались). «Дешифратор» гоняет именно эти глифы, поэтому бегущие
/// символы выглядят настоящими и корректно замирают на коде.
const String kInviteAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

// ─────────────────────────────────────────────────────────────────────────────
//  Аутентичные формы M3 (material_new_shapes) как клиппер/путь
// ─────────────────────────────────────────────────────────────────────────────

/// Вписывает готовый путь [raw] в прямоугольник [size] по центру (bounds-fit).
Path fitPathToSize(Path raw, Size size) {
  final b = raw.getBounds();
  if (b.width == 0 || b.height == 0) return raw;
  final scale = math.min(size.width / b.width, size.height / b.height);
  final dx = (size.width - b.width * scale) / 2 - b.left * scale;
  final dy = (size.height - b.height * scale) / 2 - b.top * scale;
  // Аффинная матрица 4x4 (column-major): масштаб на диагонали, сдвиг в col3.
  final storage = Float64List.fromList(<double>[
    scale, 0, 0, 0,
    0, scale, 0, 0,
    0, 0, 1, 0,
    dx, dy, 0, 1,
  ]);
  return raw.transform(storage);
}

/// Вписывает аутентичную M3-форму [poly] в прямоугольник [size] по центру.
Path m3ShapePath(RoundedPolygon poly, Size size) =>
    fitPathToSize(poly.toPath(), size);

/// Клиппер по аутентичной M3-форме — обрезает любого ребёнка (напр. букву внутрь
/// «печеньки»). Именно этого не умеет пакет material_shapes.
class M3ShapeClipper extends CustomClipper<Path> {
  final RoundedPolygon polygon;
  const M3ShapeClipper(this.polygon);

  @override
  Path getClip(Size size) => m3ShapePath(polygon, size);

  @override
  bool shouldReclip(covariant M3ShapeClipper old) => old.polygon != polygon;
}

/// Аватар в аутентичной форме «печенька» (M3 `cookie12Sided`) с инициалом.
class CookieAvatar extends StatelessWidget {
  final double size;
  final Color color;
  final Color onColor;
  final String initial;
  const CookieAvatar({
    super.key,
    required this.size,
    required this.color,
    required this.onColor,
    required this.initial,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipPath(
        clipper: M3ShapeClipper(MaterialShapes.cookie12Sided),
        child: Container(
          color: color,
          alignment: Alignment.center,
          child: Text(
            initial,
            style: TextStyle(
              fontFamily: 'Unbounded',
              fontWeight: FontWeight.w700,
              fontSize: size * 0.4,
              color: onColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Обрезает произвольного ребёнка (фото партнёра) в аутентичную «печеньку».
class CookieClip extends StatelessWidget {
  final double size;
  final Widget child;
  const CookieClip({super.key, required this.size, required this.child});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: ClipPath(
          clipper: M3ShapeClipper(MaterialShapes.cookie12Sided),
          child: child,
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
//  Пунктирное кольцо — «слот» ещё не подключённого партнёра
// ─────────────────────────────────────────────────────────────────────────────
class DashedRing extends StatelessWidget {
  final double size;
  final Color color;
  final Widget? child;
  const DashedRing({super.key, required this.size, required this.color, this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DashedRingPainter(color),
        child: Center(child: child),
      ),
    );
  }
}

class _DashedRingPainter extends CustomPainter {
  final Color color;
  _DashedRingPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 - 1.5;
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = color;
    const dashes = 18;
    final rect = Rect.fromCircle(center: center, radius: r);
    for (int i = 0; i < dashes; i++) {
      final a0 = 2 * math.pi * i / dashes;
      final sweep = (2 * math.pi / dashes) * 0.55;
      canvas.drawArc(rect, a0, sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRingPainter old) => old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Пружинное нажатие (M3 state layer feel): чуть проседает по тапу
// ─────────────────────────────────────────────────────────────────────────────
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.96,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;
  void _set(bool v) {
    if (mounted && _down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Код-«дешифратор»: каждый символ бежит сменой глифов (A→B→…→9), пока loading —
//  цикл; код готов — позиции по очереди (стаггер) замирают на своих символах.
// ─────────────────────────────────────────────────────────────────────────────
class AnimatedInviteCode extends StatefulWidget {
  final String code;
  final bool loading;
  final Color color;
  final double fontSize;
  const AnimatedInviteCode({
    super.key,
    required this.code,
    required this.loading,
    required this.color,
    this.fontSize = 52,
  });

  @override
  State<AnimatedInviteCode> createState() => _AnimatedInviteCodeState();
}

class _AnimatedInviteCodeState extends State<AnimatedInviteCode> {
  static const int _len = 6;
  Timer? _timer;
  int _tick = 0;
  late List<bool> _settled;

  bool get _ready => widget.code.length >= _len;

  @override
  void initState() {
    super.initState();
    _settled = List.filled(_len, false);
    _startSpin();
    // На входе: код уже есть — короткий «дешифратор» и посадка (эффектный вход).
    if (!widget.loading && _ready) _scheduleSettle(initialDelayMs: 360);
  }

  void _startSpin() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 65), (_) {
      if (mounted) setState(() => _tick++);
    });
  }

  void _stopIfDone() {
    if (_settled.every((s) => s)) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _scheduleSettle({int initialDelayMs = 0}) {
    for (int i = 0; i < _len; i++) {
      Future.delayed(Duration(milliseconds: initialDelayMs + i * 95), () {
        if (!mounted) return;
        setState(() => _settled[i] = true);
        _stopIfDone();
      });
    }
  }

  void _rescramble() {
    setState(() => _settled = List.filled(_len, false));
    _startSpin();
  }

  @override
  void didUpdateWidget(covariant AnimatedInviteCode old) {
    super.didUpdateWidget(old);
    if (widget.loading && !old.loading) {
      _rescramble(); // пошла генерация → снова цикл
    } else if (!widget.loading && _ready && (old.loading || widget.code != old.code)) {
      _rescramble();
      _scheduleSettle(); // код готов/сменился → пересобрать и посадить по очереди
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Ширину ячейки берём от доступной ширины → влезает на любом экране,
        // фиксированные ячейки не дают ряду «прыгать» при смене глифов.
        final avail = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : widget.fontSize * _len;
        final cellW = avail / _len;
        final fs = math.min(widget.fontSize, cellW * 0.92);
        return Row(
          mainAxisSize: MainAxisSize.max,
          children: List.generate(_len, (i) {
            final settled = _settled[i] && _ready;
            final ch = settled
                ? widget.code[i]
                : kInviteAlphabet[(_tick + i * 5) % kInviteAlphabet.length];
            return SizedBox(
              width: cellW,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 70),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: ScaleTransition(
                    scale: Tween(begin: 0.7, end: 1.0).animate(anim),
                    child: child,
                  ),
                ),
                child: Text(
                  ch,
                  key: ValueKey('$i-$ch-$settled'),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Unbounded',
                    fontWeight: FontWeight.w800,
                    fontSize: fs,
                    height: 1.0,
                    color: widget.color,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Бегущая строка «телесуфлёр»: влезает — стоит по центру; не влезает — едет
//  справа налево по кругу (две копии + разрыв → бесшовный цикл).
// ─────────────────────────────────────────────────────────────────────────────
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final double velocity; // px/сек
  final double gap; // разрыв между копиями
  const MarqueeText(this.text,
      {super.key, required this.style, this.velocity = 30, this.gap = 44});

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  double _textW = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this);
    _measure();
  }

  void _measure() {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _textW = tp.width;
    final loopW = _textW + widget.gap;
    _ctrl.duration = Duration(
        milliseconds:
            (loopW / widget.velocity * 1000).round().clamp(1500, 20000));
  }

  @override
  void didUpdateWidget(covariant MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) _measure();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final maxW = box.maxWidth;
        final fits = !maxW.isFinite || _textW <= maxW;
        if (fits) {
          if (_ctrl.isAnimating) _ctrl.stop();
          return Align(
            alignment: Alignment.center,
            child: Text(widget.text,
                maxLines: 1, softWrap: false, style: widget.style),
          );
        }
        if (!_ctrl.isAnimating) _ctrl.repeat();
        final loopW = _textW + widget.gap;
        return ClipRect(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              return OverflowBox(
                maxWidth: double.infinity,
                alignment: Alignment.centerLeft,
                child: Transform.translate(
                  offset: Offset(-loopW * _ctrl.value, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.text,
                          maxLines: 1, softWrap: false, style: widget.style),
                      SizedBox(width: widget.gap),
                      Text(widget.text,
                          maxLines: 1, softWrap: false, style: widget.style),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
//  Уникальная M3-форма на аватарку партнёра + морфинг при смене группы
// ─────────────────────────────────────────────────────────────────────────────

/// Набор форм, на которых аватарка хорошо видна: гладкие/выпуклые, без шипов
/// и глубоких вырезов (колючие sunny/burst/boom и пушистые puffy/flower убраны).
final List<RoundedPolygon> kAvatarShapes = [
  MaterialShapes.cookie12Sided,
  MaterialShapes.cookie9Sided,
  MaterialShapes.cookie7Sided,
  MaterialShapes.cookie6Sided,
  MaterialShapes.gem,
  MaterialShapes.pentagon,
  MaterialShapes.puffyDiamond,
  MaterialShapes.diamond,
  MaterialShapes.pill,
  MaterialShapes.oval,
  MaterialShapes.clamShell,
  MaterialShapes.arch,
  MaterialShapes.slanted,
  MaterialShapes.square,
];

/// Индекс формы по умолчанию для партнёра (детерминированно по uid).
int defaultShapeIndexForUid(String uid) {
  if (uid.isEmpty) return 0;
  var h = 0;
  for (final c in uid.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h % kAvatarShapes.length;
}

/// Стабильная форма для партнёра по его uid.
RoundedPolygon avatarShapeForUid(String uid) =>
    kAvatarShapes[defaultShapeIndexForUid(uid)];

/// Аватар в уникальной форме партнёра; при смене [shapeKey] форма плавно
/// морфится в новую (M3 Morph). [child] — фото/инициал, обрезается формой.
class MorphAvatar extends StatefulWidget {
  final double size;
  final Object shapeKey; // uid — определяет форму и момент морфинга
  final RoundedPolygon shape;
  final Widget child;
  const MorphAvatar({
    super.key,
    required this.size,
    required this.shapeKey,
    required this.shape,
    required this.child,
  });

  @override
  State<MorphAvatar> createState() => _MorphAvatarState();
}

class _MorphAvatarState extends State<MorphAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late RoundedPolygon _from;
  late RoundedPolygon _to;
  Morph? _morph;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 520));
    _from = widget.shape;
    _to = widget.shape;
    _c.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant MorphAvatar old) {
    super.didUpdateWidget(old);
    if (widget.shapeKey != old.shapeKey) {
      _from = old.shape;
      _to = widget.shape;
      _morph = Morph(_from, _to);
      _c.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => ClipPath(
          clipper: _MorphClipper(_to, _morph, _c.value),
          child: widget.child,
        ),
      ),
    );
  }
}

class _MorphClipper extends CustomClipper<Path> {
  final RoundedPolygon target;
  final Morph? morph;
  final double t;
  const _MorphClipper(this.target, this.morph, this.t);

  @override
  Path getClip(Size size) {
    if (morph == null || t >= 1.0) {
      return fitPathToSize(target.toPath(), size);
    }
    final e = Curves.easeOutCubic.transform(t);
    return fitPathToSize(morph!.toPath(progress: e), size);
  }

  @override
  bool shouldReclip(covariant _MorphClipper old) => old.t != t;
}
