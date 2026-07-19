import 'package:flutter/material.dart';
import '../../utils/safe_text.dart';
import 'package:geolocator/geolocator.dart';
import '../../models/memory.dart';
import '../../models/pair_data.dart';
import '../../models/user_data.dart';
import '../../services/locale_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/storage_image.dart';
import '../memory_lane_screen.dart';

/// Секция «Воспоминания» на главном экране: превью последних 3 воспоминаний.
/// Если партнёр не подключён — заглушка. Карточки повторяют новый дизайн ленты
/// (плоско, аватар + бейдж типа, коллаж/стикер/карточка места), компактно;
/// тап по любой карточке открывает полную Ленту.
class MemoryLanePreview extends StatelessWidget {
  final bool isPaired;
  final List<Memory> memories;
  final PairData pairData;
  final AppTheme theme;
  final double? userLat;
  final double? userLng;
  final UserData? userData;

  /// Тап по вкладке общего навбара внутри открытой Ленты — главный экран
  /// закрывает Ленту и переключает вкладку. null → навбар в Ленте не рисуется.
  final void Function(int index)? onNavTab;

  const MemoryLanePreview({
    super.key,
    required this.isPaired,
    required this.memories,
    required this.pairData,
    required this.theme,
    this.userLat,
    this.userLng,
    this.userData,
    this.onNavTab,
  });

  @override
  Widget build(BuildContext context) {
    if (!isPaired) return _buildEmpty(context);
    return _buildPaired(context);
  }

  // ── Paired view ────────────────────────────────────────────────────────────

  Widget _buildPaired(BuildContext context) {
    final primary = theme.primary;

    String avatarFor(Memory m) {
      final ud = userData;
      if (ud != null && m.authorUid == ud.uid && ud.avatarUrl.isNotEmpty) {
        return ud.avatarUrl;
      }
      for (final mem in pairData.members) {
        if (mem.uid == m.authorUid && mem.avatar.isNotEmpty) return mem.avatar;
      }
      return m.authorAvatar;
    }

    String nameFor(Memory m) {
      for (final mem in pairData.members) {
        if (mem.uid == m.authorUid && mem.name.isNotEmpty) return mem.name;
      }
      return m.authorName;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                LocaleService.current.relationshipMemoryLane,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.textPrimary,
                ),
              ),
              GestureDetector(
                onTap: () => _openMemoryLane(context),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha:0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        LocaleService.current.viewAll,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: primary,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(Icons.chevron_right_rounded, size: 18, color: primary),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (memories.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              height: 140,
              decoration: BoxDecoration(
                color: theme.cardSurface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: theme.divider, width: 0.5),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.photo_album_outlined,
                        size: 32, color: Colors.grey.shade300),
                    const SizedBox(height: 8),
                    Text(
                      LocaleService.current.noMemoriesYet,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: theme.textMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      LocaleService.current.addFirstMemory,
                      style: TextStyle(fontSize: 12, color: theme.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                for (int i = 0; i < memories.length && i < 3; i++)
                  _PreviewCard(
                    memory: memories[i],
                    theme: theme,
                    authorName: nameFor(memories[i]),
                    authorAvatar: avatarFor(memories[i]),
                    distanceText: _distanceKm(
                      memories[i].latitude,
                      memories[i].longitude,
                    ),
                    onTap: () => _openMemoryLane(context),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  // ── Empty (unpaired) view ──────────────────────────────────────────────────

  Widget _buildEmpty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                LocaleService.current.relationshipMemoryLane,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            height: 160,
            decoration: BoxDecoration(
              color: theme.cardSurface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: theme.divider, width: 0.5),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.photo_library_outlined,
                    size: 36, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                Text(
                  LocaleService.current.memoriesWillAppear,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: theme.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  LocaleService.current.connectWithPartnerToStart,
                  style: TextStyle(fontSize: 12, color: theme.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _openMemoryLane(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MemoryLaneScreen(
          pairData: pairData,
          theme: theme,
          userData: userData,
          onNavTab: onNavTab == null
              ? null
              // context мог устареть к моменту тапа по вкладке → Navigator.of
              // даёт "Null check operator used on a null value". Гардим mounted
              // и зовём onNavTab через ?.call. См. Bugsink #24.
              : (i) {
                  if (context.mounted) Navigator.of(context).pop();
                  onNavTab?.call(i);
                },
        ),
        settings: const RouteSettings(name: '/memory_lane'),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _distanceKm(double? lat, double? lng) {
    if (lat == null || lng == null || userLat == null || userLng == null) {
      return '';
    }
    final d = Geolocator.distanceBetween(userLat!, userLng!, lat, lng);
    if (d < 1000) return '${d.round()} м';
    return '${(d / 1000).toStringAsFixed(1)} км';
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  Компактная карточка превью (новый дизайн ленты, read-only, тап → Лента)
// ════════════════════════════════════════════════════════════════════════════
class _PreviewCard extends StatelessWidget {
  final Memory memory;
  final AppTheme theme;
  final String authorName;
  final String authorAvatar;
  final String distanceText;
  final VoidCallback onTap;

  const _PreviewCard({
    required this.memory,
    required this.theme,
    required this.authorName,
    required this.authorAvatar,
    required this.distanceText,
    required this.onTap,
  });

  Color get primary => theme.primary;
  bool get _ru => LocaleService.instance.isRussian;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: theme.cardSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: theme.divider),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(),
              const SizedBox(height: 12),
              _body(),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  // ── Header: аватар · имя · время · бейдж типа ──
  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: primary.withValues(alpha:0.18), width: 1.5),
            ),
            child: ClipOval(
              child: authorAvatar.isNotEmpty
                  ? StorageImage(
                      imageUrl: authorAvatar,
                      fit: BoxFit.cover,
                      memCacheWidth: 120,
                      memCacheHeight: 120,
                      errorWidget: (_, _, _) => _avatarFallback(),
                    )
                  : _avatarFallback(),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    authorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: theme.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '  ·  ${_timeAgo(memory.createdAt)}',
                  style: TextStyle(fontSize: 12, color: theme.textMuted),
                ),
              ],
            ),
          ),
          _typeBadge(),
        ],
      ),
    );
  }

  Widget _avatarFallback() {
    final letter = authorName.firstGraphemeUpper('♥');
    return Container(
      color: primary.withValues(alpha:0.12),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: primary,
          fontWeight: FontWeight.w800,
          fontSize: 16,
        ),
      ),
    );
  }

  Widget _typeBadge() {
    final meta = _badgeMeta(memory.type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: primary.withValues(alpha:0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(meta.$2, size: 13, color: primary),
          const SizedBox(width: 5),
          Text(
            meta.$1,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: primary,
            ),
          ),
        ],
      ),
    );
  }

  (String, IconData) _badgeMeta(MemoryType t) {
    switch (t) {
      case MemoryType.photo:
      case MemoryType.video:
        return (_ru ? 'Момент' : 'Moment', Icons.favorite_rounded);
      case MemoryType.location:
        return (_ru ? 'Локация' : 'Location', Icons.place_rounded);
      case MemoryType.music:
        return (_ru ? 'Музыка' : 'Music', Icons.music_note_rounded);
      case MemoryType.videoLink:
        return (_ru ? 'Видео' : 'Video', Icons.play_circle_fill_rounded);
      case MemoryType.text:
        return (_ru ? 'Заметка' : 'Note', Icons.sticky_note_2_rounded);
      case MemoryType.book:
        return (_ru ? 'Книга' : 'Book', Icons.menu_book_rounded);
      case MemoryType.movie:
        return (_ru ? 'Фильм' : 'Movie', Icons.movie_rounded);
    }
  }

  // ── Body per type ──
  Widget _body() {
    switch (memory.type) {
      case MemoryType.music:
        return MemoryMusicPlayer(
          key: ValueKey('preview_player_${memory.id}'),
          memory: memory,
          theme: theme,
          bodyOnly: true,
        );
      case MemoryType.text:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: _noteSticker(),
        );
      case MemoryType.location:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _placeCard(),
              _caption(),
            ],
          ),
        );
      case MemoryType.book:
      case MemoryType.movie:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: _coverRow(),
        );
      case MemoryType.videoLink:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _videoThumb(),
              _caption(),
            ],
          ),
        );
      case MemoryType.photo:
      case MemoryType.video:
        final photos = <String>[
          if (memory.imageUrls?.isNotEmpty == true)
            ...memory.imageUrls!
          else if (memory.imageUrl?.isNotEmpty == true)
            memory.imageUrl!,
        ];
        final hasVideo = memory.videoUrl?.isNotEmpty == true;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (photos.isNotEmpty)
                _collage(photos, hasVideo)
              else if (hasVideo)
                _videoOnly(),
              _caption(),
            ],
          ),
        );
    }
  }

  // ── Подпись (заголовок + описание) ──
  Widget _caption() {
    final title = memory.title?.isNotEmpty == true ? memory.title! : '';
    final cap = memory.caption?.isNotEmpty == true ? memory.caption! : '';
    if (title.isEmpty && cap.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: theme.textPrimary,
              ),
            ),
          if (cap.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: title.isNotEmpty ? 2 : 0),
              child: Text(
                cap,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  color: theme.textSecondary,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Коллаж фото (компактный) ──
  Widget _collage(List<String> photos, bool hasVideo) {
    const gap = 4.0;
    final n = photos.length;

    Widget tile(int i, {int extra = 0}) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            StorageImage(
              imageUrl: photos[i],
              fit: BoxFit.cover,
              memCacheWidth: 500,
              errorWidget: (_, _, _) => Container(
                color: theme.surfaceMuted,
                child: Icon(Icons.broken_image_rounded,
                    color: theme.textMuted, size: 22),
              ),
            ),
            if (hasVideo && i == 0)
              const Center(
                child: Icon(Icons.play_circle_fill_rounded,
                    color: Colors.white, size: 34),
              ),
            if (extra > 0)
              Container(
                color: Colors.black.withValues(alpha:0.45),
                alignment: Alignment.center,
                child: Text(
                  '+$extra',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    if (n == 1) {
      return AspectRatio(aspectRatio: 16 / 9, child: tile(0));
    }
    if (n == 2) {
      return SizedBox(
        height: 100,
        child: Row(children: [
          Expanded(child: tile(0)),
          const SizedBox(width: gap),
          Expanded(child: tile(1)),
        ]),
      );
    }
    final extra = n - 3;
    return SizedBox(
      height: 100,
      child: Row(children: [
        Expanded(child: tile(0)),
        const SizedBox(width: gap),
        Expanded(child: tile(1)),
        const SizedBox(width: gap),
        Expanded(child: tile(2, extra: extra)),
      ]),
    );
  }

  Widget _videoOnly() {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          color: Colors.grey.shade900,
          child: const Center(
            child: Icon(Icons.play_circle_fill_rounded,
                color: Colors.white, size: 40),
          ),
        ),
      ),
    );
  }

  // ── Видео-ссылка: превью с play ──
  Widget _videoThumb() {
    final hasThumb = memory.imageUrl?.isNotEmpty == true;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasThumb)
              StorageImage(
                imageUrl: memory.imageUrl!,
                fit: BoxFit.cover,
                memCacheWidth: 600,
                errorWidget: (_, _, _) => Container(color: theme.surfaceMuted),
              )
            else
              Container(color: Colors.grey.shade800),
            Container(color: Colors.black.withValues(alpha:0.22)),
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.play_arrow_rounded, color: primary, size: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Заметка: жёлтый стикер ──
  Widget _noteSticker() {
    final title = memory.title?.isNotEmpty == true ? memory.title! : '';
    final body = memory.caption?.isNotEmpty == true
        ? memory.caption!
        : (title.isEmpty ? (_ru ? 'Заметка' : 'Note') : '');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFCE08A),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF5A4A1E),
                ),
              ),
            ),
          if (body.isNotEmpty)
            Text(
              body,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF5A4A1E),
                height: 1.4,
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '— $authorName',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontStyle: FontStyle.italic,
              color: Color(0xFF7A6526),
            ),
          ),
        ],
      ),
    );
  }

  // ── Место: компактная карточка (без живой карты, для лёгкости главной) ──
  Widget _placeCard() {
    final name = memory.locationName?.isNotEmpty == true
        ? memory.locationName!
        : LocaleService.current.location;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: primary.withValues(alpha:0.10),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.location_on_rounded, color: primary, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: theme.textPrimary,
                height: 1.2,
              ),
            ),
          ),
          if (distanceText.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: primary.withValues(alpha:0.10),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                distanceText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: primary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Книга / фильм: обложка + название ──
  Widget _coverRow() {
    final cover = memory.type == MemoryType.book
        ? memory.bookCoverUrl
        : memory.moviePosterUrl;
    final title = memory.title?.isNotEmpty == true
        ? memory.title!
        : (_ru ? 'Без названия' : 'Untitled');
    final subtitle = memory.type == MemoryType.book
        ? (memory.bookAuthor ?? '')
        : (memory.movieYear ?? '');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 54,
              height: 78,
              child: (cover != null && cover.isNotEmpty)
                  ? StorageImage(
                      imageUrl: cover,
                      fit: BoxFit.cover,
                      memCacheWidth: 160,
                      errorWidget: (_, _, _) => _coverFallback(),
                    )
                  : _coverFallback(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: theme.textPrimary,
                    height: 1.25,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: theme.textMuted),
                    ),
                  ),
                if (memory.caption?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      memory.caption!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: theme.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverFallback() {
    return Container(
      color: primary.withValues(alpha:0.10),
      alignment: Alignment.center,
      child: Icon(
        memory.type == MemoryType.book
            ? Icons.menu_book_rounded
            : Icons.movie_rounded,
        color: primary,
        size: 22,
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final s = LocaleService.current;
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return s.justNow;
    if (diff.inMinutes < 60) return s.minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return s.hoursAgo(diff.inHours);
    if (diff.inDays < 30) return s.daysAgo(diff.inDays);
    return '${dt.day}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
  }
}
