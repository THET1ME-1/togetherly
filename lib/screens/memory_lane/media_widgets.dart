part of '../memory_lane_screen.dart';

// ─── Spoiler rich text for detail view ───────────────────────────────────────

class _SpoilerRichText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;
  const _SpoilerRichText({
    required this.text,
    required this.style,
    this.maxLines,
    this.overflow,
  });
  @override
  State<_SpoilerRichText> createState() => _SpoilerRichTextState();
}

class _SpoilerRichTextState extends State<_SpoilerRichText> {
  final Set<int> _revealed = {};

  List<({String text, bool isSpoiler})> _parse() {
    final result = <({String text, bool isSpoiler})>[];
    final parts = widget.text.split('||');
    for (int i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      result.add((text: parts[i], isSpoiler: i.isOdd));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final segments = _parse();
    if (!segments.any((s) => s.isSpoiler)) {
      return Text(
        widget.text,
        style: widget.style,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
      );
    }
    int spoilerIndex = 0;
    return Text.rich(
      TextSpan(
        children: segments.map((seg) {
          if (!seg.isSpoiler)
            return TextSpan(text: seg.text, style: widget.style);
          final idx = spoilerIndex++;
          final isRevealed = _revealed.contains(idx);
          return WidgetSpan(
            alignment: ui.PlaceholderAlignment.middle,
            child: GestureDetector(
              onTap: isRevealed
                  ? null
                  : () => setState(() => _revealed.add(idx)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: BoxDecoration(
                  color: isRevealed ? Colors.transparent : Colors.grey.shade800,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  seg.text,
                  style: widget.style.copyWith(
                    color: isRevealed
                        ? widget.style.color
                        : Colors.grey.shade800,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  WaveProgressBar — Material You animated wave progress bar for music player
//  Active portion: animated sine wave. Inactive portion: flat line.
// ──────────────────────────────────────────────────────────────────────────────

class WaveProgressBar extends StatefulWidget {
  /// Progress from 0.0 to 1.0
  final double value;
  final Color color;

  /// Controls wave animation: starts/stops based on playback state
  final bool isPlaying;

  /// Called with new value (0.0–1.0) when user seeks
  final ValueChanged<double>? onChanged;

  final double height;

  const WaveProgressBar({
    super.key,
    required this.value,
    required this.color,
    this.isPlaying = false,
    this.onChanged,
    this.height = 28,
  });

  @override
  State<WaveProgressBar> createState() => _WaveProgressBarState();
}

class _WaveProgressBarState extends State<WaveProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    if (widget.isPlaying) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(WaveProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.isPlaying && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          // translucent so this widget doesn't swallow system-gesture events
          // (Android back/home swipes) that happen to start within its bounds.
          behavior: HitTestBehavior.translucent,
          onTapUp: (d) {
            if (widget.onChanged == null) return;
            final r = (d.localPosition.dx / constraints.maxWidth).clamp(
              0.0,
              1.0,
            );
            widget.onChanged!(r);
          },
          onHorizontalDragUpdate: (d) {
            if (widget.onChanged == null) return;
            final r = (d.localPosition.dx / constraints.maxWidth).clamp(
              0.0,
              1.0,
            );
            widget.onChanged!(r);
          },
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => CustomPaint(
                painter: _WaveProgressPainter(
                  value: widget.value,
                  color: widget.color,
                  phase: _ctrl.value * 2 * pi,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveProgressPainter extends CustomPainter {
  final double value; // 0.0 – 1.0
  final Color color;
  final double phase;

  static const double _amplitude = 2.0;
  static const int _wavesVisible = 2;

  const _WaveProgressPainter({
    required this.value,
    required this.color,
    required this.phase,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final activeWidth = (size.width * value).clamp(0.0, size.width);
    const strokeWidth = 2.5;

    final activePaint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final inactivePaint = Paint()
      ..color = color.withOpacity(0.22)
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Inactive flat line from activeWidth to end
    if (activeWidth < size.width) {
      canvas.drawLine(
        Offset(activeWidth, cy),
        Offset(size.width, cy),
        inactivePaint,
      );
    }

    // Active wavy line from 0 to activeWidth
    if (activeWidth > 1) {
      final wavelength = size.width / _wavesVisible;
      final path = Path();
      const steps = 200;
      for (int i = 0; i <= steps; i++) {
        final t = i / steps;
        final x = activeWidth * t;
        final y = cy + _amplitude * sin((x / wavelength) * 2 * pi - phase);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, activePaint);
    }

    // Thumb circle at current position
    if (value > 0.005 && value < 0.995) {
      final thumbPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(activeWidth, cy), 5.5, thumbPaint);
    }
  }

  @override
  bool shouldRepaint(_WaveProgressPainter old) =>
      old.value != value || old.phase != phase || old.color != color;
}

// ──────────────────────────────────────────────────────────────────────────────
//  _M3WaveBars — M3 Expressive animated equalizer bars (now-playing indicator)
//  4 vertical rounded bars that bounce with wave-like offset phases, giving a
//  fluid, spring-like feel characteristic of Material 3 Expressive motion.
// ──────────────────────────────────────────────────────────────────────────────

class _M3WaveBars extends StatefulWidget {
  final bool isPlaying;
  final Color color;

  const _M3WaveBars({required this.isPlaying, required this.color});

  @override
  State<_M3WaveBars> createState() => _M3WaveBarsState();
}

class _M3WaveBarsState extends State<_M3WaveBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    if (widget.isPlaying) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(_M3WaveBars old) {
    super.didUpdateWidget(old);
    if (widget.isPlaying && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.isPlaying && _ctrl.isAnimating) {
      _ctrl.animateTo(
        0.5,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        size: const Size(28, 18),
        painter: _WaveBarsPainter(
          phase: _ctrl.value * 2 * pi,
          color: widget.color,
          isPlaying: widget.isPlaying,
        ),
      ),
    );
  }
}

/// Inline YouTube player card — shows thumbnail initially,
/// then plays the video inline when the user taps the play button.
class _YouTubeInlineCard extends StatefulWidget {
  final Memory memory;
  final Color platformColor;
  final String platformName;
  final String pairId;
  final String partnerUid;

  const _YouTubeInlineCard({
    required this.memory,
    required this.platformColor,
    required this.platformName,
    required this.pairId,
    required this.partnerUid,
  });

  @override
  State<_YouTubeInlineCard> createState() => _YouTubeInlineCardState();
}

class _YouTubeInlineCardState extends State<_YouTubeInlineCard> {
  YoutubePlayerController? _controller;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    // Предзагрузка rewarded к моменту тапа «Смотреть вместе» (если есть пара).
    if (widget.pairId.isNotEmpty) {
      TogetherLauncher.preloadStartAd();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _startInlinePlay() {
    final videoId = YoutubePlayer.convertUrlToId(widget.memory.videoUrl ?? '');
    if (videoId == null) {
      final url = widget.memory.videoUrl;
      if (url != null && url.isNotEmpty) {
        safeLaunchUrl(Uri.parse(url));
      }
      return;
    }
    setState(() {
      _controller = YoutubePlayerController(
        initialVideoId: videoId,
        flags: const YoutubePlayerFlags(
          autoPlay: true,
          enableCaption: false,
          hideControls: false,
        ),
      );
      _isPlaying = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final memory = widget.memory;
    final platformColor = widget.platformColor;
    final platformName = widget.platformName;
    // Превью: сохранённая обложка, иначе — стандартная миниатюра YouTube,
    // выведенная прямо из videoId. oEmbed на шеринге мог не отдать обложку
    // (регион/сеть) → imageUrl пуст, и раньше показывался только красный
    // градиент. i.ytimg.com/vi/<id>/hqdefault.jpg доступен без API-ключа;
    // BoxFit.cover аккуратно обрезает 4:3 до 16:9. Чинит и старые воспоминания.
    final videoId = YoutubePlayer.convertUrlToId(memory.videoUrl ?? '');
    final thumbUrl = memory.imageUrl?.isNotEmpty == true
        ? memory.imageUrl!
        : (videoId != null
            ? 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg'
            : null);
    final hasThumb = thumbUrl != null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.appTheme.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appTheme.divider, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Inline player or thumbnail preview ──
          if (_isPlaying && _controller != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: YoutubePlayer(
                controller: _controller!,
                showVideoProgressIndicator: true,
                progressIndicatorColor: platformColor,
                progressColors: ProgressBarColors(
                  playedColor: platformColor,
                  handleColor: platformColor,
                ),
              ),
            )
          else
            GestureDetector(
              onTap: _startInlinePlay,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasThumb)
                        StorageImage(
                          imageUrl: thumbUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  platformColor.withValues(alpha: 0.85),
                                  platformColor.withValues(alpha: 0.55),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                            ),
                          ),
                        )
                      else
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                platformColor.withValues(alpha: 0.85),
                                platformColor.withValues(alpha: 0.55),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                        ),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.4),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                      Center(
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.95),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.25),
                                blurRadius: 12,
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: 34,
                            color: platformColor,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: platformColor,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.smart_display_rounded,
                                size: 10,
                                color: Colors.white,
                              ),
                              SizedBox(width: 3),
                              Text(
                                'YouTube',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
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
          const SizedBox(height: 10),
          // ── Title ──
          Text(
            memory.title?.isNotEmpty == true
                ? memory.title!
                : LocaleService.current.video,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: context.appTheme.textPrimary,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (memory.musicArtist?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                memory.musicArtist!,
                style: TextStyle(fontSize: 11, color: context.appTheme.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (memory.caption?.isNotEmpty == true) ...[
            const SizedBox(height: 6),
            Text(
              memory.caption!,
              style: TextStyle(
                fontSize: 12,
                color: context.appTheme.textSecondary,
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
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
                size: 14,
                color: Colors.white,
              ),
              label: Text(
                LocaleService.current.openIn(platformName),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: platformColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
                elevation: 0,
              ),
            ),
          ),
          // ── Смотреть вместе (совместный просмотр через RTDB, 0 чтений) ──
          if (widget.pairId.isNotEmpty &&
              (memory.videoUrl?.isNotEmpty == true))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => TogetherLauncher.hostVideo(
                    context,
                    pairId: widget.pairId,
                    partnerUid: widget.partnerUid,
                    videoUrl: memory.videoUrl!,
                  ),
                  icon: Icon(Icons.people_alt_rounded,
                      size: 16, color: platformColor),
                  label: Text(
                    LocaleService.current.watchTogether,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: platformColor,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: platformColor),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WaveBarsPainter extends CustomPainter {
  final double phase;
  final Color color;
  final bool isPlaying;

  // Quarter-period offsets → adjacent bars peak at different times (wave effect)
  static const List<double> _phaseOffsets = [0.0, pi * 0.5, pi * 1.0, pi * 1.5];

  // Slightly different frequencies per bar for organic, non-robotic feel
  static const List<double> _freqs = [1.0, 1.25, 0.85, 1.15];

  const _WaveBarsPainter({
    required this.phase,
    required this.color,
    required this.isPlaying,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const barCount = 4;
    const gap = 3.0;
    final barW = (size.width - gap * (barCount - 1)) / barCount;
    final maxH = size.height;
    const minH = 3.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    for (int i = 0; i < barCount; i++) {
      double h;
      if (isPlaying) {
        // Primary wave + subtle harmonic for spring-like feel
        final t1 = sin(phase * _freqs[i] + _phaseOffsets[i]);
        final t2 = sin(phase * _freqs[i] * 1.8 + _phaseOffsets[i] * 0.4) * 0.25;
        final combined = ((t1 + t2) / 1.25).clamp(-1.0, 1.0);
        h = (minH + (maxH - minH) * (combined * 0.5 + 0.5)).clamp(minH, maxH);
      } else {
        h = minH;
      }
      final x = i * (barW + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, barW, h),
          const Radius.circular(2.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveBarsPainter old) =>
      old.phase != phase || old.color != color || old.isPlaying != isPlaying;
}

// ─────────────────────────────────────────────────────────────
// In-app video player for uploaded video memories
// ─────────────────────────────────────────────────────────────

class _InAppVideoPlayerPage extends StatefulWidget {
  final String url;
  final String? title;

  const _InAppVideoPlayerPage({required this.url, this.title});

  @override
  State<_InAppVideoPlayerPage> createState() => _InAppVideoPlayerPageState();
}

class _InAppVideoPlayerPageState extends State<_InAppVideoPlayerPage> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _hasError = false;
  bool _showControls = true;
  Timer? _hideTimer;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// Резолвим sb://gs:// в проигрываемый signed URL ПЕРЕД созданием контроллера —
  /// иначе VideoPlayerController.networkUrl получает сырой sb://gs:// и не
  /// запускается (видео отображалось как фото-превью без воспроизведения).
  /// resolveMediaUrl покрывает обе схемы (sb:// и gs://); если signed URL получить
  /// не удалось, вернётся исходный url и initialize() бросит → ловим в catch.
  Future<void> _init() async {
    final playable = await PbMediaService().resolvePlayable(widget.url);
    if (!mounted) return;
    final controller = VideoPlayerController.networkUrl(Uri.parse(playable));
    _controller = controller;
    controller.addListener(_onUpdate);
    try {
      await controller.initialize();
    } catch (e) {
      debugPrint('_InAppVideoPlayerPage: init failed for $playable: $e');
      if (mounted) setState(() => _hasError = true);
      return;
    }
    if (!mounted) return;
    setState(() {
      _isInitialized = true;
      _duration = controller.value.duration;
    });
    controller.play();
    _scheduleHide();
  }

  void _onUpdate() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    setState(() {
      _position = controller.value.position;
    });
    // Natural end: reveal controls but DON'T yank the position back to 0 — that
    // fought the seek bar (thumb snapped to the start) and hid where playback
    // ended. Restart-from-0 happens on the next play press (_togglePlay).
    final v = controller.value;
    if (v.duration > Duration.zero &&
        v.position >= v.duration &&
        !v.isPlaying) {
      _hideTimer?.cancel();
      if (!_showControls) setState(() => _showControls = true);
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls && (_controller?.value.isPlaying ?? false)) {
      _scheduleHide();
    }
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
      _hideTimer?.cancel();
      setState(() => _showControls = true);
    } else {
      // Restart from the beginning if playback had reached the end.
      if (controller.value.duration > Duration.zero &&
          controller.value.position >= controller.value.duration) {
        controller.seekTo(Duration.zero);
      }
      controller.play();
      _scheduleHide();
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_onUpdate);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final isPlaying = controller?.value.isPlaying ?? false;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          onTap: _toggleControls,
          behavior: HitTestBehavior.opaque,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ── Video ──
              Center(
                child: _hasError
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: Colors.white70,
                              size: 48,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              LocaleService.current.downloadFailed('video'),
                              style: const TextStyle(color: Colors.white70),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    : (_isInitialized && controller != null)
                        ? AspectRatio(
                            aspectRatio: controller.value.aspectRatio,
                            child: VideoPlayer(controller),
                          )
                        : const CircularProgressIndicator(
                            color: Colors.white,
                          ),
              ),

              // ── Controls overlay ──
              AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Stack(
                  children: [
                    // Top bar
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(4, 8, 16, 24),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withOpacity(0.7),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.arrow_back_rounded,
                                color: Colors.white,
                              ),
                              onPressed: () => Navigator.pop(context),
                            ),
                            if (widget.title != null) ...[
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  widget.title!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    // Centre play/pause button
                    Center(
                      child: GestureDetector(
                        onTap: _togglePlay,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 150),
                          child: Container(
                            key: ValueKey(isPlaying),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.5),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 48,
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Bottom bar with progress + time
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withOpacity(0.75),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (controller != null && _isInitialized)
                              _VideoSeekBar(
                                controller: controller,
                                color: const Color(0xFFEC4899),
                              ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Text(
                                  _fmt(_position),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  _fmt(_duration),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Seek bar for [_InAppVideoPlayerPage]. Unlike the stock
/// [VideoProgressIndicator], it holds a local drag fraction while the user
/// scrubs and paints the thumb from it — so the thumb follows the finger
/// instead of snapping back to the player's not-yet-updated position between
/// drag events (async seek lag = the visible jitter). Control is handed back to
/// the controller once its reported position catches up to the seek target.
class _VideoSeekBar extends StatefulWidget {
  final VideoPlayerController controller;
  final Color color;

  const _VideoSeekBar({required this.controller, required this.color});

  @override
  State<_VideoSeekBar> createState() => _VideoSeekBarState();
}

class _VideoSeekBarState extends State<_VideoSeekBar> {
  // 0..1 while scrubbing; null = follow the controller's reported position.
  // The parent player rebuilds this widget on every controller tick, so no
  // separate listener is needed here.
  double? _dragValue;

  void _seek(double fraction) {
    final dur = widget.controller.value.duration;
    if (dur <= Duration.zero) return;
    final frac = fraction.clamp(0.0, 1.0);
    setState(() => _dragValue = frac);
    widget.controller.seekTo(dur * frac);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.controller.value;
    final durMs = v.duration.inMilliseconds;
    final played =
        durMs > 0 ? (v.position.inMilliseconds / durMs).clamp(0.0, 1.0) : 0.0;
    // Player caught up to where we dragged → drop the override (the next
    // controller-driven rebuild resumes painting the live position smoothly).
    if (_dragValue != null && (played - _dragValue!).abs() < 0.02) {
      _dragValue = null;
    }
    final value = _dragValue ?? played;
    final buffered = (durMs > 0 && v.buffered.isNotEmpty)
        ? (v.buffered.last.end.inMilliseconds / durMs).clamp(0.0, 1.0)
        : 0.0;
    return LayoutBuilder(
      builder: (context, c) => GestureDetector(
        // translucent so the bar doesn't swallow system-gesture edge swipes.
        behavior: HitTestBehavior.translucent,
        onTapDown: (d) => _seek(d.localPosition.dx / c.maxWidth),
        onHorizontalDragUpdate: (d) => _seek(d.localPosition.dx / c.maxWidth),
        child: SizedBox(
          height: 24,
          width: double.infinity,
          child: CustomPaint(
            painter: _VideoSeekBarPainter(
              played: value,
              buffered: buffered,
              playedColor: widget.color,
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoSeekBarPainter extends CustomPainter {
  final double played; // 0..1
  final double buffered; // 0..1
  final Color playedColor;

  const _VideoSeekBarPainter({
    required this.played,
    required this.buffered,
    required this.playedColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    const trackH = 3.0;
    void bar(double frac, Color color) {
      if (frac <= 0) return;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(0, cy - trackH / 2, size.width * frac, cy + trackH / 2),
          const Radius.circular(2),
        ),
        Paint()..color = color,
      );
    }

    bar(1.0, Colors.white24); // background track
    bar(buffered, Colors.white38); // buffered
    bar(played, playedColor); // played
    // Thumb at the current (or dragged) position.
    canvas.drawCircle(
      Offset(size.width * played.clamp(0.0, 1.0), cy),
      6,
      Paint()..color = playedColor,
    );
  }

  @override
  bool shouldRepaint(_VideoSeekBarPainter old) =>
      old.played != played ||
      old.buffered != buffered ||
      old.playedColor != playedColor;
}
