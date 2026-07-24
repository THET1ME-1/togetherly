import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/pb_auth_service.dart';
import '../../../services/pocketbase_service.dart';
import '../../../services/live_location_service.dart';
import '../../../services/locale_service.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/profile_theme.dart';
import '../../../widgets/storage_image.dart';
import '../../live_map_screen.dart';
import '../../../utils/safe_text.dart';

const String _kCollapsedKey = 'live_map_card_collapsed';
const Color _kPartnerColor = Color(0xFFFF5C8A);

/// Превью-карточка «Где мы» на главном экране (под блоком маскотов).
/// Прямоугольное превью карты с обеими аватарками; можно свернуть/развернуть
/// и открыть на весь экран. Масштаб превью подобран так, чтобы было видно
/// обоих.
class LiveMapCard extends StatefulWidget {
  final String pairId;
  final String partnerUid;
  final String partnerName;
  final String partnerAvatarUrl;
  final AppTheme theme;

  const LiveMapCard({
    super.key,
    required this.pairId,
    required this.partnerUid,
    required this.partnerName,
    required this.partnerAvatarUrl,
    required this.theme,
  });

  @override
  State<LiveMapCard> createState() => _LiveMapCardState();
}

class _LiveMapCardState extends State<LiveMapCard> {
  final MapController _mapController = MapController();

  StreamSubscription<LivePoint?>? _partnerSub;
  StreamSubscription<LivePoint?>? _meSub;

  LivePoint? _partner;
  LivePoint? _me;
  bool _collapsed = false;
  bool _mapReady = false;
  bool _prefsLoaded = false;

  String get _myUid => PocketBaseService().userId ?? '';
  String get _myAvatarUrl =>
      PbAuthService().currentProfile()?['avatarUrl'] as String? ?? '';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _subscribe();
    LiveLocationService.instance.sharingEnabled.addListener(_onSharingChanged);
  }

  @override
  void didUpdateWidget(covariant LiveMapCard old) {
    super.didUpdateWidget(old);
    if (old.pairId != widget.pairId || old.partnerUid != widget.partnerUid) {
      _subscribe();
    }
  }

  @override
  void dispose() {
    _partnerSub?.cancel();
    _meSub?.cancel();
    LiveLocationService.instance.sharingEnabled
        .removeListener(_onSharingChanged);
    super.dispose();
  }

  void _onSharingChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _collapsed = prefs.getBool(_kCollapsedKey) ?? false;
          _prefsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _prefsLoaded = true);
    }
  }

  void _subscribe() {
    _partnerSub?.cancel();
    _meSub?.cancel();
    final svc = LiveLocationService.instance;
    _partnerSub = svc.watchPartner(widget.pairId, widget.partnerUid).listen((p) {
      if (!mounted) return;
      setState(() => _partner = p);
      _fitBoth();
    });
    if (_myUid.isNotEmpty) {
      _meSub = svc.watchSelf(widget.pairId, widget.partnerUid).listen((p) {
        if (!mounted) return;
        setState(() => _me = p);
        _fitBoth();
      });
    }
  }

  Future<void> _toggleCollapsed() async {
    setState(() => _collapsed = !_collapsed);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kCollapsedKey, _collapsed);
    } catch (_) {}
    if (!_collapsed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitBoth());
    }
  }

  void _fitBoth() {
    if (!_mapReady || _collapsed) return;
    final me = _me?.latLng;
    final partner = _partner?.latLng;
    final pts = [?me, ?partner];
    if (pts.isEmpty) return;
    try {
      if (pts.length == 1) {
        _mapController.move(pts.first, 15);
      } else {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: pts,
            padding: const EdgeInsets.all(46),
            maxZoom: 16,
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _enableSharing() async {
    final ok = await LiveLocationService.instance.setSharingEnabled(
      true,
      pairId: widget.pairId,
      partnerUid: widget.partnerUid,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(LocaleService.current.liveMapPermissionDenied)),
      );
    }
  }

  Future<void> _disableSharing() async {
    await LiveLocationService.instance.setSharingEnabled(
      false,
      pairId: widget.pairId,
      partnerUid: widget.partnerUid,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(LocaleService.current.liveMapStopped)),
      );
    }
  }

  void _openFull() {
    final both = _bothCenter();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveMapScreen(
          pairId: widget.pairId,
          partnerUid: widget.partnerUid,
          partnerName: widget.partnerName,
          partnerAvatarUrl: widget.partnerAvatarUrl,
          myAvatarUrl: _myAvatarUrl,
          theme: widget.theme,
          initialCenter: both,
          initialZoom: both == null ? 13 : 14,
        ),
      ),
    );
  }

  LatLng? _bothCenter() {
    final me = _me?.latLng;
    final partner = _partner?.latLng;
    if (me != null && partner != null) {
      return LatLng(
        (me.latitude + partner.latitude) / 2,
        (me.longitude + partner.longitude) / 2,
      );
    }
    return me ?? partner;
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (!_prefsLoaded) return const SizedBox.shrink();
    final t = widget.theme;
    final cs = ProfileTheme.themeFor(t).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(t),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: _collapsed
                ? const SizedBox(width: double.infinity)
                : _preview(t),
          ),
        ],
      ),
    );
  }

  Widget _header(AppTheme t) {
    final cs = ProfileTheme.themeFor(t).colorScheme;
    return InkWell(
      onTap: _toggleCollapsed,
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.location_on_rounded,
                  color: cs.onPrimaryContainer, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                LocaleService.current.liveMapTitle,
                style: TextStyle(
                  fontFamily: ProfileTheme.displayFont,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (!_collapsed)
              GestureDetector(
                onTap: _openFull,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.open_in_full_rounded,
                      color: cs.primary, size: 20),
                ),
              ),
            AnimatedRotation(
              turns: _collapsed ? 0.5 : 0,
              duration: const Duration(milliseconds: 250),
              child: Icon(Icons.keyboard_arrow_up_rounded,
                  color: cs.onSurfaceVariant, size: 24),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview(AppTheme t) {
    final me = _me?.latLng;
    final partner = _partner?.latLng;
    final sharing = LiveLocationService.instance.sharingEnabled.value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 180,
          width: double.infinity,
          child: Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter:
                      partner ?? me ?? const LatLng(47.0105, 28.8638),
                  initialZoom: 13,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.none,
                  ),
                  onTap: (_, _) => _openFull(),
                  onMapReady: () {
                    _mapReady = true;
                    _fitBoth();
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.togetherly.love',
                    maxNativeZoom: 19,
                  ),
                  if (me != null && partner != null)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: [me, partner],
                          strokeWidth: 3,
                          color: t.primary.withValues(alpha: 0.8),
                          pattern: StrokePattern.dashed(segments: const [9, 6]),
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: [
                      if (partner != null)
                        Marker(
                          point: partner,
                          width: 40,
                          height: 40,
                          child: _MiniAvatar(
                            url: widget.partnerAvatarUrl,
                            name: widget.partnerName,
                            ring: _kPartnerColor,
                          ),
                        ),
                      if (me != null)
                        Marker(
                          point: me,
                          width: 40,
                          height: 40,
                          child: _MiniAvatar(
                            url: _myAvatarUrl,
                            name: LocaleService.current.liveMapYou,
                            ring: t.primary,
                          ),
                        ),
                    ],
                  ),
                ],
              ),

              // Дистанция.
              if (me != null && partner != null)
                Positioned(
                  left: 10,
                  top: 10,
                  child: _distancePill(t, me, partner),
                ),

              // CTA включения шеринга поверх превью.
              if (!sharing) _enableOverlay(t),

              // Кнопка выключения шеринга (когда включён).
              if (sharing)
                Positioned(
                  right: 10,
                  top: 10,
                  child: _stopChip(t),
                ),

              // Ждём партнёра (шеринг включён, но точки партнёра нет).
              if (sharing && partner == null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10,
                  child: Center(child: _hintChip(t, LocaleService.current.liveMapWaitingPartner)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _distancePill(AppTheme t, LatLng me, LatLng partner) {
    final meters = LiveLocationService.distanceMeters(me, partner);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: t.cardSurface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.favorite_rounded, size: 14, color: _kPartnerColor),
          const SizedBox(width: 6),
          Text(
            LiveLocationService.formatDistance(meters),
            style: GoogleFonts.rubik(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: t.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _hintChip(AppTheme t, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: t.cardSurface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: GoogleFonts.rubik(fontSize: 12, color: t.textSecondary),
      ),
    );
  }

  Widget _enableOverlay(AppTheme t) {
    final cs = ProfileTheme.themeFor(t).colorScheme;
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.32),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_on_rounded, color: Colors.white, size: 30),
            const SizedBox(height: 8),
            Text(
              LocaleService.current.liveMapEnableHint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: ProfileTheme.bodyFont,
                fontSize: 13,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _enableSharing,
              style: FilledButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: Text(
                LocaleService.current.liveMapEnableCta,
                style: const TextStyle(
                  fontFamily: ProfileTheme.bodyFont,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stopChip(AppTheme t) {
    final cs = ProfileTheme.themeFor(t).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _disableSharing,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.location_off_rounded,
                  size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 5),
              Text(
                LocaleService.current.liveMapStopCta,
                style: TextStyle(
                  fontFamily: ProfileTheme.bodyFont,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Компактная аватарка для превью ──────────────────────────────────────────
class _MiniAvatar extends StatelessWidget {
  final String url;
  final String name;
  final Color ring;

  const _MiniAvatar({required this.url, required this.name, required this.ring});

  @override
  Widget build(BuildContext context) {
    final initial = name.firstGraphemeUpper('♥');
    final fallback = Container(
      color: ring.withValues(alpha: 0.18),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
            color: ring, fontWeight: FontWeight.w800, fontSize: 14),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: ring.withValues(alpha: 0.4),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipOval(
        child: Container(
          color: Colors.white,
          child: url.isEmpty
              ? fallback
              : StorageImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  memCacheWidth: 120,
                  memCacheHeight: 120,
                  errorWidget: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}
