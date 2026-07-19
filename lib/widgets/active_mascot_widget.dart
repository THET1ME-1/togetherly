import 'dart:async';
import 'storage_image.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/mascot.dart';
import '../services/locale_service.dart';
import '../services/mascot_service.dart';
import '../theme/app_theme.dart';

const String _kHiddenKey = 'mascot_hidden';
const String _kOnboardingKey = 'mascot_onboarding_shown';

/// Global notifier for the mascot's hidden state.
/// Listen to this in other widgets (e.g. home screen mascot row)
/// to react when the user hides/shows the floating mascot.
final ValueNotifier<bool> mascotHiddenNotifier = ValueNotifier<bool>(false);

/// Floating mascot overlay rendered inside the home screen Stack.
/// Draggable + pinch-to-scale. Position and scale sync via [MascotService].
class ActiveMascotWidget extends StatefulWidget {
  final MascotService mascotService;
  final AppTheme theme;
  final VoidCallback onOpenGallery;

  const ActiveMascotWidget({
    super.key,
    required this.mascotService,
    required this.theme,
    required this.onOpenGallery,
  });

  @override
  State<ActiveMascotWidget> createState() => _ActiveMascotWidgetState();
}

class _ActiveMascotWidgetState extends State<ActiveMascotWidget>
    with SingleTickerProviderStateMixin {
  bool _hidden = false;
  bool _onboardingShown = false;

  // Gesture tracking
  Offset _position = Offset.zero; // screen-space position of mascot center
  double _scale = 1.0;
  bool _positionInitialized = false;

  // Pinch state
  double _baseScale = 1.0;
  bool _isInteracting = false;

  // Push-debounce for Firestore writes
  Timer? _syncTimer;

  // Entrance animation
  late AnimationController _entranceCtrl;
  late Animation<double> _entranceAnim;

  MascotService get _svc => widget.mascotService;

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _entranceAnim = CurvedAnimation(
      parent: _entranceCtrl,
      curve: Curves.elasticOut,
    );

    _loadPrefs();
    _svc.addListener(_onServiceChanged);
    mascotHiddenNotifier.addListener(_onExternalVisibilityChanged);
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _syncTimer?.cancel();
    _svc.removeListener(_onServiceChanged);
    mascotHiddenNotifier.removeListener(_onExternalVisibilityChanged);
    super.dispose();
  }

  /// Called when another widget changes [mascotHiddenNotifier] (e.g. home row).
  void _onExternalVisibilityChanged() {
    final shouldHide = mascotHiddenNotifier.value;
    if (shouldHide != _hidden) {
      setState(() => _hidden = shouldHide);
      if (!shouldHide && _positionInitialized) {
        _entranceCtrl.forward(from: 0);
      }
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final hidden = prefs.getBool(_kHiddenKey) ?? false;
    if (mounted) {
      setState(() {
        _hidden = hidden;
        _onboardingShown = prefs.getBool(_kOnboardingKey) ?? false;
      });
    }
    mascotHiddenNotifier.value = hidden;
  }

  void _onServiceChanged() {
    final state = _svc.state;
    if (!mounted) return;

    if (!_positionInitialized && mounted) {
      // First sync: adopt group position/scale
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final size = MediaQuery.of(context).size;
        setState(() {
          _position = Offset(
            state.positionX * size.width,
            state.positionY * size.height,
          );
          _scale = state.scale.clamp(0.4, 3.0);
          _positionInitialized = true;
        });
        _entranceCtrl.forward(from: 0);
        if (!_onboardingShown) _showOnboarding();
      });
      return;
    }

    if (_positionInitialized && !_isInteracting) {
      final size = MediaQuery.of(context).size;
      final nextPosition = Offset(
        state.positionX * size.width,
        state.positionY * size.height,
      );
      final nextScale = state.scale.clamp(0.4, 3.0);
      final shouldUpdatePosition =
          (_position.dx - nextPosition.dx).abs() > 0.5 ||
          (_position.dy - nextPosition.dy).abs() > 0.5;
      final shouldUpdateScale = (_scale - nextScale).abs() > 0.01;

      if (shouldUpdatePosition || shouldUpdateScale) {
        setState(() {
          _position = nextPosition;
          _scale = nextScale;
          _clampPosition();
        });
        return;
      }
    }

    setState(() {});
  }

  void _showOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboardingKey, true);
    if (!mounted) return;

    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        bottom: 120,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 400),
              builder: (_, v, child) => Opacity(opacity: v, child: child),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  LocaleService.current.groupMascotBanner,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 3), () {
      entry.remove();
      if (mounted) setState(() => _onboardingShown = true);
    });
  }

  // ── Gestures ─────────────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    _isInteracting = true;
    _baseScale = _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      _scale = (_baseScale * d.scale).clamp(0.4, 3.0);
      _position += d.focalPointDelta;
      _clampPosition();
    });
    _scheduleSyncTimer();
  }

  void _onScaleEnd(ScaleEndDetails _) {
    _isInteracting = false;
    _scheduleSync();
  }

  void _clampPosition() {
    if (!mounted) return;
    final size = MediaQuery.of(context).size;
    final half = 40.0 * _scale;
    _position = Offset(
      _position.dx.clamp(half, size.width - half),
      _position.dy.clamp(half, size.height - half),
    );
  }

  void _scheduleSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 300), _scheduleSync);
  }

  void _scheduleSync() {
    if (!mounted) return;
    final size = MediaQuery.of(context).size;
    _svc.updatePosition(
      x: (_position.dx / size.width).clamp(0.0, 1.0),
      y: (_position.dy / size.height).clamp(0.0, 1.0),
      scale: _scale,
    );
  }

  // ── Menu ─────────────────────────────────────────────────────────────────

  void _onTap() {
    showModalBottomSheet(
      context: context,
      backgroundColor: widget.theme.cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: widget.theme.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: Icon(
                Icons.photo_library_outlined,
                color: widget.theme.primary,
              ),
              title: Text(LocaleService.current.goToGallery),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onOpenGallery();
              },
            ),
            ListTile(
              leading: Icon(
                Icons.visibility_off_outlined,
                color: widget.theme.textMuted,
              ),
              title: Text(LocaleService.current.hide),
              onTap: () async {
                Navigator.of(ctx).pop();
                setState(() => _hidden = true);
                mascotHiddenNotifier.value = true;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool(_kHiddenKey, true);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final mascot = _svc.activeMascot;
    if (mascot == null || _hidden || !_positionInitialized) {
      return const SizedBox.shrink();
    }

    final mascotSize = 80.0 * _scale;

    return Positioned(
      left: _position.dx - mascotSize / 2,
      top: _position.dy - mascotSize / 2,
      child: ScaleTransition(
        scale: _entranceAnim,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _onTap,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: SizedBox(
            width: mascotSize,
            height: mascotSize,
            child: _MascotImage(mascot: mascot, service: _svc),
          ),
        ),
      ),
    );
  }
}

// ── Mascot image renderer ─────────────────────────────────────────────────────

class _MascotImage extends StatelessWidget {
  final Mascot mascot;
  final MascotService service;

  const _MascotImage({required this.mascot, required this.service});

  @override
  Widget build(BuildContext context) {
    final asset = service.resolvedAssetForMood(mascot);
    if (asset != null) {
      return buildMascotAssetImage(asset, fit: BoxFit.contain);
    }
    if (mascot.catalogUrl != null) {
      return CachedNetworkImage(
        imageUrl: mascot.catalogUrl!,
        fit: BoxFit.contain,
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) => const Icon(Icons.face, size: 40),
      );
    }
    if (mascot.imageUrl != null) {
      return StorageImage(
        imageUrl: mascot.imageUrl!,
        fit: BoxFit.contain,
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) => const Icon(Icons.face, size: 40),
      );
    }
    return const Icon(Icons.face, size: 40);
  }
}

/// Renders a mascot from a local asset path.
/// Supports PNG/JPG (Image.asset) and SVG (SvgPicture.asset).
Widget buildMascotAssetImage(
  String assetPath, {
  BoxFit fit = BoxFit.contain,
  double? width,
  double? height,
}) {
  if (assetPath.toLowerCase().endsWith('.svg')) {
    return SvgPicture.asset(assetPath, fit: fit, width: width, height: height);
  }
  return Image.asset(
    assetPath,
    fit: fit,
    width: width,
    height: height,
    errorBuilder: (_, __, ___) => const Icon(Icons.face, size: 40),
  );
}

/// Un-hides the floating mascot from anywhere in the app.
Future<void> showMascotOverlay() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kHiddenKey, false);
  mascotHiddenNotifier.value = false;
}
