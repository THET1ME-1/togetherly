import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import '../services/live_location_service.dart';
import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_scope.dart';
import '../widgets/storage_image.dart';
import '../utils/safe_text.dart';

/// Цвет аватарки партнёра на карте (контраст к теме пользователя).
const Color _kPartnerColor = Color(0xFFFF5C8A);

/// Полноэкранная карта «Где мы»: обе аватарки в реальном времени, пунктир
/// между ними и дистанция (см/м/км). При открытии — плавный перелёт на
/// аватарку партнёра.
class LiveMapScreen extends StatefulWidget {
  final String pairId;
  final String partnerUid;
  final String partnerName;
  final String partnerAvatarUrl;
  final String myAvatarUrl;
  final AppTheme theme;

  /// Стартовый центр (обычно «обе точки» из превью), чтобы перелёт читался.
  final LatLng? initialCenter;
  final double initialZoom;

  const LiveMapScreen({
    super.key,
    required this.pairId,
    required this.partnerUid,
    required this.partnerName,
    required this.partnerAvatarUrl,
    required this.myAvatarUrl,
    required this.theme,
    this.initialCenter,
    this.initialZoom = 13,
  });

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();

  StreamSubscription<LivePoint?>? _partnerSub;
  StreamSubscription<Position>? _meSub;

  LatLng? _me;
  LivePoint? _partner;
  bool _mapReady = false;
  bool _focusedPartner = false;

  AnimationController? _moveCtrl;

  @override
  void initState() {
    super.initState();
    _partnerSub = LiveLocationService.instance
        .watchPartner(widget.pairId, widget.partnerUid)
        .listen(_onPartner);
    _startMyStream();
  }

  @override
  void dispose() {
    _partnerSub?.cancel();
    _meSub?.cancel();
    _moveCtrl?.dispose();
    super.dispose();
  }

  Future<void> _startMyStream() async {
    try {
      // Немедленный фикс, чтобы своя аватарка не ждала первого шага.
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (mounted) setState(() => _me = LatLng(pos.latitude, pos.longitude));
    } catch (_) {}
    _meSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((pos) {
      if (mounted) setState(() => _me = LatLng(pos.latitude, pos.longitude));
    }, onError: (_) {});
  }

  void _onPartner(LivePoint? p) {
    if (!mounted) return;
    setState(() => _partner = p);
    // Один раз плавно перелетаем на аватарку партнёра.
    if (p != null && !_focusedPartner && _mapReady) {
      _focusedPartner = true;
      _animatedMapMove(p.latLng, 16.5);
    }
  }

  // ── Плавное перемещение камеры ────────────────────────────────────────────
  void _animatedMapMove(LatLng dest, double destZoom) {
    // До onMapReady (и после dispose) внутреннее состояние карты не создано, и
    // `_mapController.camera`/`.move` бросают "Null check operator used on a
    // null value". Кнопки могут сработать раньше готовности карты, а анимация —
    // дотикать уже после ухода с экрана. Гардим mounted+_mapReady и оборачиваем
    // все обращения к карте в try/catch. См. Bugsink #24 (топ-краш экрана).
    if (!_mapReady || !mounted) return;
    final LatLng center;
    final double zoom;
    try {
      final camera = _mapController.camera;
      center = camera.center;
      zoom = camera.zoom;
    } catch (_) {
      return; // карта ещё/уже не готова
    }
    final latTween = Tween<double>(begin: center.latitude, end: dest.latitude);
    final lngTween =
        Tween<double>(begin: center.longitude, end: dest.longitude);
    final zoomTween = Tween<double>(begin: zoom, end: destZoom);

    _moveCtrl?.dispose();
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _moveCtrl = ctrl;
    final anim = CurvedAnimation(parent: ctrl, curve: Curves.easeInOutCubic);
    ctrl.addListener(() {
      if (!mounted || !_mapReady) return;
      try {
        _mapController.move(
          LatLng(latTween.evaluate(anim), lngTween.evaluate(anim)),
          zoomTween.evaluate(anim),
        );
      } catch (_) {
        ctrl.stop(); // карта уничтожена во время анимации — тихо останавливаемся
      }
    });
    ctrl.forward();
  }

  void _centerOnMe() {
    if (_me != null) _animatedMapMove(_me!, 16.5);
  }

  void _showBoth() {
    if (!_mapReady || !mounted) return; // fitCamera тоже читает состояние карты
    final me = _me;
    final partner = _partner?.latLng;
    if (me != null && partner != null) {
      _moveCtrl?.dispose();
      try {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: [me, partner],
            padding: const EdgeInsets.all(90),
            maxZoom: 16.5,
          ),
        );
      } catch (_) {}
    } else if (partner != null) {
      _animatedMapMove(partner, 16);
    } else if (me != null) {
      _animatedMapMove(me, 16);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final primary = widget.theme.primary;
    final bottom = MediaQuery.of(context).padding.bottom;
    final me = _me;
    final partner = _partner;

    final center = widget.initialCenter ??
        partner?.latLng ??
        me ??
        const LatLng(47.0105, 28.8638);

    return Scaffold(
      backgroundColor: widget.theme.bgGradient[0],
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: widget.initialZoom,
              minZoom: 2,
              maxZoom: 18,
              onMapReady: () {
                _mapReady = true;
                // Если точка партнёра уже есть — перелетаем после готовности.
                // Захватываем p локально: _partner может обнулиться до postFrame.
                final p = _partner;
                if (p != null && !_focusedPartner) {
                  _focusedPartner = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _animatedMapMove(p.latLng, 16.5);
                  });
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.togetherly.love',
                maxNativeZoom: 19,
              ),
              if (me != null && partner != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [me, partner.latLng],
                      strokeWidth: 3,
                      color: primary.withValues(alpha: 0.8),
                      pattern: StrokePattern.dashed(
                        segments: const [11, 7],
                      ),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (partner != null)
                    Marker(
                      point: partner.latLng,
                      width: 72,
                      height: 86,
                      alignment: Alignment.topCenter,
                      child: _AvatarMarker(
                        avatarUrl: widget.partnerAvatarUrl,
                        name: widget.partnerName,
                        ringColor: _kPartnerColor,
                        stale: _isStale(partner.updatedAt),
                      ),
                    ),
                  if (me != null)
                    Marker(
                      point: me,
                      width: 72,
                      height: 86,
                      alignment: Alignment.topCenter,
                      child: _AvatarMarker(
                        avatarUrl: widget.myAvatarUrl,
                        name: LocaleService.current.liveMapYou,
                        ringColor: primary,
                        stale: false,
                      ),
                    ),
                ],
              ),
            ],
          ),

          // ── Верх: назад + дистанция ────────────────────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Row(
                children: [
                  _RoundIconButton(
                    icon: Icons.arrow_back_rounded,
                    onTap: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  _DistancePill(me: me, partner: partner?.latLng),
                  const Spacer(),
                  const SizedBox(width: 42),
                ],
              ),
            ),
          ),

          // ── FAB-ы ───────────────────────────────────────────────────────
          Positioned(
            right: 14,
            bottom: bottom + 28,
            child: Column(
              children: [
                _RoundIconButton(
                  icon: Icons.people_alt_rounded,
                  tooltip: LocaleService.current.liveMapShowBoth,
                  onTap: _showBoth,
                  color: primary,
                ),
                const SizedBox(height: 12),
                _RoundIconButton(
                  icon: Icons.my_location_rounded,
                  tooltip: LocaleService.current.liveMapCenterMe,
                  onTap: _centerOnMe,
                  color: primary,
                ),
              ],
            ),
          ),

          // ── Ожидание партнёра ───────────────────────────────────────────
          if (partner == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: bottom + 28,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(
                    color: widget.theme.cardSurface,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        LocaleService.current.liveMapWaitingPartner,
                        style: GoogleFonts.rubik(
                          fontSize: 13,
                          color: widget.theme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _isStale(int updatedAt) {
    if (updatedAt <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - updatedAt > 5 * 60 * 1000; // >5 минут
  }
}

// ── Аватарка-маркер ───────────────────────────────────────────────────────
class _AvatarMarker extends StatelessWidget {
  final String avatarUrl;
  final String name;
  final Color ringColor;
  final bool stale;

  const _AvatarMarker({
    required this.avatarUrl,
    required this.name,
    required this.ringColor,
    required this.stale,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.firstGraphemeUpper('♥');
    final fallback = Container(
      color: ringColor.withValues(alpha: 0.18),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: ringColor,
          fontWeight: FontWeight.w800,
          fontSize: 18,
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: stale ? 0.55 : 1,
          child: Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: ringColor, width: 3),
              boxShadow: [
                BoxShadow(
                  color: ringColor.withValues(alpha: 0.45),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: ClipOval(
              child: Container(
                color: Colors.white,
                child: avatarUrl.isEmpty
                    ? fallback
                    : StorageImage(
                        imageUrl: avatarUrl,
                        fit: BoxFit.cover,
                        memCacheWidth: 160,
                        memCacheHeight: 160,
                        errorWidget: (_, _, _) => fallback,
                      ),
              ),
            ),
          ),
        ),
        // Хвостик-указатель.
        Transform.translate(
          offset: const Offset(0, -2),
          child: CustomPaint(
            size: const Size(14, 9),
            painter: _PinTailPainter(ringColor),
          ),
        ),
      ],
    );
  }
}

class _PinTailPainter extends CustomPainter {
  final Color color;
  _PinTailPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_PinTailPainter old) => old.color != color;
}

// ── Бейдж дистанции ───────────────────────────────────────────────────────
class _DistancePill extends StatelessWidget {
  final LatLng? me;
  final LatLng? partner;
  const _DistancePill({this.me, this.partner});

  @override
  Widget build(BuildContext context) {
    if (me == null || partner == null) return const SizedBox.shrink();
    final t = context.appTheme;
    final meters = LiveLocationService.distanceMeters(me!, partner!);
    final text = LiveLocationService.formatDistance(meters);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: t.cardSurface,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.favorite_rounded, size: 16, color: _kPartnerColor),
          const SizedBox(width: 8),
          Text(
            text,
            style: GoogleFonts.rubik(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: t.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? color;

  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    final btn = GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: t.cardSurface,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.13),
              blurRadius: 10,
            ),
          ],
        ),
        child: Icon(icon, color: color ?? t.textPrimary, size: 22),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}
