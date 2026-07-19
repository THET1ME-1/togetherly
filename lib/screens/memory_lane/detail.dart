part of '../memory_lane_screen.dart';

class _MemoryDetailSheet extends StatefulWidget {
  final Memory memory;
  final String groupId;
  final Color primary;
  final bool isOwner;
  final bool canDownload;
  final Color typeColor;
  final double? userLat;
  final double? userLng;
  final VoidCallback onTogglePin;
  final VoidCallback onDownload;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onSetLocation;
  /// Live-resolved author avatar URL (from group memberAvatars). If empty,
  /// AvatarWidget falls back to memory.authorAvatar.
  final String liveAuthorAvatar;

  const _MemoryDetailSheet({
    required this.memory,
    required this.groupId,
    required this.primary,
    required this.isOwner,
    required this.canDownload,
    required this.typeColor,
    this.userLat,
    this.userLng,
    required this.onTogglePin,
    required this.onDownload,
    required this.onEdit,
    required this.onDelete,
    this.onSetLocation,
    this.liveAuthorAvatar = '',
  });

  @override
  State<_MemoryDetailSheet> createState() => _MemoryDetailSheetState();
}

class _MemoryDetailSheetState extends State<_MemoryDetailSheet>
    with SingleTickerProviderStateMixin {
  AudioPlayer? _audioPlayer;
  late final AnimationController _animCtrl;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;
  // Cached to avoid recomputing Color.lerp on every build frame
  late final List<Color> _bannerGradient;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _bannerGradient = [
      widget.primary,
      Color.lerp(widget.primary, Colors.white, 0.30)!,
    ];
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _audioPlayer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final memory = widget.memory;
    final p = widget.primary;
    final isLarge =
        memory.type == MemoryType.photo ||
        memory.type == MemoryType.video ||
        memory.type == MemoryType.videoLink;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: isLarge ? 0.88 : 0.75,
      maxChildSize: 0.95,
      builder: (_, sc) => Container(
        color: context.appTheme.cardSurface,
        child: Column(
            children: [
              _buildHeader(memory, p),
              Expanded(
                // RepaintBoundary isolates the animated entry from the static
                // header so the header layer doesn't repaint every animation frame.
                child: RepaintBoundary(
                  child: FadeTransition(
                    opacity: _fadeAnim,
                    child: SlideTransition(
                      position: _slideAnim,
                      child: SingleChildScrollView(
                        controller: sc,
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Images/video are GPU-heavy; isolate them so that
                            // caption/location/action repaints don't touch them.
                            RepaintBoundary(child: _buildMedia(memory, p)),
                            _buildCaption(memory),
                            _buildLocationRow(memory, p),
                            const SizedBox(height: 20),
                            // Action buttons are static after build; isolate them
                            // so comments StreamBuilder repaints don't cascade up.
                            RepaintBoundary(child: _buildActions(memory, p)),
                            const SizedBox(height: 24),
                            RepaintBoundary(
                              child: _CommentsSection(
                                groupId: widget.groupId,
                                memoryId: widget.memory.id,
                                primary: p,
                              ),
                            ),
                            const _KeyboardPaddingBox(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
    );
  }

  // ── HEADER ───────────────────────────────────────────────────────────────────
  Widget _buildHeader(Memory memory, Color p) {
    final theme = context.appTheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _bannerGradient,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.isDark
                    ? theme.cardSurface
                    : Colors.white.withOpacity(0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.isDark
                        ? theme.cardBorder
                        : Colors.white.withOpacity(0.7),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: AvatarWidget(
                  uid: memory.authorUid,
                  liveUrl: widget.liveAuthorAvatar,
                  fallbackUrl: memory.authorAvatar,
                  name: memory.authorName,
                  size: 44,
                  primary: widget.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      memory.authorName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _fmtDate(memory.createdAt),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.white.withOpacity(0.8),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: theme.isDark
                      ? theme.cardSurface
                      : Colors.white.withOpacity(0.22),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: theme.isDark
                        ? theme.cardBorder
                        : Colors.white.withOpacity(0.35),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SvgPicture.asset(
                      _svgAssetForType(memory.type),
                      width: 12,
                      height: 12,
                      colorFilter: const ColorFilter.mode(
                        Colors.white,
                        BlendMode.srcIn,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      memory.typeLabel,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              if (memory.isPinned) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: theme.isDark
                        ? theme.cardSurface
                        : Colors.white.withOpacity(0.22),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.isDark
                          ? theme.cardBorder
                          : Colors.white.withOpacity(0.35),
                      width: 1,
                    ),
                  ),
                  child: const Icon(
                    Icons.push_pin_rounded,
                    size: 13,
                    color: Colors.white,
                  ),
                ),
              ],
            ],
          ),
          if (memory.title?.isNotEmpty == true) ...[
            const SizedBox(height: 12),
            Text(
              memory.title!,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.2,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── MEDIA ────────────────────────────────────────────────────────────────────
  Widget _buildMedia(Memory memory, Color p) {
    switch (memory.type) {
      case MemoryType.photo:
        // Смешанный пин: фото + видео — показываем оба блока.
        if (memory.videoUrl?.isNotEmpty == true) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPhotoMedia(memory),
              const SizedBox(height: 12),
              _buildVideoMedia(memory, p),
            ],
          );
        }
        return _buildPhotoMedia(memory);
      case MemoryType.video:
        return _buildVideoMedia(memory, p);
      case MemoryType.location:
        return _buildLocationMedia(memory, p);
      case MemoryType.music:
        return _MusicPlayerWidget(
          memory: memory,
          player: _audioPlayer,
          onPlayerCreated: (pl) => setState(() => _audioPlayer = pl),
          primary: p,
          typeColor: widget.typeColor,
        );
      case MemoryType.text:
        return _buildTextMedia(memory, p);
      case MemoryType.videoLink:
        return _buildVideoLinkMedia(memory, p);
      case MemoryType.book:
        return _buildBookMedia(memory, p);
      case MemoryType.movie:
        return _buildMovieMedia(memory, p);
    }
  }

  Widget _buildPhotoMedia(Memory memory) {
    final allPhotos = <String>[
      if (memory.imageUrls?.isNotEmpty == true)
        ...memory.imageUrls!
      else if (memory.imageUrl?.isNotEmpty == true)
        memory.imageUrl!,
    ];
    if (allPhotos.isEmpty) return _noImgBox(200);
    void openGallery(int i) {
      final galleryItems = allPhotos
          .map((url) => GalleryItem(url: url, memoryId: memory.id))
          .toList();
      Navigator.of(context).push<String>(
        PageRouteBuilder(
          opaque: false,
          barrierColor: Colors.black,
          pageBuilder: (_, __, ___) =>
              FullscreenGallery(items: galleryItems, initialIndex: i),
        ),
      );
    }

    Widget photoWidget;
    if (allPhotos.length == 1) {
      photoWidget = GestureDetector(
        onTap: () => openGallery(0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: AspectRatio(
            aspectRatio: 1.0,
            child: StorageImage(
              imageUrl: allPhotos.first,
              fit: BoxFit.cover,
              memCacheWidth: 800,
              memCacheHeight: 800,
              errorWidget: (_, __, ___) => _noImgBox(200),
            ),
          ),
        ),
      );
    } else {
      photoWidget = _buildPhotoGrid(allPhotos, openGallery);
    }

    if (memory.isAdult) {
      return _BlurAfterTap(child: photoWidget);
    }
    return photoWidget;
  }

  // ── SMART PHOTO GRID ─────────────────────────────────────────────────────────
  // Adapts layout to photo count: 1→square, 2→side-by-side, 3→big+two,
  // 4→2×2, 5→2+3, 6→3+3, 7-8→3+3 with +N badge, 9→3×3, 10+→3×3 with badge.
  Widget _buildPhotoGrid(List<String> photos, void Function(int) onTap) {
    final n = photos.length;
    const gap = 3.0;
    const innerR = BorderRadius.all(Radius.circular(8));
    const outerR = BorderRadius.all(Radius.circular(18));

    Widget cell(int index, {double? aspect, int? extraCount}) {
      return GestureDetector(
        onTap: () => onTap(index),
        child: ClipRRect(
          borderRadius: innerR,
          child: AspectRatio(
            aspectRatio: aspect ?? 1.0,
            child: Stack(
              fit: StackFit.expand,
              children: [
                StorageImage(
                  imageUrl: photos[index],
                  fit: BoxFit.cover,
                  memCacheWidth: 600,
                  memCacheHeight: 600,
                  fadeInDuration: const Duration(milliseconds: 180),
                  errorWidget: (_, __, ___) => Container(
                    color: context.appTheme.surfaceMuted,
                    child: Icon(Icons.image_not_supported_rounded,
                        color: context.appTheme.textMuted, size: 28),
                  ),
                ),
                if (extraCount != null && extraCount > 0)
                  Container(
                    color: Colors.black54,
                    alignment: Alignment.center,
                    child: Text(
                      '+$extraCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    Widget photoRow(List<int> indices, {int? moreCount}) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int k = 0; k < indices.length; k++) ...[
            if (k > 0) const SizedBox(width: gap),
            Expanded(
              child: cell(
                indices[k],
                extraCount: k == indices.length - 1 ? moreCount : null,
              ),
            ),
          ],
        ],
      );
    }

    late Widget body;
    if (n == 1) {
      body = cell(0, aspect: 1.0);
    } else if (n == 2) {
      body = photoRow([0, 1]);
    } else if (n == 3) {
      body = Column(
        children: [
          cell(0, aspect: 1.0),
          const SizedBox(height: gap),
          photoRow([1, 2]),
        ],
      );
    } else if (n == 4) {
      body = Column(
        children: [
          photoRow([0, 1]),
          const SizedBox(height: gap),
          photoRow([2, 3]),
        ],
      );
    } else if (n == 5) {
      body = Column(
        children: [
          photoRow([0, 1]),
          const SizedBox(height: gap),
          photoRow([2, 3, 4]),
        ],
      );
    } else if (n == 6) {
      body = Column(
        children: [
          photoRow([0, 1, 2]),
          const SizedBox(height: gap),
          photoRow([3, 4, 5]),
        ],
      );
    } else if (n <= 8) {
      body = Column(
        children: [
          photoRow([0, 1, 2]),
          const SizedBox(height: gap),
          photoRow([3, 4, 5], moreCount: n - 6),
        ],
      );
    } else {
      // 9+: 3×3, last cell shows +N if more than 9
      body = Column(
        children: [
          photoRow([0, 1, 2]),
          const SizedBox(height: gap),
          photoRow([3, 4, 5]),
          const SizedBox(height: gap),
          photoRow([6, 7, 8], moreCount: n > 9 ? n - 9 : null),
        ],
      );
    }

    return ClipRRect(
      borderRadius: outerR,
      child: body,
    );
  }

  Widget _buildVideoMedia(Memory memory, Color p) {
    final hasThumb = memory.imageUrl?.isNotEmpty == true;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        children: [
          if (hasThumb)
            StorageImage(
              imageUrl: memory.imageUrl!,
              width: double.infinity,
              height: 220,
              fit: BoxFit.cover,
            )
          else
            Container(
                height: 220,
                color: context.appTheme.isDark
                    ? context.appTheme.surfaceMuted
                    : Colors.grey.shade900),
          Container(
            height: 220,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.1),
                  Colors.black.withOpacity(0.45),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 220,
            width: double.infinity,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  final url = memory.videoUrl;
                  if (url != null && url.isNotEmpty) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _InAppVideoPlayerPage(
                          url: url,
                          title: memory.title,
                        ),
                        settings: const RouteSettings(name: '/video_player'),
                      ),
                    );
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.92),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(Icons.play_arrow_rounded, size: 42, color: p),
                ),
              ),
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.videocam_rounded,
                    size: 12,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    LocaleService.current.videoBadge,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
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

  Widget _buildVideoLinkMedia(Memory memory, Color p) {
    final platform = _MemoryLaneScreenState._detectVideoPlatform(
      memory.videoUrl ?? '',
    );
    final platformColor = platform['color'] as Color;
    final platformName = platform['name'] as String;
    final hasThumb = memory.imageUrl?.isNotEmpty == true;

    return Container(
      decoration: BoxDecoration(
        color: platformColor.withOpacity(0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: platformColor.withOpacity(0.18), width: 1),
      ),
      child: Column(
        children: [
          // Thumbnail strip
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasThumb)
                    StorageImage(
                      imageUrl: memory.imageUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) =>
                          _buildThumbFallback(platformColor, platformName),
                    )
                  else
                    _buildThumbFallback(platformColor, platformName),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.55),
                        ],
                      ),
                    ),
                  ),
                  // Play button
                  Center(
                    child: GestureDetector(
                      onTap: () {
                        final url = memory.videoUrl;
                        if (url != null && url.isNotEmpty) {
                          launchUrl(
                            Uri.parse(url),
                            mode: LaunchMode.externalApplication,
                          );
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.92),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 42,
                          color: platformColor,
                        ),
                      ),
                    ),
                  ),
                  // Platform badge
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _MemoryLaneScreenState._videoPlatformIcon(
                              platformName,
                            ),
                            size: 12,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            platformName.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
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
          // Bottom row: author + open button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Row(
              children: [
                if (memory.musicArtist?.isNotEmpty == true)
                  Expanded(
                    child: Text(
                      memory.musicArtist!,
                      style: TextStyle(
                        fontSize: 13,
                        color: context.appTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else
                  const Spacer(),
                ElevatedButton.icon(
                  onPressed: () {
                    final url = memory.videoUrl;
                    if (url != null && url.isNotEmpty) {
                      launchUrl(
                        Uri.parse(url),
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  icon: const Icon(
                    Icons.open_in_new_rounded,
                    size: 15,
                    color: Colors.white,
                  ),
                  label: Text(
                    LocaleService.current.openIn(platformName),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: platformColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    elevation: 0,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbFallback(Color platformColor, String platformName) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            platformColor.withOpacity(0.75),
            platformColor.withOpacity(0.45),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.play_circle_outline_rounded,
              color: Colors.white.withOpacity(0.9),
              size: 52,
            ),
            const SizedBox(height: 6),
            Text(
              platformName,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationMedia(Memory memory, Color p) {
    final hasCoords = memory.latitude != null && memory.longitude != null;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.withOpacity(0.07), p.withOpacity(0.02)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.withOpacity(0.18), width: 1),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [p, p.withOpacity(0.75)],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: context.appTheme.accentGlow(
                    p,
                    opacity: 0.3,
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ),
                child: const Icon(
                  Icons.location_on_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      memory.locationName ??
                          LocaleService.current.unknownLocation,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: context.appTheme.textPrimary,
                      ),
                    ),
                    if (memory.latitude != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        '${memory.latitude!.toStringAsFixed(5)}, '
                        '${memory.longitude?.toStringAsFixed(5) ?? ""}',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.appTheme.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (hasCoords) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _showMapsPickerSheet(
                  context,
                  memory.latitude!,
                  memory.longitude!,
                  memory.locationName,
                ),
                icon: const Icon(Icons.map_rounded, size: 18),
                label: Text(LocaleService.current.openInGoogleMaps),
                style: ElevatedButton.styleFrom(
                  backgroundColor: p,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTextMedia(Memory memory, Color p) {
    final text = memory.caption ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.withOpacity(0.07), p.withOpacity(0.02)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.withOpacity(0.15), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: p.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.format_quote_rounded, color: p, size: 16),
              ),
              const SizedBox(width: 8),
              Text(
                LocaleService.current.noteBadge,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: p,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SpoilerRichText(
            text: text,
            style: TextStyle(
              fontSize: 16,
              color: context.appTheme.textPrimary,
              height: 1.65,
            ),
          ),
        ],
      ),
    );
  }

  // ── BOOK MEDIA (full detail card with 3D cover) ──────────────────────────────
  Widget _buildBookMedia(Memory memory, Color p) {
    final title = memory.title?.isNotEmpty == true
        ? memory.title!
        : LocaleService.current.books;
    final author = memory.bookAuthor ?? '';
    final hasYear = memory.bookYear?.isNotEmpty == true;
    final hasPublisher = memory.bookPublisher?.isNotEmpty == true;
    final hasInfo = memory.bookInfoUrl?.isNotEmpty == true;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.withOpacity(0.07), p.withOpacity(0.02)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.withOpacity(0.15), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Badge ──
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: p.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.menu_book_rounded, color: p, size: 16),
              ),
              const SizedBox(width: 8),
              Text(
                LocaleService.current.books.toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: p,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ── 3D cover + meta side by side ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MiniBookCover(
                accent: p,
                coverUrl: memory.bookCoverUrl,
                title: title,
                author: author,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: context.appTheme.textPrimary,
                        height: 1.25,
                      ),
                    ),
                    if (author.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        author,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    if (hasYear || hasPublisher)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (hasYear)
                            _detailChip(
                              Icons.calendar_today_rounded,
                              memory.bookYear!,
                              p,
                            ),
                          if (hasPublisher)
                            _detailChip(
                              Icons.business_rounded,
                              memory.bookPublisher!,
                              p,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
          // ── Rating ──
          if (memory.rating != null) ...[
            const SizedBox(height: 16),
            _ratingRow(memory.rating!),
          ],
          // ── Review (caption) ──
          if (memory.caption?.isNotEmpty == true) ...[
            const SizedBox(height: 16),
            _reviewHeader(p),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.appTheme.cardSurface.withOpacity(0.55),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.withOpacity(0.10)),
              ),
              child: _SpoilerRichText(
                text: memory.caption!,
                style: TextStyle(
                  fontSize: 14.5,
                  color: context.appTheme.textPrimary,
                  height: 1.55,
                ),
              ),
            ),
          ],
          // ── "Read more" link ──
          if (hasInfo) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(memory.bookInfoUrl!),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(
                  Icons.open_in_new_rounded,
                  size: 16,
                  color: Colors.white,
                ),
                label: Text(
                  LocaleService.current.bookReadMore,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: p,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _ratingRow(int rating) {
    return Row(
      children: [
        Text(
          LocaleService.current.yourRating,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: context.appTheme.textSecondary,
          ),
        ),
        const SizedBox(width: 10),
        RatingBadge(rating: rating, fontSize: 14),
      ],
    );
  }

  Widget _reviewHeader(Color p) {
    return Row(
      children: [
        Icon(Icons.rate_review_rounded, size: 14, color: p),
        const SizedBox(width: 6),
        Text(
          LocaleService.current.yourReview.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: p,
            letterSpacing: 1.0,
          ),
        ),
      ],
    );
  }

  // ── MOVIE / SERIES DETAIL ──
  Widget _buildMovieMedia(Memory memory, Color p) {
    final s = LocaleService.current;
    final isRu = LocaleService.instance.isRussian;
    final title = memory.title?.isNotEmpty == true ? memory.title! : s.movies;
    final original = memory.movieOriginalTitle ?? '';
    final hasOriginal = original.isNotEmpty && original != title;
    final hasYear = memory.movieYear?.isNotEmpty == true;
    final hasGenres = memory.movieGenres?.isNotEmpty == true;
    final hasCountry = memory.movieCountry?.isNotEmpty == true;
    final hasKp = memory.movieRatingKp?.isNotEmpty == true;
    final hasInfo = memory.movieInfoUrl?.isNotEmpty == true;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.withOpacity(0.07), p.withOpacity(0.02)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.withOpacity(0.15), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Badge ──
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: p.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.local_movies_rounded, color: p, size: 16),
              ),
              const SizedBox(width: 8),
              Text(
                movieKindLabel(memory.movieKind, isRu: isRu).toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: p,
                  letterSpacing: 1.2,
                ),
              ),
              if (hasKp) ...[
                const Spacer(),
                Icon(Icons.star_rounded, size: 15, color: Colors.amber.shade600),
                const SizedBox(width: 3),
                Text(
                  LocaleService.current.kpRating(memory.movieRatingKp!),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.amber.shade800,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          // ── Poster + meta ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MiniMoviePoster(
                accent: p,
                posterUrl: memory.moviePosterUrl,
                title: title,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: context.appTheme.textPrimary,
                        height: 1.25,
                      ),
                    ),
                    if (hasOriginal) ...[
                      const SizedBox(height: 6),
                      Text(
                        original,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    if (hasYear || hasGenres || hasCountry)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (hasYear)
                            _detailChip(
                              Icons.calendar_today_rounded,
                              memory.movieYear!,
                              p,
                            ),
                          if (hasGenres)
                            _detailChip(
                              Icons.theaters_rounded,
                              memory.movieGenres!,
                              p,
                            ),
                          if (hasCountry)
                            _detailChip(
                              Icons.public_rounded,
                              memory.movieCountry!,
                              p,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
          // ── Rating ──
          if (memory.rating != null) ...[
            const SizedBox(height: 16),
            _ratingRow(memory.rating!),
          ],
          // ── Review (caption) ──
          if (memory.caption?.isNotEmpty == true) ...[
            const SizedBox(height: 16),
            _reviewHeader(p),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.appTheme.cardSurface.withOpacity(0.55),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.withOpacity(0.10)),
              ),
              child: _SpoilerRichText(
                text: memory.caption!,
                style: TextStyle(
                  fontSize: 14.5,
                  color: context.appTheme.textPrimary,
                  height: 1.55,
                ),
              ),
            ),
          ],
          // ── Open on Kinopoisk ──
          if (hasInfo) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(memory.movieInfoUrl!),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(
                  Icons.open_in_new_rounded,
                  size: 16,
                  color: Colors.white,
                ),
                label: Text(
                  s.movieReadMore,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: p,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailChip(IconData icon, String label, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: accent),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── LOCATION ROW (shown for all memory types that have coords/name) ──────────
  Widget _buildLocationRow(Memory memory, Color p) {
    final hasCoords = memory.latitude != null && memory.longitude != null;
    final hasName = memory.locationName?.isNotEmpty == true;
    if (!hasCoords && !hasName) return const SizedBox.shrink();
    // Don't duplicate — location type already shows full card via _buildLocationMedia
    if (memory.type == MemoryType.location) return const SizedBox.shrink();

    String? distLabel;
    Color pillColor = context.appTheme.textMuted;
    if (hasCoords && widget.userLat != null && widget.userLng != null) {
      final m = Geolocator.distanceBetween(
        widget.userLat!, widget.userLng!,
        memory.latitude!, memory.longitude!,
      );
      final km = m / 1000;
      distLabel = LocaleService.current.distanceLabel(m);
      if (km < 1) {
        pillColor = const Color(0xFF22C55E);
      } else if (km < 10) {
        pillColor = const Color(0xFF16A34A);
      } else if (km < 50) {
        pillColor = const Color(0xFFF59E0B);
      } else {
        pillColor = const Color(0xFFEF4444);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: GestureDetector(
        onTap: hasCoords
            ? () => _showMapsPickerSheet(
                context, memory.latitude!, memory.longitude!, memory.locationName)
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: hasCoords ? pillColor.withOpacity(0.06) : context.appTheme.surfaceMuted,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: hasCoords ? pillColor.withOpacity(0.25) : context.appTheme.divider,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: hasCoords ? pillColor.withOpacity(0.12) : context.appTheme.surfaceMuted,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.location_on_rounded,
                  size: 18,
                  color: hasCoords ? pillColor : context.appTheme.textMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hasName)
                      Text(
                        memory.locationName!,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: context.appTheme.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (distLabel != null)
                      Text(
                        distLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: pillColor,
                        ),
                      )
                    else if (!hasName)
                      Text(
                        '${memory.latitude!.toStringAsFixed(5)}, ${memory.longitude!.toStringAsFixed(5)}',
                        style: TextStyle(fontSize: 12, color: context.appTheme.textMuted),
                      ),
                  ],
                ),
              ),
              if (hasCoords) ...[
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded, size: 18, color: pillColor),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Shows a bottom sheet with map app choices to build a route.
  static Future<void> _showMapsPickerSheet(
    BuildContext context,
    double lat,
    double lng,
    String? label,
  ) async {
    final t = context.appTheme;
    final encodedLabel = label != null ? Uri.encodeComponent(label) : '';

    final apps = [
      (
        name: 'Google Maps',
        icon: Icons.map_rounded,
        color: const Color(0xFF4285F4),
        url: 'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng',
      ),
      (
        name: 'Яндекс Карты',
        icon: Icons.directions_rounded,
        color: const Color(0xFFFC3F1D),
        url: 'yandexmaps://maps.yandex.ru/?rtext=~$lat,$lng&rtt=auto',
      ),
      (
        name: '2GIS',
        icon: Icons.location_city_rounded,
        color: const Color(0xFF00AF43),
        url: 'dgis://2gis.ru/routeSearch/rsType/car/to/$lng,$lat',
      ),
      (
        name: 'Waze',
        icon: Icons.navigation_rounded,
        color: const Color(0xFF09D3AC),
        url: 'https://waze.com/ul?ll=$lat,$lng&navigate=yes',
      ),
      (
        name: 'Apple Maps',
        icon: Icons.map_outlined,
        color: const Color(0xFF007AFF),
        url: 'https://maps.apple.com/?daddr=$lat,$lng&q=$encodedLabel',
      ),
    ];

    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: t.cardSurface,
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: t.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (label != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    children: [
                      Icon(Icons.location_on_rounded,
                          size: 16, color: t.textMuted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: t.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ...apps.map((app) => _MapAppTile(
                    name: app.name,
                    icon: app.icon,
                    color: app.color,
                    url: app.url,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  // ── CAPTION ──────────────────────────────────────────────────────────────────
  Widget _buildCaption(Memory memory) {
    if (memory.type == MemoryType.text) return const SizedBox.shrink();
    final caption = memory.caption;
    if (caption == null || caption.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Text(
        caption,
        style: TextStyle(
          fontSize: 15.5,
          color: context.appTheme.textPrimary,
          height: 1.55,
        ),
      ),
    );
  }

  // ── ACTIONS ───────────────────────────────────────────────────────────────────
  Widget _buildActions(Memory memory, Color p) {
    return Column(
      children: [
        Container(height: 1, color: context.appTheme.divider),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _actionBtn(
                icon: memory.isPinned
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                label: memory.isPinned
                    ? LocaleService.current.unpinMemory
                    : LocaleService.current.pinMemory,
                color: p,
                // Закрепление — основное действие: залитая кнопка под цвет темы.
                filled: !memory.isPinned,
                onTap: () {
                  Navigator.pop(context);
                  widget.onTogglePin();
                },
              ),
            ),
            if (widget.canDownload) ...[
              const SizedBox(width: 10),
              Expanded(
                child: _actionBtn(
                  icon: Icons.download_rounded,
                  label: LocaleService.current.saveToDevice,
                  color: p,
                  onTap: () {
                    Navigator.pop(context);
                    widget.onDownload();
                  },
                ),
              ),
            ],
          ],
        ),
        if (widget.isOwner) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _actionBtn(
                  icon: Icons.edit_rounded,
                  label: LocaleService.current.editMemory,
                  color: p,
                  onTap: () {
                    Navigator.pop(context);
                    widget.onEdit();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _actionBtn(
                  icon: Icons.delete_outline_rounded,
                  label: LocaleService.current.deleteMemory,
                  color: const Color(0xFFEF4444),
                  onTap: () {
                    Navigator.pop(context);
                    widget.onDelete();
                  },
                ),
              ),
            ],
          ),
          // Show "Set Location" only when the memory has no location yet
          if (widget.onSetLocation != null &&
              widget.memory.type != MemoryType.location &&
              widget.memory.latitude == null &&
              widget.memory.longitude == null &&
              (widget.memory.locationName?.isEmpty ?? true)) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: _actionBtn(
                icon: Icons.add_location_alt_rounded,
                label: LocaleService.current.selectLocation,
                color: p,
                onTap: () {
                  Navigator.pop(context);
                  widget.onSetLocation!();
                },
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    // Залитая кнопка — сплошной цвет, белый текст; обычная — мягкая заливка
    // тем же цветом без рамки (меньше цветов, всё под тему).
    final bgColor = filled ? color : color.withValues(alpha: 0.10);
    final fgColor = filled ? Colors.white : color;
    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: fgColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: fgColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noImgBox(double h) => Container(
    height: h,
    decoration: BoxDecoration(
      color: context.appTheme.surfaceMuted,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Center(
      child: Icon(
        Icons.image_not_supported_rounded,
        color: context.appTheme.textMuted,
        size: 48,
      ),
    ),
  );

  static String _fmtDate(DateTime dt) {
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month]} ${dt.day}, ${dt.year} at $h:$m';
  }
}

// ══════════════════════════════════════════════════════
//  Comments Section Widget
// ══════════════════════════════════════════════════════

class _CommentsSection extends StatefulWidget {
  final String groupId;
  final String memoryId;
  final Color primary;

  const _CommentsSection({
    required this.groupId,
    required this.memoryId,
    required this.primary,
  });

  @override
  State<_CommentsSection> createState() => _CommentsSectionState();
}

class _CommentsSectionState extends State<_CommentsSection> {
  final TextEditingController _ctrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      // Rate-limit раньше жил внутри FirebaseService.addComment; репозиторий PB
      // его не делает, поэтому проверяем здесь (бросает RateLimitException ниже).
      await RateLimiterService().checkAndRecordComment();
      await MemoryRepository().addComment(
        groupId: widget.groupId,
        memoryId: widget.memoryId,
        text: text,
      );
      _ctrl.clear();
    } on RateLimitException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.appTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 18,
              color: t.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              LocaleService.current.comments,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: t.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Comment list (real-time)
        StreamBuilder<List<MemoryComment>>(
          stream: MemoryRepository().watchComments(widget.groupId, widget.memoryId),
          builder: (context, snap) {
            final comments = snap.data ?? [];
            if (comments.isEmpty) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  LocaleService.current.noCommentsYet,
                  style: TextStyle(
                    fontSize: 13,
                    color: t.textMuted,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              );
            }
            // Column is faster than shrinkWrap ListView inside a ScrollView:
            // shrinkWrap forces a full second-pass layout on every rebuild.
            return Column(
              children: [
                for (int i = 0; i < comments.length; i++) ...[
                  if (i > 0) const SizedBox(height: 10),
                  _commentBubble(comments[i]),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 12),

        // Input field
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                textCapitalization: TextCapitalization.sentences,
                maxLines: 4,
                minLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: LocaleService.current.writeAComment,
                  hintStyle: TextStyle(color: t.textMuted),
                  filled: true,
                  fillColor: t.surfaceMuted,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(color: t.divider),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(color: t.divider),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(color: widget.primary, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _sending ? null : _send,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: widget.primary,
                  shape: BoxShape.circle,
                ),
                child: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.send_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _commentBubble(MemoryComment comment) {
    final isMe = comment.authorUid == PocketBaseService().userId;
    final t = context.appTheme;
    return GestureDetector(
      onLongPress: isMe ? () => _confirmDeleteComment(comment) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AvatarWidget(
            uid: comment.authorUid,
            fallbackUrl: comment.authorAvatar,
            name: comment.authorName,
            size: 28,
            primary: widget.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isMe
                    ? widget.primary.withOpacity(0.06)
                    : t.surfaceMuted,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isMe
                      ? widget.primary.withOpacity(0.15)
                      : t.divider,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        comment.authorName,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isMe ? widget.primary : t.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _timeAgo(comment.createdAt),
                        style: TextStyle(
                          fontSize: 10,
                          color: t.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    comment.text,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: t.textPrimary,
                      height: 1.35,
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

  void _confirmDeleteComment(MemoryComment comment) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(LocaleService.current.deleteCommentQuestion),
        content: Text(LocaleService.current.actionCannotBeUndone),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(LocaleService.current.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              MemoryRepository().deleteComment(comment.id);
            },
            child: Text(
              LocaleService.current.delete,
              style: TextStyle(color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
  }
}

// ══════════════════════════════════════════════════════
//  GalleryItem — a single photo or video entry
// ══════════════════════════════════════════════════════
class GalleryItem {
  final String url;       // photo URL or video thumbnail
  final String? videoUrl; // non-null for video items
  final String memoryId;
  final String? caption;

  const GalleryItem({
    required this.url,
    this.videoUrl,
    required this.memoryId,
    this.caption,
  });

  bool get isVideo => videoUrl != null;
}

