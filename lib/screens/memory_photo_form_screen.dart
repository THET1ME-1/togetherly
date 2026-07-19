import 'dart:io';
import 'dart:typed_data';
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';

import '../models/memory.dart';
import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../widgets/memory_date_field.dart';

import 'map_picker_screen.dart';

/// type авто-определяется: фото → photo, видео → video, без медиа → text.
typedef MemoryPhotoSaveCallback = Future<void> Function({
  required MemoryType type,
  required String title,
  required String caption,
  List<String>? mediaPaths,
  String? mediaPath,
  String? locationName,
  double? latitude,
  double? longitude,
  required bool isAdult,
  DateTime? customDate,
});

/// Full-page photo memory creation form.
class MemoryPhotoFormScreen extends StatefulWidget {
  final AppTheme theme;
  final MemoryPhotoSaveCallback onSave;

  const MemoryPhotoFormScreen({
    super.key,
    required this.theme,
    required this.onSave,
  });

  @override
  State<MemoryPhotoFormScreen> createState() => _MemoryPhotoFormScreenState();
}

class _MemoryPhotoFormScreenState extends State<MemoryPhotoFormScreen> {
  final _titleCtrl = TextEditingController();
  final _captionCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();

  // Единый список: фото и видео вместе
  List<XFile> _media = [];
  // Кэш превью для видео: path → thumbnail bytes
  final Map<String, Uint8List> _videoThumbs = {};

  double? _lat;
  double? _lng;
  bool _isAdult = false;
  bool _isSaving = false;
  bool _isLoadingLocation = false;
  DateTime? _customDate;

  static bool _isVideo(XFile f) {
    final ext = f.path.split('.').last.toLowerCase();
    return ['mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'].contains(ext);
  }

  // Авто-определяемый тип: есть фото → photo, только видео → video, пусто → text
  MemoryType get _effectiveType {
    if (_media.isEmpty) return MemoryType.text;
    final hasPhoto = _media.any((f) => !_isVideo(f));
    if (hasPhoto) return MemoryType.photo;
    return MemoryType.video;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _captionCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_isSaving &&
      (_media.isNotEmpty ||
          _titleCtrl.text.trim().isNotEmpty ||
          _captionCtrl.text.trim().isNotEmpty);

  // ── Picking photos & video ──────────────────────────────────────────────────

  Future<void> _pickMedia() async {
    try {
      final picked = await ImagePicker().pickMultipleMedia();
      if (picked.isEmpty || !mounted) return;
      setState(() => _media = [..._media, ...picked]);
      if (_lat == null) {
        final firstPhoto =
            picked.firstWhere((f) => !_isVideo(f), orElse: () => picked.first);
        if (!_isVideo(firstPhoto)) _tryExifGps(firstPhoto.path);
      }
      for (final f in picked) {
        if (_isVideo(f) && !_videoThumbs.containsKey(f.path)) {
          _generateVideoThumb(f.path);
        }
      }
    } catch (e) {
      _showError(LocaleService.current.failedSelectPhotos(e.toString()));
    }
  }

  Future<void> _generateVideoThumb(String path) async {
    try {
      final thumb = await VideoCompress.getByteThumbnail(
        path,
        quality: 60,
        position: -1,
      );
      if (thumb != null && mounted) {
        setState(() => _videoThumbs[path] = thumb);
      }
    } catch (_) {}
  }

  Future<void> _tryExifGps(String path) async {
    final coords = await _extractExifGps(path);
    if (coords == null || !mounted) return;
    final addr = await _reverseGeocode(coords.$1, coords.$2);
    if (!mounted) return;
    setState(() {
      _lat = coords.$1;
      _lng = coords.$2;
      _locationCtrl.text = addr;
    });
  }

  // ── Location ────────────────────────────────────────────────────────────────

  Future<void> _useCurrentLocation() async {
    setState(() => _isLoadingLocation = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showError(LocaleService.current.locationServicesDisabled);
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _showError(LocaleService.current.locationPermissionDenied);
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      final addr = await _reverseGeocode(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() {
        _lat = pos.latitude;
        _lng = pos.longitude;
        _locationCtrl.text = addr;
      });
    } catch (_) {
      _showError(LocaleService.current.failedGetLocation);
    } finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  Future<void> _pickOnMap() async {
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
        _locationCtrl.text = result['address'] as String? ?? '';
      });
    }
  }

  void _clearLocation() => setState(() {
        _lat = null;
        _lng = null;
        _locationCtrl.clear();
      });

  // ── Save ────────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _isSaving = true);
    Navigator.pop(context);
    final photos = _media.where((f) => !_isVideo(f)).toList();
    final videos = _media.where((f) => _isVideo(f)).toList();
    await widget.onSave(
      type: _effectiveType,
      title: _titleCtrl.text.trim(),
      caption: _captionCtrl.text.trim(),
      mediaPaths: photos.isNotEmpty ? photos.map((f) => f.path).toList() : null,
      mediaPath: videos.isNotEmpty ? videos.first.path : null,
      locationName: _locationCtrl.text.trim().isEmpty
          ? null
          : _locationCtrl.text.trim(),
      latitude: _lat,
      longitude: _lng,
      isAdult: _isAdult,
      customDate: _customDate,
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade400),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final primary = widget.theme.primary;
    final s = LocaleService.current;

    return Scaffold(
      backgroundColor: widget.theme.cardSurface,
      appBar: _buildAppBar(primary, s),
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _buildTitleField(s),
            ),
            const SizedBox(height: 12),
            _buildPhotoPicker(primary),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCaptionField(s),
                  const SizedBox(height: 12),
                  _buildLocationSection(primary, s),
                  const SizedBox(height: 10),
                  _buildAdultToggle(s),
                  const SizedBox(height: 16),
                  MemoryDateField(
                    value: _customDate,
                    onChanged: (d) => setState(() => _customDate = d),
                    accent: primary,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(Color primary, AppStrings s) {
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
        LocaleService.current.newEntry,
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
                backgroundColor: primary,
                foregroundColor: Colors.white,
                shape: const StadiumBorder(),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              child: Text(s.addMemoryBtn),
            ),
          ),
        ),
      ],
    );
  }

  // ── Media picker ────────────────────────────────────────────────────────────

  Widget _buildPhotoPicker(Color primary) {
    if (_media.isEmpty) return _buildEmptyMediaPicker(primary);
    return _buildFilledMedia(primary);
  }

  // Пустое состояние — вся область = пикер
  Widget _buildEmptyMediaPicker(Color primary) {
    return GestureDetector(
      onTap: _pickMedia,
      child: Container(
        width: double.infinity,
        height: 180,
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        decoration: BoxDecoration(
          color: widget.theme.surfaceMuted,
          borderRadius: BorderRadius.circular(18),
        ),
        child: CustomPaint(
          painter: _DashedBorderPainter(color: primary.withValues(alpha: 0.35)),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.add_photo_alternate_rounded,
                      size: 30, color: primary),
                ),
                const SizedBox(height: 8),
                Text(
                  LocaleService.current.photoVideo,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: primary),
                ),
                const SizedBox(height: 3),
                Text(
                  LocaleService.current.optionalTapToSelect,
                  style: TextStyle(fontSize: 12, color: widget.theme.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Заполненное состояние — превью первого элемента + лента миниатюр
  Widget _buildFilledMedia(Color primary) {
    final first = _media.first;
    final isFirstVideo = _isVideo(first);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Hero — первый элемент
        SizedBox(
          width: double.infinity,
          height: 260,
          child: ClipRect(
            child: Stack(
              children: [
                // Превью — Positioned.fill гарантирует обрезку, а не сжатие
                if (isFirstVideo)
                  Positioned.fill(
                    child: _videoPreviewWidget(first.path, fit: BoxFit.cover),
                  )
                else
                  Positioned.fill(
                    child: Image.file(File(first.path), fit: BoxFit.cover),
                  ),
                // Иконка Play для видео
                if (isFirstVideo)
                  const Center(
                    child: Icon(Icons.play_circle_filled_rounded,
                        color: Colors.white, size: 52),
                  ),
                // Счётчик
                if (_media.length > 1)
                  Positioned(
                    bottom: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        LocaleService.current.itemsShort(_media.length),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Лента миниатюр
        const SizedBox(height: 6),
        SizedBox(
          height: 72,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: _media.length + 1,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              // Кнопка "Добавить ещё" в конце
              if (i == _media.length) {
                return GestureDetector(
                  onTap: _pickMedia,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: widget.theme.surfaceMuted,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: primary.withValues(alpha: 0.3), width: 1.5),
                    ),
                    child: Icon(Icons.add_rounded, color: primary, size: 24),
                  ),
                );
              }
              final item = _media[i];
              final isVid = _isVideo(item);
              return Stack(
                children: [
                  // Миниатюра
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: isVid
                        ? _videoPreviewWidget(item.path,
                            width: 72, height: 72)
                        : Image.file(File(item.path),
                            width: 72, height: 72, fit: BoxFit.cover),
                  ),
                  // Play-иконка на видео
                  if (isVid)
                    const Positioned.fill(
                      child: Center(
                        child: Icon(Icons.play_circle_filled_rounded,
                            color: Colors.white70, size: 22),
                      ),
                    ),
                  // Удалить
                  Positioned(
                    top: 3,
                    right: 3,
                    child: GestureDetector(
                      onTap: () => setState(() => _media.removeAt(i)),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle),
                        child: const Icon(Icons.close_rounded,
                            color: Colors.white, size: 12),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  // Виджет превью видео: показывает кэшированный thumb или тёмный фон
  Widget _videoPreviewWidget(String path,
      {BoxFit fit = BoxFit.cover, double? width, double? height}) {
    final thumb = _videoThumbs[path];
    if (thumb != null) {
      return Image.memory(thumb,
          fit: fit,
          width: width,
          height: height ?? double.infinity);
    }
    return Container(
      width: width,
      height: height,
      color: Colors.grey.shade800,
      child: const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              color: Colors.white70, strokeWidth: 2),
        ),
      ),
    );
  }

  // ── Fields ──────────────────────────────────────────────────────────────────

  Widget _buildTitleField(AppStrings s) {
    return TextField(
      controller: _titleCtrl,
      onChanged: (_) => setState(() {}),
      textCapitalization: TextCapitalization.sentences,
      style:
          const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      decoration: InputDecoration(
        hintText: s.titleOptional,
        hintStyle: TextStyle(
            fontWeight: FontWeight.w400, color: widget.theme.textMuted),
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
          borderSide:
              BorderSide(color: widget.theme.primary, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildCaptionField(AppStrings s) {
    return TextField(
      controller: _captionCtrl,
      onChanged: (_) => setState(() {}),
      maxLines: 5,
      minLines: 3,
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
          borderSide:
              BorderSide(color: widget.theme.primary, width: 1.5),
        ),
      ),
    );
  }

  // ── Location ────────────────────────────────────────────────────────────────

  Widget _buildLocationSection(Color primary, AppStrings s) {
    if (_lat != null && _lng != null) {
      return GestureDetector(
        onTap: _clearLocation,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF22C55E).withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color:
                    const Color(0xFF22C55E).withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF22C55E).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.location_on_rounded,
                    size: 16, color: Color(0xFF22C55E)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _locationCtrl.text.isNotEmpty
                      ? _locationCtrl.text
                      : '${_lat!.toStringAsFixed(4)}, ${_lng!.toStringAsFixed(4)}',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF16A34A)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.close_rounded,
                  size: 16, color: widget.theme.textMuted),
            ],
          ),
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: _locationButton(
            icon: _isLoadingLocation ? null : Icons.my_location_rounded,
            loadingWidget: _isLoadingLocation
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : null,
            label: s.useCurrent,
            color: primary,
            onTap: _isLoadingLocation ? null : _useCurrentLocation,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _locationButton(
            icon: Icons.map_rounded,
            label: s.pickOnMap,
            color: const Color(0xFF22C55E),
            onTap: _pickOnMap,
          ),
        ),
      ],
    );
  }

  Widget _locationButton({
    IconData? icon,
    Widget? loadingWidget,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loadingWidget != null) ...[
              loadingWidget,
              const SizedBox(width: 7),
            ] else if (icon != null) ...[
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 7),
            ],
            Text(
              label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  // ── Adult toggle ────────────────────────────────────────────────────────────

  Widget _buildAdultToggle(AppStrings s) {
    return GestureDetector(
      onTap: () => setState(() => _isAdult = !_isAdult),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _isAdult ? Colors.red.shade50 : widget.theme.surfaceMuted,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: _isAdult
                  ? Colors.red.shade200
                  : widget.theme.divider),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _isAdult
                    ? Colors.red.withValues(alpha: 0.12)
                    : widget.theme.surfaceMuted,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isAdult ? Icons.lock_rounded : Icons.lock_open_rounded,
                size: 16,
                color: _isAdult
                    ? Colors.red.shade400
                    : widget.theme.textMuted,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.adultContent,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _isAdult
                            ? Colors.red.shade600
                            : widget.theme.textSecondary),
                  ),
                  Text(
                    s.photoBlurred,
                    style: TextStyle(
                        fontSize: 11,
                        color: _isAdult
                            ? Colors.red.shade400
                            : widget.theme.textMuted),
                  ),
                ],
              ),
            ),
            Switch(
              value: _isAdult,
              onChanged: (v) => setState(() => _isAdult = v),
              activeThumbColor: Colors.red.shade400,
              activeTrackColor: Colors.red.shade100,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static Future<(double, double)?> _extractExifGps(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final tags = await readExifFromBytes(bytes);
      if (!tags.containsKey('GPS GPSLatitude') ||
          !tags.containsKey('GPS GPSLongitude')) {
        return null;
      }
      final latRef =
          tags['GPS GPSLatitudeRef']?.printable.trim() ?? 'N';
      final lngRef =
          tags['GPS GPSLongitudeRef']?.printable.trim() ?? 'E';
      double? toDeg(String raw) {
        final clean = raw.replaceAll(RegExp(r'[\[\]\s]'), '');
        final parts = clean.split(',');
        if (parts.length < 3) return null;
        double p(String s) {
          if (s.contains('/')) {
            final f = s.split('/');
            final n = double.tryParse(f[0]);
            final d = double.tryParse(f[1]);
            if (n == null || d == null || d == 0) return 0;
            return n / d;
          }
          return double.tryParse(s) ?? 0;
        }
        return p(parts[0]) + p(parts[1]) / 60.0 + p(parts[2]) / 3600.0;
      }

      final latVal = toDeg(tags['GPS GPSLatitude']!.printable);
      final lngVal = toDeg(tags['GPS GPSLongitude']!.printable);
      if (latVal == null ||
          lngVal == null ||
          (latVal == 0.0 && lngVal == 0.0)) {
        return null;
      }
      return (
        latRef == 'S' ? -latVal : latVal,
        lngRef == 'W' ? -lngVal : lngVal
      );
    } catch (_) {
      return null;
    }
  }

  static Future<String> _reverseGeocode(double lat, double lng) async {
    try {
      final ps = await placemarkFromCoordinates(lat, lng);
      if (ps.isNotEmpty) {
        final place = ps.first;
        final name = place.name ?? place.subLocality ?? '';
        final locality = place.locality ?? '';
        return name.isNotEmpty ? '$name, $locality' : locality;
      }
    } catch (_) {}
    return '';
  }
}

// ── Dashed border painter ────────────────────────────────────────────────────

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  const _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const dashLen = 8.0;
    const gapLen = 5.0;
    const radius = Radius.circular(18);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height), radius));
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final end = (distance + dashLen).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dashLen + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}
