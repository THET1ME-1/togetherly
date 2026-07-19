import '../../../widgets/storage_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../services/locale_service.dart';
import '../../../services/pb_data_service.dart';
import '../../../models/memory.dart';
import '../../../theme/app_theme.dart';

/// Пара (url, caption) — одна фотография из ленты воспоминаний.
typedef _Photo = ({String url, String? caption});

/// Bottom-sheet для выбора фото из ленты воспоминаний.
///
/// Открывается через [MemoryPhotoPicker.show] и возвращает список URL
/// выбранных фотографий (уже загруженных на Firebase Storage — без повторной загрузки).
class MemoryPhotoPicker extends StatefulWidget {
  final String groupId;
  final AppTheme theme;
  final int maxCount;
  final List<String> alreadySelected;

  const MemoryPhotoPicker({
    super.key,
    required this.groupId,
    required this.theme,
    required this.maxCount,
    this.alreadySelected = const [],
  });

  /// Открывает пикер и возвращает выбранные URL-адреса.
  /// Возвращает пустой список, если пользователь закрыл без выбора.
  static Future<List<String>> show(
    BuildContext context, {
    required String groupId,
    required AppTheme theme,
    required int maxCount,
    List<String> alreadySelected = const [],
  }) async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryPhotoPicker(
        groupId: groupId,
        theme: theme,
        maxCount: maxCount,
        alreadySelected: alreadySelected,
      ),
    );
    return result ?? [];
  }

  @override
  State<MemoryPhotoPicker> createState() => _MemoryPhotoPickerState();
}

class _MemoryPhotoPickerState extends State<MemoryPhotoPicker> {
  List<_Photo>? _photos;
  bool _loading = true;
  String? _error;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    try {
      // Лента воспоминаний из PocketBase (новые сверху), фильтр «фото» в Dart.
      final recs =
          await PbDataService().loadMemories(widget.groupId, limit: 100);
      final photos = <_Photo>[];
      for (final rec in recs) {
        final m = Memory.fromPb(rec);
        if (m.type != MemoryType.photo) continue;
        final caption = m.caption;
        final url = m.imageUrl;
        if (url != null && url.isNotEmpty) {
          photos.add((url: url, caption: caption));
        }
        for (final u in m.imageUrls ?? const <String>[]) {
          if (u.isNotEmpty && u != url) {
            photos.add((url: u, caption: caption));
          }
        }
      }
      if (mounted) {
        setState(() {
          _photos = photos;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _toggle(String url) {
    if (_selected.contains(url)) {
      setState(() => _selected.remove(url));
    } else {
      if (_selected.length >= widget.maxCount) return;
      setState(() => _selected.add(url));
    }
  }

  void _confirm() {
    Navigator.pop(context, _selected.toList());
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final remaining = widget.maxCount - _selected.length;
    final canConfirm = _selected.isNotEmpty;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
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
                            LocaleService.current.memoryLane,
                            style: GoogleFonts.rubik(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: t.primary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.maxCount == 1
                                ? LocaleService.current.selectOnePhoto
                                : remaining == 0
                                    ? LocaleService.current.maxSelected
                                    : LocaleService.current
                                        .selectUpToPhotos(remaining),
                            style: GoogleFonts.rubik(
                              fontSize: 12,
                              color: t.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_selected.isNotEmpty)
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
                          '${_selected.length}/${widget.maxCount}',
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
              const SizedBox(height: 12),
              Expanded(child: _buildBody(t, scrollController)),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: canConfirm ? _confirm : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: t.surfaceMuted,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        _selected.isEmpty
                            ? LocaleService.current.selectPhotosPrompt
                            : LocaleService.current
                                .addWithCount(_selected.length),
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

  Widget _buildBody(AppTheme t, ScrollController scrollController) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(
          LocaleService.current.failedToLoadMemories,
          style: GoogleFonts.rubik(color: t.textMuted),
        ),
      );
    }
    final photos = _photos ?? [];
    if (photos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined,
                size: 48, color: t.textMuted),
            const SizedBox(height: 12),
            Text(
              LocaleService.current.noPhotosInMemoryLane,
              style: GoogleFonts.rubik(color: t.textMuted),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: photos.length,
      itemBuilder: (context, index) {
        final photo = photos[index];
        final isSelected = _selected.contains(photo.url);
        final isAlreadyUsed =
            widget.alreadySelected.contains(photo.url);
        final atMax = _selected.length >= widget.maxCount;
        final disabled = !isSelected && atMax;

        return GestureDetector(
          onTap: disabled ? null : () => _toggle(photo.url),
          child: Stack(
            fit: StackFit.expand,
            children: [
              StorageImage(
                imageUrl: photo.url,
                fit: BoxFit.cover,
                memCacheWidth: 300,
                memCacheHeight: 300,
                placeholder: (_, __) => Container(
                  color: t.surfaceMuted,
                ),
                errorWidget: (_, __, ___) => Container(
                  color: t.surfaceMuted,
                  child: Icon(Icons.broken_image_rounded,
                      color: t.textMuted),
                ),
              ),
              // Dim if at max and not selected
              if (disabled)
                Container(color: Colors.white.withOpacity(0.5)),
              // Selection overlay
              if (isSelected)
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: t.primary, width: 3),
                    color: t.primary.withOpacity(0.18),
                  ),
                ),
              // Checkmark badge
              Positioned(
                top: 6,
                right: 6,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: isSelected
                      ? Container(
                          key: const ValueKey('checked'),
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: t.primary,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.2),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.check_rounded,
                              size: 14, color: Colors.white),
                        )
                      : Container(
                          key: const ValueKey('unchecked'),
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.25),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white,
                              width: 1.5,
                            ),
                          ),
                        ),
                ),
              ),
              // "Already in widget" badge
              if (isAlreadyUsed && !isSelected)
                Positioned(
                  bottom: 4,
                  left: 4,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      LocaleService.current.inWidget,
                      style: GoogleFonts.rubik(
                        fontSize: 9,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
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
}
