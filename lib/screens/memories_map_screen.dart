import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import '../models/memory.dart';
import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../widgets/storage_image.dart';

class _MemoryCluster {
  final LatLng center;
  final List<Memory> memories;

  const _MemoryCluster({required this.center, required this.memories});

  int get count => memories.length;
}

class MemoriesMapScreen extends StatefulWidget {
  final List<Memory> memories;
  final AppTheme theme;
  final String? currentUserUid;

  const MemoriesMapScreen({
    super.key,
    required this.memories,
    required this.theme,
    this.currentUserUid,
  });

  @override
  State<MemoriesMapScreen> createState() => _MemoriesMapScreenState();
}

class _MemoriesMapScreenState extends State<MemoriesMapScreen> {
  late final MapController _mapController;
  late List<_MemoryCluster> _clusters;
  _MemoryCluster? _selectedCluster;
  double _zoom = 3.5;

  // How many screen pixels define "overlapping" — markers closer than this merge.
  static const double _clusterPixels = 56.0;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _clusters = _buildClusters(_zoom);
  }

  /// Grid cell size in degrees for a given zoom level.
  /// At zoom z, 256·2^z pixels span 360° → 1° = 256·2^z/360 px.
  /// We merge markers whose centres are within [_clusterPixels] pixels.
  static double _cellDeg(double zoom) {
    final pxPerDeg = 256.0 * pow(2.0, zoom) / 360.0;
    return _clusterPixels / pxPerDeg;
  }

  List<_MemoryCluster> _buildClusters(double zoom) {
    final cell = _cellDeg(zoom);
    final geoMemories = widget.memories
        .where((m) => m.latitude != null && m.longitude != null)
        .toList();

    final Map<String, List<Memory>> groups = {};
    for (final m in geoMemories) {
      final cellLat = (m.latitude! / cell).floor();
      final cellLng = (m.longitude! / cell).floor();
      groups.putIfAbsent('${cellLat}_$cellLng', () => []).add(m);
    }

    return groups.values.map((list) {
      final avgLat =
          list.map((m) => m.latitude!).reduce((a, b) => a + b) / list.length;
      final avgLng =
          list.map((m) => m.longitude!).reduce((a, b) => a + b) / list.length;
      return _MemoryCluster(center: LatLng(avgLat, avgLng), memories: list);
    }).toList();
  }

  void _onMapEvent(MapEvent event) {
    final newZoom = event.camera.zoom;
    // Only re-cluster when zoom changes meaningfully (ignore tiny floating drift)
    if ((newZoom - _zoom).abs() >= 0.25) {
      setState(() {
        _zoom = newZoom;
        _selectedCluster = null;
        _clusters = _buildClusters(newZoom);
      });
    }
  }

  double _markerSize(_MemoryCluster c) {
    if (c.count == 1) return 40;
    if (c.count <= 3) return 50;
    if (c.count <= 8) return 62;
    return 74;
  }

  Color _markerColor(_MemoryCluster c) {
    final t = widget.theme;
    final uid = widget.currentUserUid;

    final bool isMine = uid != null &&
        c.memories.where((m) => m.authorUid == uid).length >
            c.memories.length / 2;

    final base = isMine ? t.primary : Colors.teal.shade400;
    if (c.count == 1) return base.withValues(alpha: 0.85);
    if (c.count <= 3) return base;
    if (c.count <= 8) return Color.lerp(base, Colors.deepPurple, 0.25)!;
    return Color.lerp(base, Colors.deepPurple, 0.5)!;
  }

  LatLng? _boundsCenter() {
    if (_clusters.isEmpty) return null;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final c in _clusters) {
      minLat = min(minLat, c.center.latitude);
      maxLat = max(maxLat, c.center.latitude);
      minLng = min(minLng, c.center.longitude);
      maxLng = max(maxLng, c.center.longitude);
    }
    return LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
  }

  void _onClusterTap(_MemoryCluster cluster) {
    if (_selectedCluster == cluster) {
      setState(() => _selectedCluster = null);
    } else {
      // Zoom in enough that the cluster likely splits (or shows detail)
      final targetZoom = (_zoom + 3).clamp(1.5, 18.0);
      _mapController.move(cluster.center, targetZoom);
      // Re-cluster at new zoom and then select
      setState(() {
        _zoom = targetZoom;
        _clusters = _buildClusters(targetZoom);
        _selectedCluster = null; // will be updated below
      });
      // Find whichever cluster now contains the tapped memories
      final tappedIds = cluster.memories.map((m) => m.id).toSet();
      final newCluster = _clusters.firstWhere(
        (c) => c.memories.any((m) => tappedIds.contains(m.id)),
        orElse: () => cluster,
      );
      setState(() => _selectedCluster = newCluster);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final center = _boundsCenter() ?? const LatLng(48.0, 15.0);

    return Scaffold(
      backgroundColor: t.bgGradient[0],
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: _zoom,
              minZoom: 1.5,
              maxZoom: 18,
              onTap: (_, __) => setState(() => _selectedCluster = null),
              onMapEvent: _onMapEvent,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.togetherly.love',
                maxNativeZoom: 19,
              ),
              MarkerLayer(
                markers: _clusters.map((c) {
                  final size = _markerSize(c);
                  final color = _markerColor(c);
                  final isSelected = _selectedCluster == c;
                  return Marker(
                    point: c.center,
                    width: size + 12,
                    height: size + 12,
                    child: GestureDetector(
                      onTap: () => _onClusterTap(c),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: size + (isSelected ? 12 : 0),
                        height: size + (isSelected ? 12 : 0),
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white,
                            width: isSelected ? 3 : 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: 0.45),
                              blurRadius: isSelected ? 20 : 12,
                              spreadRadius: isSelected ? 4 : 2,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            '${c.count}',
                            style: GoogleFonts.rubik(
                              fontSize: size * 0.32,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),

          // AppBar overlay
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: t.cardSurface,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.arrow_back_rounded,
                          color: t.textPrimary,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: t.cardSurface,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.map_rounded, size: 16, color: t.primary),
                            const SizedBox(width: 8),
                            Text(
                              LocaleService.current.memoriesMapTooltip,
                              style: GoogleFonts.rubik(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: t.textPrimary,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: t.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${widget.memories.where((m) => m.latitude != null).length}',
                                style: GoogleFonts.rubik(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: t.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Empty state
          if (_clusters.isEmpty)
            Center(
              child: Container(
                margin: const EdgeInsets.all(32),
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: t.cardSurface,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 20,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.location_off_rounded,
                        size: 48, color: t.textMuted),
                    const SizedBox(height: 16),
                    Text(
                      LocaleService.current.noGeoMemories,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.rubik(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: t.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      LocaleService.current.addLocationHint,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.rubik(
                        fontSize: 13,
                        color: t.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Cluster popup panel
          if (_selectedCluster != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildClusterPanel(_selectedCluster!),
            ),
        ],
      ),
    );
  }

  Widget _buildClusterPanel(_MemoryCluster cluster) {
    final t = widget.theme;
    final photos = cluster.memories
        .where((m) =>
            m.type == MemoryType.photo &&
            (m.imageUrls?.isNotEmpty == true || m.imageUrl?.isNotEmpty == true))
        .take(6)
        .toList();
    final locationName = cluster.memories
        .firstWhere(
          (m) => m.locationName?.isNotEmpty == true,
          orElse: () => cluster.memories.first,
        )
        .locationName;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.cardSurface,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 24,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: t.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.location_on_rounded,
                      size: 18, color: t.primary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        locationName ?? LocaleService.current.placeFallback,
                        style: GoogleFonts.rubik(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: t.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${cluster.count} ${LocaleService.current.memoriesUnit(cluster.count)}',
                        style: GoogleFonts.rubik(
                          fontSize: 12,
                          color: t.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (photos.isNotEmpty) ...[
              const SizedBox(height: 14),
              SizedBox(
                height: 72,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final url =
                        photos[i].imageUrls?.firstOrNull ?? photos[i].imageUrl;
                    if (url == null) return const SizedBox.shrink();
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: StorageImage(
                        imageUrl: url,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        errorWidget: (context, _, __) => Container(
                          width: 72,
                          height: 72,
                          color: t.surfaceMuted,
                          child: Icon(Icons.broken_image_rounded,
                              color: t.textMuted),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
