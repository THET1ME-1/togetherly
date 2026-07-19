import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../widgets/memory_date_field.dart';
import 'map_picker_screen.dart';

/// Сохранение воспоминания-локации.
typedef MemoryLocationSaveCallback = Future<void> Function({
  required String locationName,
  double? latitude,
  double? longitude,
  String caption,
  DateTime? customDate,
});

/// Полноэкранная форма создания локации.
///
/// Центральный элемент — живое превью карты с выбранной точкой. Тап по карте
/// открывает полноценный выбор места ([MapPickerScreen]) с поиском и геопозицией.
class MemoryLocationFormScreen extends StatefulWidget {
  final AppTheme theme;
  final MemoryLocationSaveCallback onSave;

  const MemoryLocationFormScreen({
    super.key,
    required this.theme,
    required this.onSave,
  });

  @override
  State<MemoryLocationFormScreen> createState() =>
      _MemoryLocationFormScreenState();
}

class _MemoryLocationFormScreenState extends State<MemoryLocationFormScreen> {
  static const Color _accent = Color(0xFF22C55E);

  final _nameCtrl = TextEditingController();
  final _captionCtrl = TextEditingController();

  double? _lat;
  double? _lng;
  bool _isLoadingLocation = false;
  bool _isSaving = false;
  DateTime? _customDate;

  Color get _primary => widget.theme.primary;

  bool get _hasLocation => _lat != null && _lng != null;

  bool get _canSave =>
      !_isSaving && (_hasLocation || _nameCtrl.text.trim().isNotEmpty);

  @override
  void dispose() {
    _nameCtrl.dispose();
    _captionCtrl.dispose();
    super.dispose();
  }

  // ── Actions ─────────────────────────────────────────────────────────────--

  Future<void> _openMapPicker() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            MapPickerScreen(initialLatitude: _lat, initialLongitude: _lng),
        settings: const RouteSettings(name: '/map_picker'),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _lat = result['latitude'] as double?;
        _lng = result['longitude'] as double?;
        final addr = result['address'] as String? ?? '';
        if (addr.isNotEmpty) _nameCtrl.text = addr;
      });
    }
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _isLoadingLocation = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _snack(LocaleService.current.locationServicesDisabled);
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _snack(LocaleService.current.locationPermissionDenied);
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      String addr = '';
      try {
        final ps = await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (ps.isNotEmpty) {
          final p = ps.first;
          final name = p.name ?? p.subLocality ?? '';
          final locality = p.locality ?? '';
          addr = name.isNotEmpty ? '$name, $locality' : locality;
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _lat = pos.latitude;
        _lng = pos.longitude;
        if (addr.isNotEmpty) _nameCtrl.text = addr;
      });
    } catch (_) {
      _snack(LocaleService.current.failedGetLocation);
    } finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  void _clearLocation() => setState(() {
        _lat = null;
        _lng = null;
      });

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _isSaving = true);
    Navigator.pop(context);
    await widget.onSave(
      locationName: _nameCtrl.text.trim(),
      latitude: _lat,
      longitude: _lng,
      caption: _captionCtrl.text.trim(),
      customDate: _customDate,
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.grey.shade800),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────--

  @override
  Widget build(BuildContext context) {
    final s = LocaleService.current;
    return Scaffold(
      backgroundColor: widget.theme.cardSurface,
      appBar: _buildAppBar(s),
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          children: [
            _buildMapHero(s),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildNameField(s),
                  const SizedBox(height: 12),
                  _buildActionsRow(s),
                  const SizedBox(height: 16),
                  _buildCaptionField(s),
                  const SizedBox(height: 16),
                  MemoryDateField(
                    value: _customDate,
                    onChanged: (d) => setState(() => _customDate = d),
                    accent: _accent,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(AppStrings s) {
    return AppBar(
      backgroundColor: widget.theme.cardSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close_rounded, size: 22),
        style: IconButton.styleFrom(foregroundColor: widget.theme.textSecondary),
      ),
      title: Text(
        s.location,
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: widget.theme.textPrimary,
        ),
      ),
      centerTitle: true,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: AnimatedOpacity(
            opacity: _canSave ? 1.0 : 0.4,
            duration: const Duration(milliseconds: 200),
            child: FilledButton(
              onPressed: _canSave ? _save : null,
              style: FilledButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                shape: const StadiumBorder(),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                textStyle:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              child: Text(s.addMemoryBtn),
            ),
          ),
        ),
      ],
    );
  }

  // ── Map hero ────────────────────────────────────────────────────────────--

  Widget _buildMapHero(AppStrings s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: GestureDetector(
        onTap: _openMapPicker,
        child: Container(
          height: 240,
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: _accent.withValues(alpha: 0.18),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: _hasLocation ? _buildMapPreview(s) : _buildEmptyMap(s),
          ),
        ),
      ),
    );
  }

  Widget _buildMapPreview(AppStrings s) {
    final center = LatLng(_lat!, _lng!);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Неинтерактивное превью — тап по карте открывает полный выбор.
        FlutterMap(
          key: ValueKey('$_lat,$_lng'),
          options: MapOptions(
            initialCenter: center,
            initialZoom: 15,
            interactionOptions:
                const InteractionOptions(flags: InteractiveFlag.none),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.togetherly.love',
              maxNativeZoom: 19,
            ),
          ],
        ),
        // Центральный маркер (остриё указывает в центр карты).
        Center(
          child: Transform.translate(
            offset: const Offset(0, -18),
            child: _buildPin(),
          ),
        ),
        // Затемнение снизу для читаемости адреса.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            height: 90,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.55),
                ],
              ),
            ),
          ),
        ),
        // Адрес снизу слева.
        Positioned(
          left: 14,
          right: 14,
          bottom: 12,
          child: Row(
            children: [
              const Icon(Icons.place_rounded, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _nameCtrl.text.trim().isNotEmpty
                      ? _nameCtrl.text.trim()
                      : '${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Кнопка «Изменить» сверху справа.
        Positioned(
          top: 12,
          right: 12,
          child: _glassChip(
            icon: Icons.edit_location_alt_rounded,
            label: s.pickOnMap,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyMap(AppStrings s) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _accent.withValues(alpha: 0.12),
            _primary.withValues(alpha: 0.06),
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.add_location_alt_rounded,
                  size: 34, color: _accent),
            ),
            const SizedBox(height: 12),
            Text(
              s.tapOnMapToSelect,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: widget.theme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPin() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: _accent,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: _accent.withValues(alpha: 0.5),
                blurRadius: 12,
                spreadRadius: 1,
              ),
            ],
          ),
          child: const Icon(Icons.location_on_rounded,
              color: Colors.white, size: 20),
        ),
        Container(
          width: 2,
          height: 10,
          color: _accent,
        ),
      ],
    );
  }

  Widget _glassChip({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: _accent),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _accent,
            ),
          ),
        ],
      ),
    );
  }

  // ── Fields & actions ──────────────────────────────────────────────────────

  Widget _buildNameField(AppStrings s) {
    return TextField(
      controller: _nameCtrl,
      onChanged: (_) => setState(() {}),
      textCapitalization: TextCapitalization.sentences,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      decoration: InputDecoration(
        hintText: s.locationNameHint,
        hintStyle:
            TextStyle(fontWeight: FontWeight.w400, color: widget.theme.textMuted),
        prefixIcon: const Icon(Icons.location_on_rounded, color: _accent),
        suffixIcon: _hasLocation
            ? IconButton(
                icon: Icon(Icons.close_rounded,
                    size: 18, color: widget.theme.textMuted),
                tooltip: s.pickOnMap,
                onPressed: _clearLocation,
              )
            : null,
        filled: true,
        fillColor: widget.theme.surfaceMuted,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: widget.theme.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: widget.theme.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: _primary, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildActionsRow(AppStrings s) {
    return Row(
      children: [
        Expanded(
          child: _actionButton(
            icon: _isLoadingLocation ? null : Icons.my_location_rounded,
            loading: _isLoadingLocation,
            label: s.useCurrent,
            color: _primary,
            onTap: _isLoadingLocation ? null : _useCurrentLocation,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _actionButton(
            icon: Icons.map_rounded,
            label: s.pickOnMap,
            color: _accent,
            onTap: _openMapPicker,
          ),
        ),
      ],
    );
  }

  Widget _actionButton({
    IconData? icon,
    bool loading = false,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.25),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            else if (icon != null)
              Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCaptionField(AppStrings s) {
    return TextField(
      controller: _captionCtrl,
      maxLines: 4,
      minLines: 2,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        hintText: s.descriptionOptional,
        hintStyle: TextStyle(color: widget.theme.textMuted),
        filled: true,
        fillColor: widget.theme.surfaceMuted,
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: widget.theme.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: widget.theme.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: _primary, width: 1.5),
        ),
      ),
    );
  }
}
