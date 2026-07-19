part of '../memory_lane_screen.dart';

/// Готовит источник для just_audio с учётом наших схем:
/// • localfile:// → локальный файл (медиа, созданное офлайн);
/// • pb:// → HTTPS с file-токеном (раньше pb://-музыка не резолвилась — не играла);
/// • остальное (http/локальный путь) — как есть.
Future<void> _setAudioSource(AudioPlayer player, String url) async {
  if (MediaCache.instance.isLocalRef(url)) {
    final p = MediaCache.instance.localPath(url);
    if (p != null) {
      await player.setFilePath(p);
      return;
    }
  }
  if (PbMediaService().isPbRef(url)) {
    final resolved = await PbMediaService().resolveUrlAuthed(url);
    await player.setUrl(resolved ?? url);
    return;
  }
  await player.setUrl(url);
}

// ── Standalone music player widget for detail sheet ──
class _MusicPlayerWidget extends StatefulWidget {
  final Memory memory;
  final AudioPlayer? player;
  final void Function(AudioPlayer) onPlayerCreated;
  final Color primary;
  final Color typeColor;

  const _MusicPlayerWidget({
    required this.memory,
    required this.player,
    required this.onPlayerCreated,
    required this.primary,
    required this.typeColor,
  });

  @override
  State<_MusicPlayerWidget> createState() => _MusicPlayerWidgetState();
}

class _MusicPlayerWidgetState extends State<_MusicPlayerWidget> {
  AudioPlayer? _player;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _loading = false;
  String? _error;

  bool _isExternalLink = false;
  String? _sourceName;

  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    _player = widget.player;
    _detectSource();
  }

  @override
  void didUpdateWidget(_MusicPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.memory.musicUrl != widget.memory.musicUrl) {
      _sourceName = null;
      _isExternalLink = false;
      _detectSource();
    }
  }

  void _detectSource() {
    final url = widget.memory.musicUrl;
    if (url == null || url.isEmpty) return;
    final lower = url.toLowerCase();

    if (lower.contains('spotify')) {
      _sourceName = 'Spotify';
      _isExternalLink = true;
    } else if (lower.contains('music.youtube.com')) {
      _sourceName = 'YouTube Music';
      _isExternalLink = true;
    } else if (lower.contains('youtube') || lower.contains('youtu.be')) {
      _sourceName = 'YouTube';
      _isExternalLink = true;
    } else if (lower.contains('music.apple.com')) {
      _sourceName = 'Apple Music';
      _isExternalLink = true;
    } else if (lower.contains('deezer')) {
      _sourceName = 'Deezer';
      _isExternalLink = true;
    } else if (lower.contains('soundcloud')) {
      _sourceName = 'SoundCloud';
      _isExternalLink = true;
    } else if (lower.contains('music.yandex') ||
        lower.contains('yandex.ru/music')) {
      _sourceName = 'Яндекс Музыка';
      _isExternalLink = true;
    } else if (lower.contains('tidal.com')) {
      _sourceName = 'Tidal';
      _isExternalLink = true;
    } else if (lower.contains('vk.com/music') ||
        lower.contains('vk.com/audio') ||
        lower.contains('vk.ru/music')) {
      _sourceName = 'VK Музыка';
      _isExternalLink = true;
    } else if (lower.startsWith('http') &&
        !lower.contains('firebasestorage') &&
        !lower.contains('firebase')) {
      _sourceName = null;
      _isExternalLink = true;
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _initAndPlay() async {
    final url = widget.memory.musicUrl;
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _error = 'No audio URL');
      return;
    }

    // If it's an external streaming link open externally
    final lower = url.toLowerCase();
    if (lower.contains('spotify') ||
        lower.contains('youtube') ||
        lower.contains('youtu.be') ||
        lower.contains('music.apple.com') ||
        lower.contains('deezer') ||
        lower.contains('soundcloud') ||
        lower.contains('music.yandex') ||
        lower.contains('tidal.com') ||
        (!lower.contains('firebasestorage') &&
            !lower.contains('firebase') &&
            lower.startsWith('http'))) {
      safeLaunchUrl(Uri.parse(url));
      return;
    }

    if (!mounted) return;
    setState(() => _loading = true);
    try {
      _player ??= AudioPlayer();
      widget.onPlayerCreated(_player!);

      _posSub = _player!.positionStream.listen((pos) {
        if (mounted) setState(() => _position = pos);
      });
      _durSub = _player!.durationStream.listen((dur) {
        if (dur != null && mounted) setState(() => _duration = dur);
      });
      _stateSub = _player!.playerStateStream.listen((state) {
        if (mounted) {
          setState(() {
            _isPlaying = state.playing;
            if (state.processingState == ProcessingState.completed) {
              _isPlaying = false;
              _position = Duration.zero;
              _player?.seek(Duration.zero);
              _player?.pause();
            }
          });
        }
      });

      await _setAudioSource(_player!, url);
      if (mounted) setState(() => _loading = false);
      await _player!.play();
    } catch (e) {
      debugPrint('Audio player error: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Cannot play this audio';
        });
      }
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final memory = widget.memory;
    final p = widget.primary;
    final hasLocalPlayer = !_isExternalLink;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.withValues(alpha: 0.07), p.withValues(alpha: 0.02)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.withValues(alpha: 0.14)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Album art / cover + винил-перекличка с экраном создания
              _buildCover(memory, p),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_sourceName != null) ...[
                      _sourceChip(p),
                      const SizedBox(height: 6),
                    ],
                    Text(
                      memory.musicTitle ?? LocaleService.current.audioFile,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                        color: context.appTheme.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (memory.musicArtist != null &&
                        memory.musicArtist!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: memory.musicArtist!
                              .split(',')
                              .map((a) => a.trim())
                              .where((a) => a.isNotEmpty)
                              .map(
                                (a) => Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: p.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    a,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: p,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                  ],
                ),
              ),
              // Play / Pause button — only for local audio files
              if (hasLocalPlayer) ...[
                const SizedBox(width: 10),
                _buildPlayButton(p),
              ],
            ],
          ),
          // Progress bar — only for local audio
          if (hasLocalPlayer && _duration > Duration.zero) ...[
            const SizedBox(height: 14),
            WaveProgressBar(
              value: _duration.inMilliseconds > 0
                  ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(
                      0.0,
                      1.0,
                    )
                  : 0.0,
              color: p,
              isPlaying: _isPlaying,
              onChanged: (v) {
                _player?.seek(
                  Duration(
                    milliseconds: (v * _duration.inMilliseconds).toInt(),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatDuration(_position),
                    style: TextStyle(fontSize: 11, color: context.appTheme.textMuted),
                  ),
                  Text(
                    _formatDuration(_duration),
                    style: TextStyle(fontSize: 11, color: context.appTheme.textMuted),
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(fontSize: 12, color: Colors.red.shade400),
            ),
          ],
          // Открыть в стриминговом сервисе — залитая кнопка под цвет темы
          if (_isExternalLink && memory.musicUrl != null) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  launchUrl(
                    Uri.parse(memory.musicUrl!),
                    mode: LaunchMode.externalApplication,
                  );
                },
                icon: const Icon(
                  Icons.play_arrow_rounded,
                  size: 20,
                  color: Colors.white,
                ),
                label: Text(
                  LocaleService.current.openIn(
                    _sourceName ?? LocaleService.current.audioFile,
                  ),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: p,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Обложка + винил, выглядывающий из-за неё — та же деталь, что и на
  // экране создания музыкального пина.
  Widget _buildCover(Memory memory, Color p) {
    final hasCover =
        memory.musicCoverUrl != null && memory.musicCoverUrl!.isNotEmpty;
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: hasCover
          ? StorageImage(
              imageUrl: memory.musicCoverUrl!,
              width: 64,
              height: 64,
              fit: BoxFit.cover,
              errorWidget: (context, url, error) => _defaultMusicCover(p),
            )
          : _defaultMusicCover(p),
    );
    return SizedBox(
      width: 82,
      height: 64,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: 0,
            top: 4,
            child: CustomPaint(
              size: const Size(56, 56),
              painter: _MiniVinylPainter(labelColor: p),
            ),
          ),
          Positioned(
            left: 0,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: p.withValues(alpha: 0.22),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: cover,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceChip(Color p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: p.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq_rounded, size: 11, color: p),
          const SizedBox(width: 5),
          Text(
            _sourceName!,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: p,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayButton(Color p) {
    return GestureDetector(
      onTap: _loading
          ? null
          : () {
              if (_player == null ||
                  !_isPlaying && _position == Duration.zero) {
                _initAndPlay();
              } else if (_isPlaying) {
                _player?.pause();
              } else {
                _player?.play();
              }
            },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: p,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: p.withValues(alpha: 0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: _loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : Icon(
                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 24,
              ),
      ),
    );
  }

  Widget _defaultMusicCover(Color p) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p, Color.lerp(p, Colors.black, 0.28)!],
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Icon(
        Icons.music_note_rounded,
        color: Colors.white,
        size: 24,
      ),
    );
  }
}

// ── Mini vinyl disc — компактная версия винила с экрана создания ──────────────
class _MiniVinylPainter extends CustomPainter {
  final Color labelColor;
  const _MiniVinylPainter({required this.labelColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final body = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xFF2A2A2E), Color(0xFF111113)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, body);

    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withValues(alpha: 0.06);
    for (double r = radius * 0.45; r < radius - 1.5; r += 4) {
      canvas.drawCircle(center, r, groove);
    }

    final label = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          labelColor.withValues(alpha: 0.95),
          labelColor.withValues(alpha: 0.70),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius * 0.36));
    canvas.drawCircle(center, radius * 0.36, label);

    canvas.drawCircle(
      center,
      radius * 0.05,
      Paint()..color = const Color(0xFF111113),
    );
  }

  @override
  bool shouldRepaint(_MiniVinylPainter old) => old.labelColor != labelColor;
}

// ── Mini 3D book cover — компактная обложка для карточки в ленте ─────────────
/// Компактный постер фильма (соотношение ~2:3) с тенью и бликом — для карточек.
class _MiniMoviePoster extends StatelessWidget {
  final Color accent;
  final String? posterUrl;
  final String title;

  const _MiniMoviePoster({
    required this.accent,
    this.posterUrl,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    const w = 48.0;
    const h = 68.0;
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (posterUrl != null && posterUrl!.isNotEmpty)
            Image.network(
              posterUrl!,
              fit: BoxFit.cover,
              loadingBuilder: (ctx, child, progress) =>
                  progress == null ? child : _placeholder(),
              errorBuilder: (_, __, ___) => _placeholder(),
            )
          else
            _placeholder(),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.16),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.9),
            accent.withValues(alpha: 0.55),
          ],
        ),
      ),
      child: const Center(
        child: Icon(Icons.movie_rounded, color: Colors.white, size: 20),
      ),
    );
  }
}

class _MiniBookCover extends StatelessWidget {
  final Color accent;
  final String? coverUrl;
  final String title;
  final String author;

  const _MiniBookCover({
    required this.accent,
    this.coverUrl,
    required this.title,
    required this.author,
  });

  @override
  Widget build(BuildContext context) {
    // Соотношение сторон как у настоящей книги — ~0.7 (высота > ширины).
    const w = 48.0;
    const h = 68.0;
    return SizedBox(
      width: w + 4,
      height: h + 4,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Тень справа-снизу для имитации глубины
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 4,
              height: h,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.20),
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(2),
                  bottomRight: Radius.circular(2),
                ),
              ),
            ),
          ),
          // Сама обложка
          Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(3),
                bottomRight: Radius.circular(3),
                topLeft: Radius.circular(1.5),
                bottomLeft: Radius.circular(1.5),
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(3),
                bottomRight: Radius.circular(3),
                topLeft: Radius.circular(1.5),
                bottomLeft: Radius.circular(1.5),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (coverUrl != null && coverUrl!.isNotEmpty)
                    Image.network(
                      coverUrl!,
                      fit: BoxFit.cover,
                      loadingBuilder: (ctx, child, progress) =>
                          progress == null ? child : _placeholder(),
                      errorBuilder: (_, __, ___) => _placeholder(),
                    )
                  else
                    _placeholder(),
                  // Корешок слева — тёмная полоска
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 4,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.black.withValues(alpha: 0.30),
                            Colors.black.withValues(alpha: 0.05),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Глянцевый блик в верхнем-левом углу
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withValues(alpha: 0.18),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.45],
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

  Widget _placeholder() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.9),
            accent.withValues(alpha: 0.55),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(7, 8, 5, 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.menu_book_rounded, color: Colors.white, size: 12),
            const Spacer(),
            if (title.isNotEmpty)
              Text(
                title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 7,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              ),
            if (author.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 6,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  Music Mini Player — feed card with real playback
// ══════════════════════════════════════════════════════

class MemoryMusicPlayer extends StatefulWidget {
  final Memory memory;
  final AppTheme theme;
  final VoidCallback? onHeaderTap;

  /// true → рендерим ТОЛЬКО плеер (без собственной шапки) — для общей оболочки
  /// ленты, где шапку/подпись/футер рисует _musicTile. false (дефолт) → старый
  /// самодостаточный вид с шапкой (превью на главном).
  final bool bodyOnly;

  const MemoryMusicPlayer({
    super.key,
    required this.memory,
    required this.theme,
    this.onHeaderTap,
    this.bodyOnly = false,
  });

  @override
  State<MemoryMusicPlayer> createState() => _MemoryMusicPlayerState();
}

class _MemoryMusicPlayerState extends State<MemoryMusicPlayer> {
  AudioPlayer? _player;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _loading = false;
  bool _isExternalLink = false;

  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _stateSub;

  String? _sourceName;
  Color? _sourceColor;
  Color get primary => widget.theme.primary;
  Memory get memory => widget.memory;

  @override
  void initState() {
    super.initState();
    _detectSource();
  }

  @override
  void didUpdateWidget(MemoryMusicPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.memory.musicUrl != widget.memory.musicUrl) {
      _sourceName = null;
      _sourceColor = null;
      _isExternalLink = false;
      _detectSource();
    }
  }

  void _detectSource() {
    final url = memory.musicUrl;
    if (url == null || url.isEmpty) return;
    final lower = url.toLowerCase();

    if (lower.contains('spotify')) {
      _sourceName = 'Spotify';
      _sourceColor = const Color(0xFF1DB954);
      _isExternalLink = true;
    } else if (lower.contains('music.youtube.com')) {
      _sourceName = 'YouTube Music';
      _sourceColor = const Color(0xFFFF0000);
      _isExternalLink = true;
    } else if (lower.contains('youtube') || lower.contains('youtu.be')) {
      _sourceName = 'YouTube';
      _sourceColor = const Color(0xFFFF0000);
      _isExternalLink = true;
    } else if (lower.contains('music.apple.com')) {
      _sourceName = 'Apple Music';
      _sourceColor = const Color(0xFFFC3C44);
      _isExternalLink = true;
    } else if (lower.contains('deezer')) {
      // covers deezer.com, deezer.page.link, link.deezer.com
      _sourceName = 'Deezer';
      _sourceColor = const Color(0xFFA238FF);
      _isExternalLink = true;
    } else if (lower.contains('soundcloud')) {
      // covers soundcloud.com, on.soundcloud.com, soundcloud.app.goo.gl
      _sourceName = 'SoundCloud';
      _sourceColor = const Color(0xFFFF5500);
      _isExternalLink = true;
    } else if (lower.contains('music.yandex.') ||
        lower.contains('yandex.ru/music') ||
        lower.contains('music.yandex')) {
      _sourceName = 'Яндекс Музыка';
      _sourceColor = const Color(0xFFFFCC00);
      _isExternalLink = true;
    } else if (lower.contains('tidal.com')) {
      _sourceName = 'Tidal';
      _sourceColor = const Color(0xFF000000);
      _isExternalLink = true;
    } else if (lower.contains('vk.com/music') ||
        lower.contains('vk.com/audio') ||
        lower.contains('vk.ru/music')) {
      _sourceName = 'VK Музыка';
      _sourceColor = const Color(0xFF0077FF);
      _isExternalLink = true;
    } else if (lower.startsWith('http') &&
        !lower.contains('firebasestorage') &&
        !lower.contains('firebase')) {
      // Any other http link that's not firebase storage
      _sourceName = null;
      _isExternalLink = true;
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    final url = memory.musicUrl;
    if (url == null || url.isEmpty) return;

    if (_isExternalLink) {
      safeLaunchUrl(Uri.parse(url));
      return;
    }

    if (_isPlaying) {
      _player?.pause();
      return;
    }

    if (_player != null && _position > Duration.zero) {
      _player?.play();
      return;
    }

    if (!mounted) return;
    setState(() => _loading = true);
    try {
      _player ??= AudioPlayer();

      // Cancel any previous subscriptions before re-subscribing
      await _posSub?.cancel();
      await _durSub?.cancel();
      await _stateSub?.cancel();

      _posSub = _player!.positionStream.listen((pos) {
        if (mounted) setState(() => _position = pos);
      });
      _durSub = _player!.durationStream.listen((dur) {
        if (dur != null && mounted) setState(() => _duration = dur);
      });
      _stateSub = _player!.playerStateStream.listen((state) {
        if (mounted) {
          setState(() {
            _isPlaying = state.playing;
            if (state.processingState == ProcessingState.completed) {
              _isPlaying = false;
              _position = Duration.zero;
              _player?.seek(Duration.zero);
              _player?.pause();
            }
          });
        }
      });

      if (!mounted) return;
      await _setAudioSource(_player!, url);
      if (mounted) setState(() => _loading = false);
      await _player!.play();
    } catch (e) {
      debugPrint('Mini player error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString();
    final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$sec';
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

  @override
  Widget build(BuildContext context) {
    // bodyOnly → плеер без шапки (общую оболочку рисует _musicTile).
    if (widget.bodyOnly) return _buildPlayerBody();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header with streaming source (tap → open detail) ──
        GestureDetector(
          onTap: widget.onHeaderTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: primary.withOpacity(0.18),
                          width: 1.5,
                        ),
                      ),
                      child: AvatarWidget(
                        uid: memory.authorUid,
                        fallbackUrl: memory.authorAvatar,
                        name: memory.authorName,
                        size: 40,
                        primary: primary,
                      ),
                    ),
                    Positioned(
                      bottom: -2,
                      left: -2,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: primary, // Music type color is primary
                          shape: BoxShape.circle,
                          border: Border.all(color: widget.theme.cardSurface, width: 2),
                        ),
                        child: Center(
                          child: SvgPicture.asset(
                            _svgAssetForType(memory.type),
                            width: 10,
                            height: 10,
                            colorFilter: const ColorFilter.mode(
                              Colors.white,
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              memory.authorName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: widget.theme.textPrimary,
                              ),
                            ),
                          ),
                          if (_sourceName != null) ...[
                            Text(
                              ' via ',
                              style: TextStyle(
                                fontSize: 12,
                                color: widget.theme.textMuted,
                              ),
                            ),
                            Text(
                              _sourceName!,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: _sourceColor,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.verified_rounded,
                              size: 14,
                              color: _sourceColor,
                            ),
                          ],
                          Text(
                            '  ·  ${_timeAgo(memory.createdAt)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.theme.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 1),
                      Text(
                        [
                          if (memory.title?.isNotEmpty == true) memory.title!,
                          if (memory.caption?.isNotEmpty == true)
                            memory.caption!,
                        ].join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: primary),
                      ),
                    ],
                  ),
                ),
                if (memory.isPinned)
                  Icon(
                    Icons.push_pin_rounded,
                    size: 16,
                    color: primary.withOpacity(0.45),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _buildPlayerBody(),
        const SizedBox(height: 12),
      ],
    );
  }

  /// Тело плеера. Поглощает тапы, чтобы не открывать деталь по нажатию на
  /// элементы управления. Для файлов — богатый плеер, для ссылок — карточка.
  Widget _buildPlayerBody() {
    final hasUrl = memory.musicUrl != null && memory.musicUrl!.isNotEmpty;
    final isFile = hasUrl && !_isExternalLink;
    return GestureDetector(
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: isFile ? _buildFilePlayer() : _buildLinkCard(),
      ),
    );
  }

  /// Богатый плеер — ТОЛЬКО для музыкальных файлов (чтобы было видно, что трек
  /// проигрывается прямо здесь). Градиент от АКТИВНОЙ ТЕМЫ (не фиолетовый).
  Widget _buildFilePlayer() {
    final hasCover =
        memory.musicCoverUrl != null && memory.musicCoverUrl!.isNotEmpty;
    final dark = Color.lerp(primary, Colors.black, 0.32)!;
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [primary, dark],
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Обложка + эквалайзер-оверлей при проигрывании.
              SizedBox(
                width: 60,
                height: 60,
                child: Stack(
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: hasCover
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: StorageImage(
                                imageUrl: memory.musicCoverUrl!,
                                fit: BoxFit.cover,
                                memCacheWidth: 140,
                                memCacheHeight: 140,
                                errorWidget: (_, _, _) =>
                                    _coverNote(Colors.white),
                              ),
                            )
                          : _coverNote(Colors.white),
                    ),
                    Positioned.fill(
                      child: AnimatedOpacity(
                        opacity: _isPlaying ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 300),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            color: Colors.black.withOpacity(0.30),
                            child: Center(
                              child: _M3WaveBars(
                                isPlaying: _isPlaying,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      memory.musicTitle ?? LocaleService.current.unknownTrack,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    if (memory.musicArtist != null &&
                        memory.musicArtist!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        memory.musicArtist!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withOpacity(0.85),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Большая кнопка play/pause.
              GestureDetector(
                onTap: _togglePlayback,
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: _loading
                      ? Padding(
                          padding: const EdgeInsets.all(14),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.6,
                            color: primary,
                          ),
                        )
                      : Icon(
                          _isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: primary,
                          size: 30,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          WaveProgressBar(
            value: progress,
            color: Colors.white,
            isPlaying: _isPlaying,
            height: 24,
            onChanged: _duration > Duration.zero
                ? (v) => _player?.seek(
                      Duration(
                        milliseconds: (v * _duration.inMilliseconds).toInt(),
                      ),
                    )
                : null,
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _fmt(_position),
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withOpacity(0.75),
                ),
              ),
              Text(
                _duration > Duration.zero ? _fmt(_duration) : '--:--',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withOpacity(0.75),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Карточка-ссылка для стриминговых сервисов: обложка + название + артист и
  /// кнопка «Открыть в …» в фирменном цвете сервиса (кнопки оставлены).
  Widget _buildLinkCard() {
    final hasCover =
        memory.musicCoverUrl != null && memory.musicCoverUrl!.isNotEmpty;
    final hasUrl = memory.musicUrl != null && memory.musicUrl!.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.theme.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: widget.theme.divider, width: 1),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: hasCover
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: StorageImage(
                          imageUrl: memory.musicCoverUrl!,
                          fit: BoxFit.cover,
                          memCacheWidth: 96,
                          memCacheHeight: 96,
                          errorWidget: (_, _, _) => _coverNote(primary),
                        ),
                      )
                    : _coverNote(primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      memory.musicTitle ?? LocaleService.current.unknownTrack,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: widget.theme.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (memory.musicArtist != null &&
                        memory.musicArtist!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          memory.musicArtist!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: primary),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (hasUrl) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _togglePlayback,
                icon: const Icon(
                  Icons.open_in_new_rounded,
                  size: 15,
                  color: Colors.white,
                ),
                label: Text(
                  LocaleService.current.openIn(
                    _sourceName ?? LocaleService.current.audioFile,
                  ),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _sourceColor ?? primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  elevation: 0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _coverNote(Color color) {
    return Center(
      child: SvgPicture.asset(
        'assets/icons/ic_music_note.svg',
        width: 22,
        height: 22,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════
//  Memory Detail Sheet Widget
//  Extracted StatefulWidget — keyboard animation only
//  rebuilds this isolated subtree, not the whole page.
// ══════════════════════════════════════════════════════

