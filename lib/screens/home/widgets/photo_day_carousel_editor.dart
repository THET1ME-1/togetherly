import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../utils/safe_pick.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/storage_image.dart';
import '../../../utils/photo_crop.dart';
import '../../../services/locale_service.dart';

/// Bottom-sheet редактор карусели для одного виджета "Фото-виджет".
///
/// Количество фото — динамическое: от 1 до 10. Если фото 1 — карусели нет,
/// если 2-10 — появляются настройки смены (по разблокировке / по таймеру).
/// Порядок задаётся drag-and-drop.
///
/// [onPickFromMemories] — если передан, появляется кнопка "Из ленты воспоминаний".
/// Callback принимает максимальное количество фото, которые можно выбрать,
/// и возвращает список выбранных https-URL (уже загруженных на Firebase Storage).
class PhotoDayCarouselEditor extends StatefulWidget {
  final AppTheme theme;
  final List<String> initialPaths;
  final String initialRotationType;
  final int initialRotationInterval;
  final Future<void> Function({
    required List<String> paths,
    required String rotationType,
    required int rotationInterval,
  })
  onSave;

  /// Callback для выбора фото из ленты воспоминаний.
  /// Принимает [maxCount] — сколько ещё фото можно добавить.
  /// Возвращает список URL выбранных фотографий.
  final Future<List<String>> Function(int maxCount)? onPickFromMemories;

  const PhotoDayCarouselEditor({
    super.key,
    required this.theme,
    required this.initialPaths,
    required this.onSave,
    this.initialRotationType = 'unlock',
    this.initialRotationInterval = 60,
    this.onPickFromMemories,
  });

  static const int kMaxPhotos = 10;

  @override
  State<PhotoDayCarouselEditor> createState() => _PhotoDayCarouselEditorState();
}

class _PhotoDayCarouselEditorState extends State<PhotoDayCarouselEditor> {
  late List<String> _paths;
  late String _rotationType;
  late int _rotationInterval;
  bool _isSaving = false;
  // Были ли фото при открытии редактора — нужно, чтобы разрешить «Удалить фото»
  // (сохранение пустого списка), когда пользователь убрал все ранее выбранные.
  bool _hadInitialPhotos = false;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _paths = widget.initialPaths
        .where((p) => p.trim().isNotEmpty)
        .take(PhotoDayCarouselEditor.kMaxPhotos)
        .toList();
    _hadInitialPhotos = _paths.isNotEmpty;
    _rotationType = widget.initialRotationType;
    _rotationInterval = widget.initialRotationInterval;
  }

  Future<void> _addFromMemories() async {
    final remaining = PhotoDayCarouselEditor.kMaxPhotos - _paths.length;
    if (remaining <= 0 || widget.onPickFromMemories == null) return;
    final picked = await widget.onPickFromMemories!(remaining);
    if (picked.isEmpty || !mounted) return;
    setState(() {
      for (final url in picked) {
        if (!_paths.contains(url) &&
            _paths.length < PhotoDayCarouselEditor.kMaxPhotos) {
          _paths.add(url);
        }
      }
    });
  }

  Future<void> _addPhotos() async {
    final remaining = PhotoDayCarouselEditor.kMaxPhotos - _paths.length;
    if (remaining <= 0) return;

    try {
      final List<XFile> picked = await _picker.pickMultiImage(
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      if (picked.isEmpty) return;

      final taken = picked.take(remaining).toList();
      if (taken.length == 1) {
        // Одно фото — предлагаем кроппер
        final croppedPath = await cropPhoto(
          taken.first.path,
          accentColor: widget.theme.primary,
        );
        if (mounted) setState(() => _paths.add(croppedPath ?? taken.first.path));
      } else {
        // Несколько фото — добавляем без обрезки
        if (mounted) setState(() => _paths.addAll(taken.map((x) => x.path)));
      }
    } catch (_) {
      final XFile? single = await safePick(
        () => _picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
          maxWidth: 1920,
          maxHeight: 1920,
        ),
      );
      if (single == null) return;
      final croppedPath = await cropPhoto(
        single.path,
        accentColor: widget.theme.primary,
      );
      if (mounted) setState(() => _paths.add(croppedPath ?? single.path));
    }
  }

  void _replacePhoto(int index) async {
    final XFile? picked = await safePick(
      () => _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      ),
    );
    if (picked == null) return;
    final croppedPath = await cropPhoto(
      picked.path,
      accentColor: widget.theme.primary,
    );
    if (mounted) setState(() => _paths[index] = croppedPath ?? picked.path);
  }

  void _removePhoto(int index) {
    setState(() => _paths.removeAt(index));
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _paths.removeAt(oldIndex);
      _paths.insert(newIndex, item);
    });
  }

  Future<void> _save() async {
    // Пустой список — это валидное действие «удалить все фото»: сохраняем его,
    // чтобы можно было очистить выбранные фото (в т.ч. «Фото для партнёра»).
    setState(() => _isSaving = true);
    try {
      await widget.onSave(
        paths: List<String>.from(_paths),
        rotationType: _paths.length >= 2 ? _rotationType : 'none',
        rotationInterval: _rotationInterval,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint('Error saving carousel: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final canAddMore = _paths.length < PhotoDayCarouselEditor.kMaxPhotos;
    final hasCarousel = _paths.length >= 2;

    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: t.cardSurface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            LocaleService.current.widgetPhotoTitle,
                            style: GoogleFonts.rubik(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: t.primary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _paths.isEmpty
                                ? LocaleService.current.addOneToTenPhotos
                                : _paths.length == 1
                                    ? LocaleService.current.onePhotoNoCarousel
                                    : LocaleService.current
                                        .photoCountCarousel(_paths.length),
                            style: GoogleFonts.rubik(
                              fontSize: 12,
                              color: t.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: t.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_paths.length}/${PhotoDayCarouselEditor.kMaxPhotos}',
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
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: EdgeInsets.only(
                    left: 20,
                    right: 20,
                    bottom: MediaQuery.of(context).padding.bottom + 100,
                  ),
                  children: [
                    if (_paths.isNotEmpty) _buildHint(t),
                    if (_paths.isNotEmpty) const SizedBox(height: 8),
                    if (_paths.isNotEmpty) _buildPhotoList(t),
                    if (canAddMore) const SizedBox(height: 8),
                    if (canAddMore) _buildAddButton(t),
                    if (hasCarousel) const SizedBox(height: 24),
                    if (hasCarousel) _buildRotationSection(t),
                    if (_paths.isNotEmpty && !hasCarousel) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: t.primary.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: t.primary.withOpacity(0.18),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 16,
                              color: t.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleService.current.addMorePhotosCarouselHint,
                                style: GoogleFonts.rubik(
                                  fontSize: 11,
                                  color: t.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      // Кнопка активна, когда есть что сохранить ИЛИ когда есть
                      // что удалить (изначально были фото, а теперь список пуст).
                      onPressed: (_isSaving ||
                              (_paths.isEmpty && !_hadInitialPhotos))
                          ? null
                          : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _paths.isEmpty ? Colors.red.shade400 : t.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: t.surfaceMuted,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _paths.isEmpty
                                  ? LocaleService.current.deletePhoto
                                  : LocaleService.current.save,
                              style: GoogleFonts.rubik(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHint(AppTheme t) {
    return Row(
      children: [
        Icon(Icons.drag_indicator_rounded, size: 14, color: t.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            LocaleService.current.dragToReorder,
            style: GoogleFonts.rubik(
              fontSize: 11,
              color: t.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoList(AppTheme t) {
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: _reorder,
      children: [
        for (int i = 0; i < _paths.length; i++)
          _buildPhotoTile(t, i, _paths[i]),
      ],
    );
  }

  Widget _buildPhotoTile(AppTheme t, int index, String path) {
    return Container(
      key: ValueKey('photo_${index}_${path.hashCode}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: t.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.divider),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 12,
              ),
              child: Icon(
                Icons.drag_handle_rounded,
                size: 20,
                color: t.textMuted,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => _replacePhoto(index),
            child: Container(
              width: 56,
              height: 56,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: t.surfaceMuted,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.primary.withOpacity(0.25)),
              ),
              child: path.startsWith('http') || path.startsWith('gs://') || path.startsWith('sb://') || path.startsWith('pb://')
                  ? StorageImage(
                      imageUrl: path,
                      fit: BoxFit.cover,
                      memCacheWidth: 200,
                      memCacheHeight: 200,
                      errorWidget: (_, __, ___) => Icon(
                        Icons.broken_image_rounded,
                        size: 18,
                        color: t.textMuted,
                      ),
                    )
                  : Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.broken_image_rounded,
                        size: 18,
                        color: t.textMuted,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  LocaleService.current.photoNumber(index + 1),
                  style: GoogleFonts.rubik(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: t.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  index == 0
                      ? LocaleService.current.mainPhoto
                      : LocaleService.current.positionNumber(index + 1),
                  style: GoogleFonts.rubik(
                    fontSize: 11,
                    color: t.textMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: LocaleService.current.delete,
            onPressed: () => _removePhoto(index),
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 20,
              color: Colors.red.shade400,
            ),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildAddButton(AppTheme t) {
    final hasMemoryPicker = widget.onPickFromMemories != null;
    final label = _paths.isEmpty
        ? LocaleService.current.photoGridAddPhoto
        : LocaleService.current.addMore;

    if (!hasMemoryPicker) {
      return _addTile(
        t,
        icon: Icons.add_photo_alternate_rounded,
        label: label,
        onTap: _addPhotos,
      );
    }

    // Два источника: с устройства и из ленты воспоминаний
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _addTile(
                t,
                icon: Icons.add_photo_alternate_rounded,
                label: LocaleService.current.fromDevice,
                onTap: _addPhotos,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _addTile(
                t,
                icon: Icons.auto_stories_rounded,
                label: LocaleService.current.fromFeed,
                onTap: _addFromMemories,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _addTile(
    AppTheme t, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: t.primary.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: t.primary.withOpacity(0.3),
            width: 1.2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: t.primary, size: 22),
            const SizedBox(height: 6),
            Text(
              label,
              style: GoogleFonts.rubik(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: t.primary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRotationSection(AppTheme t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          LocaleService.current.changePhotosLabel,
          style: GoogleFonts.rubik(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: t.primary,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildRadio(
                title: LocaleService.current.onUnlockOption,
                value: 'unlock',
                groupValue: _rotationType,
                onChanged: (v) => setState(() => _rotationType = v!),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildRadio(
                title: LocaleService.current.byTimeOption,
                value: 'time',
                groupValue: _rotationType,
                onChanged: (v) => setState(() => _rotationType = v!),
              ),
            ),
          ],
        ),
        if (_rotationType == 'time') ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: t.surfaceMuted,
              borderRadius: BorderRadius.circular(12),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _rotationInterval,
                isExpanded: true,
                items: [
                  DropdownMenuItem(
                    value: 15,
                    child: Text(LocaleService.current.every15Minutes),
                  ),
                  DropdownMenuItem(
                    value: 30,
                    child: Text(LocaleService.current.every30Minutes),
                  ),
                  DropdownMenuItem(
                    value: 60,
                    child: Text(LocaleService.current.everyHourOption),
                  ),
                  DropdownMenuItem(
                    value: 180,
                    child: Text(LocaleService.current.every3HoursOption),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _rotationInterval = v);
                },
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRadio({
    required String title,
    required String value,
    required String groupValue,
    required ValueChanged<String?> onChanged,
  }) {
    final isSelected = value == groupValue;
    final t = widget.theme;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? t.primary.withOpacity(0.1) : Colors.transparent,
          border: Border.all(
            color: isSelected ? t.primary : t.divider,
            width: isSelected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: isSelected ? t.primary : t.textMuted,
              size: 18,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                style: GoogleFonts.rubik(
                  fontSize: 12,
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected ? t.primary : t.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
