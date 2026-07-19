import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../services/locale_service.dart';
import '../theme/theme_scope.dart';


// ─── Data class ─────────────────────────────────────────────────────────────
class _PlaceResult {
  final String displayName;
  final String shortName;
  final double lat;
  final double lng;
  const _PlaceResult({
    required this.displayName,
    required this.shortName,
    required this.lat,
    required this.lng,
  });
}

// ─── Widget ──────────────────────────────────────────────────────────────────
class MapPickerScreen extends StatefulWidget {
  final double? initialLatitude;
  final double? initialLongitude;

  const MapPickerScreen({
    super.key,
    this.initialLatitude,
    this.initialLongitude,
  });

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  late final MapController _mapController;
  late final TextEditingController _searchCtrl;
  late final FocusNode _searchFocus;

  LatLng _selected = const LatLng(47.0105, 28.8638);
  String _address = '';
  bool _loadingAddr = false;
  bool _searching = false;
  List<_PlaceResult> _suggestions = [];
  bool _showSugg = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _searchCtrl = TextEditingController();
    _searchFocus = FocusNode();

    if (widget.initialLatitude != null && widget.initialLongitude != null) {
      _selected = LatLng(widget.initialLatitude!, widget.initialLongitude!);
      _reverseGeocode();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // ── Reverse geocoding ────────────────────────────────────────────────────
  Future<void> _reverseGeocode() async {
    setState(() => _loadingAddr = true);
    try {
      final ps = await placemarkFromCoordinates(
        _selected.latitude,
        _selected.longitude,
      );
      if (ps.isNotEmpty && mounted) {
        final p = ps.first;
        final parts = <String>[
          if ((p.name ?? '').isNotEmpty) p.name!,
          if ((p.street ?? '').isNotEmpty && p.street != p.name) p.street!,
          if ((p.locality ?? '').isNotEmpty) p.locality!,
          if ((p.country ?? '').isNotEmpty) p.country!,
        ];
        setState(() => _address = parts.join(', '));
      }
    } catch (_) {
      if (mounted) setState(() => _address = LocaleService.current.selectedLocation);
    }
    if (mounted) setState(() => _loadingAddr = false);
  }

  // ── Map tap ──────────────────────────────────────────────────────────────
  void _onMapTap(TapPosition _, LatLng point) {
    _searchFocus.unfocus();
    setState(() {
      _selected = point;
      _showSugg = false;
      _suggestions = [];
      _searchCtrl.clear();
    });
    _reverseGeocode();
  }

  // ── Search field ─────────────────────────────────────────────────────────
  void _onChanged(String q) {
    _debounce?.cancel();
    final t = q.trim();
    if (t.isEmpty) {
      setState(() { _suggestions = []; _showSugg = false; _searching = false; });
      return;
    }
    // If it looks like coordinates, don't trigger Nominatim search
    if (_parseCoords(t) != null) {
      setState(() { _suggestions = []; _showSugg = false; _searching = false; });
      return;
    }
    if (t.length < 2) return;
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 480), () async {
      final results = await _nominatim(t);
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _showSugg = results.isNotEmpty;
        _searching = false;
      });
    });
  }

  void _onSubmit(String q) {
    _debounce?.cancel();
    final t = q.trim();
    if (t.isEmpty) return;

    // Coordinates: "55.7522, 37.6156"
    final coords = _parseCoords(t);
    if (coords != null) {
      _goToCoords(coords.$1, coords.$2);
      return;
    }

    // Immediate search + pick first result
    setState(() => _searching = true);
    _nominatim(t).then((results) {
      if (!mounted) return;
      setState(() { _searching = false; });
      if (results.isNotEmpty) {
        if (results.length == 1) {
          _selectPlace(results.first);
        } else {
          setState(() { _suggestions = results; _showSugg = true; });
        }
      }
    });
  }

  void _selectPlace(_PlaceResult p) {
    final loc = LatLng(p.lat, p.lng);
    _searchFocus.unfocus();
    setState(() {
      _selected = loc;
      _address = p.displayName;
      _showSugg = false;
      _suggestions = [];
      _searchCtrl.text = p.shortName;
    });
    _mapController.move(loc, 14.0);
  }

  void _goToCoords(double lat, double lng) {
    final loc = LatLng(lat, lng);
    _searchFocus.unfocus();
    setState(() {
      _selected = loc;
      _showSugg = false;
      _suggestions = [];
    });
    _mapController.move(loc, 14.0);
    _reverseGeocode();
  }

  // ── My location ──────────────────────────────────────────────────────────
  Future<void> _goToMyLocation() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return;
      final pos = await Geolocator.getCurrentPosition();
      final loc = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() {
        _selected = loc;
        _showSugg = false;
        _searchCtrl.clear();
      });
      _mapController.move(loc, 15.0);
      _reverseGeocode();
    } catch (e) {
      debugPrint('Current location failed: $e');
    }
  }

  // ── Confirm ──────────────────────────────────────────────────────────────
  void _confirm() {
    Navigator.pop(context, {
      'latitude': _selected.latitude,
      'longitude': _selected.longitude,
      'address': _address,
    });
  }

  // ── Nominatim API ────────────────────────────────────────────────────────
  static Future<List<_PlaceResult>> _nominatim(String query) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'json',
        'limit': '7',
        'addressdetails': '1',
      });
      final resp = await http.get(uri, headers: {
        'User-Agent': 'Togetherly/1.0 (love app)',
        'Accept-Language': 'ru,en',
      }).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return [];
      final data = json.decode(resp.body) as List<dynamic>;
      return data.map((d) {
        final displayName = d['display_name'] as String;
        final addr = (d['address'] as Map<String, dynamic>?) ?? {};
        final shortParts = <String>[];
        final poi = addr['amenity'] ?? addr['tourism'] ?? addr['shop'] ??
            addr['leisure'] ?? addr['building'] ?? '';
        if (poi != '') shortParts.add(poi as String);
        final road = addr['road'] ?? addr['pedestrian'] ?? addr['street'] ?? '';
        if (road != '') shortParts.add(road as String);
        final city = addr['city'] ?? addr['town'] ?? addr['village'] ??
            addr['municipality'] ?? '';
        if (city != '') shortParts.add(city as String);
        final country = addr['country'] ?? '';
        if (country != '') shortParts.add(country as String);
        return _PlaceResult(
          displayName: displayName,
          shortName: shortParts.isNotEmpty
              ? shortParts.join(', ')
              : displayName.split(',').first.trim(),
          lat: double.parse(d['lat'] as String),
          lng: double.parse(d['lon'] as String),
        );
      }).toList();
    } catch (e) {
      debugPrint('Nominatim error: $e');
      return [];
    }
  }

  // ── Coordinate parser ────────────────────────────────────────────────────
  static (double, double)? _parseCoords(String input) {
    final m = RegExp(
      r'^(-?\d{1,3}(?:[.,]\d+)?)[,;\s]+(-?\d{1,3}(?:[.,]\d+)?)$',
    ).firstMatch(input.trim());
    if (m == null) return null;
    final lat = double.tryParse(m.group(1)!.replaceAll(',', '.'));
    final lng = double.tryParse(m.group(2)!.replaceAll(',', '.'));
    if (lat == null || lng == null) return null;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    return (lat, lng);
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).primaryColor;
    final t = context.appTheme;
    final bottom = MediaQuery.of(context).padding.bottom;
    final hasCoordInput = _parseCoords(_searchCtrl.text.trim()) != null;

    return Scaffold(
      backgroundColor: t.bgGradient[0],
      body: Stack(
        children: [
          // ─ Map ─────────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _selected,
              initialZoom: widget.initialLatitude != null ? 14.0 : 4.0,
              onTap: _onMapTap,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.togetherly.love',
                maxNativeZoom: 19,
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: _selected,
                    width: 40,
                    height: 52,
                    child: Column(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2.5),
                            boxShadow: [
                              BoxShadow(
                                color: primary.withOpacity(0.45),
                                blurRadius: 14,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.location_on_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                        Container(
                          width: 2,
                          height: 10,
                          decoration: BoxDecoration(
                            color: primary,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),

          // ─ Top: back + search ──────────────────────────────────────────
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: Row(
                    children: [
                      // Back button
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: t.cardSurface,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.13),
                                blurRadius: 8,
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
                      const SizedBox(width: 10),
                      // Search bar
                      Expanded(
                        child: Container(
                          height: 44,
                          decoration: BoxDecoration(
                            color: t.cardSurface,
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.12),
                                blurRadius: 10,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: TextField(
                            controller: _searchCtrl,
                            focusNode: _searchFocus,
                            onChanged: _onChanged,
                            onSubmitted: _onSubmit,
                            textInputAction: TextInputAction.search,
                            style: GoogleFonts.rubik(fontSize: 13),
                            decoration: InputDecoration(
                              hintText: LocaleService.current.placeOrCoordsHint,
                              hintStyle: GoogleFonts.rubik(
                                fontSize: 13,
                                color: t.textMuted,
                              ),
                              prefixIcon: _searching
                                  ? Padding(
                                      padding: const EdgeInsets.all(13),
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: primary,
                                        ),
                                      ),
                                    )
                                  : Icon(
                                      Icons.search_rounded,
                                      size: 20,
                                      color: t.textMuted,
                                    ),
                              suffixIcon: _searchCtrl.text.isNotEmpty
                                  ? GestureDetector(
                                      onTap: () {
                                        _searchCtrl.clear();
                                        setState(() {
                                          _suggestions = [];
                                          _showSugg = false;
                                          _searching = false;
                                        });
                                      },
                                      child: Icon(
                                        Icons.close_rounded,
                                        size: 18,
                                        color: t.textMuted,
                                      ),
                                    )
                                  : null,
                              border: InputBorder.none,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 13),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Coordinates hint row
                if (hasCoordInput)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(64, 6, 12, 0),
                    child: GestureDetector(
                      onTap: () {
                        final c = _parseCoords(_searchCtrl.text.trim());
                        if (c != null) _goToCoords(c.$1, c.$2);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: t.cardSurface,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.my_location_rounded,
                              size: 16,
                              color: primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              LocaleService.current.goToCoordinates,
                              style: GoogleFonts.rubik(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: primary,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              Icons.arrow_forward_rounded,
                              size: 16,
                              color: primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Suggestions dropdown
                if (_showSugg && _suggestions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(64, 6, 12, 0),
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 320),
                      decoration: BoxDecoration(
                        color: t.cardSurface,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.12),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _suggestions.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: t.divider,
                          ),
                          itemBuilder: (_, i) {
                            final p = _suggestions[i];
                            return InkWell(
                              onTap: () => _selectPlace(p),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 11,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.location_on_rounded,
                                      size: 16,
                                      color: primary,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            p.shortName,
                                            style: GoogleFonts.rubik(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: t.textPrimary,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            p.displayName,
                                            style: GoogleFonts.rubik(
                                              fontSize: 11,
                                              color: t.textMuted,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ─ My location FAB ─────────────────────────────────────────────
          Positioned(
            right: 14,
            bottom: bottom + 170,
            child: GestureDetector(
              onTap: _goToMyLocation,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: t.cardSurface,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.13),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.my_location_rounded,
                  color: primary,
                  size: 22,
                ),
              ),
            ),
          ),

          // ─ Bottom card: address + confirm ──────────────────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                color: t.cardSurface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 20,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              padding: EdgeInsets.fromLTRB(20, 14, 20, bottom + 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag handle
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: t.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: primary.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child:
                            Icon(Icons.location_on_rounded, color: primary, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _loadingAddr
                            ? Row(
                                children: [
                                  SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: primary,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    LocaleService.current.gettingAddress,
                                    style: GoogleFonts.rubik(
                                      fontSize: 13,
                                      color: t.textMuted,
                                    ),
                                  ),
                                ],
                              )
                            : Text(
                                _address.isNotEmpty
                                    ? _address
                                    : LocaleService.current.tapOnMapToSelect,
                                style: GoogleFonts.rubik(
                                  fontSize: 14,
                                  fontWeight: _address.isNotEmpty
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: _address.isNotEmpty
                                      ? t.textPrimary
                                      : t.textMuted,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _confirm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        LocaleService.current.confirm,
                        style: GoogleFonts.rubik(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
