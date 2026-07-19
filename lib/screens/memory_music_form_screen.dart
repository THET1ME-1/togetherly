import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../widgets/memory_date_field.dart';

/// Получает метаданные трека по ссылке: {title, artist, cover}.
typedef MusicMetaFetcher = Future<Map<String, String?>> Function(String url);

/// Сохранение музыкального воспоминания.
typedef MemoryMusicSaveCallback = Future<void> Function({
  required String musicTitle,
  required String musicArtist,
  required String musicUrl,
  String? musicCoverUrl,
  String? musicPath,
  String caption,
  DateTime? customDate,
});

/// Описание стримингового сервиса для бейджа платформы.
class _MusicService {
  final String name;
  final Color color;
  final IconData icon;
  const _MusicService(this.name, this.color, this.icon);

  /// Распознаёт сервис по ссылке (зеркало MemoryMusicPlayer._detectSource).
  static _MusicService? detect(String url) {
    final lower = url.toLowerCase();
    if (lower.isEmpty || !lower.startsWith('http')) return null;
    if (lower.contains('spotify')) {
      return const _MusicService('Spotify', Color(0xFF1DB954), Icons.music_note_rounded);
    }
    if (lower.contains('music.youtube.com')) {
      return const _MusicService('YouTube Music', Color(0xFFFF0000), Icons.play_circle_rounded);
    }
    if (lower.contains('youtube') || lower.contains('youtu.be')) {
      return const _MusicService('YouTube', Color(0xFFFF0000), Icons.smart_display_rounded);
    }
    if (lower.contains('music.apple.com')) {
      return const _MusicService('Apple Music', Color(0xFFFC3C44), Icons.apple_rounded);
    }
    if (lower.contains('deezer')) {
      return const _MusicService('Deezer', Color(0xFFA238FF), Icons.album_rounded);
    }
    if (lower.contains('soundcloud')) {
      return const _MusicService('SoundCloud', Color(0xFFFF5500), Icons.cloud_rounded);
    }
    if (lower.contains('yandex') && lower.contains('music')) {
      return const _MusicService('Яндекс Музыка', Color(0xFFFFCC00), Icons.library_music_rounded);
    }
    if (lower.contains('tidal.com')) {
      return const _MusicService('Tidal', Color(0xFF101010), Icons.waves_rounded);
    }
    return null;
  }
}

/// Полноэкранная форма создания музыкального воспоминания.
///
/// Живое «now playing» превью: обложка, название и исполнитель появляются
/// сразу после вставки ссылки (авто-подгрузка) или выбора аудиофайла.
class MemoryMusicFormScreen extends StatefulWidget {
  final AppTheme theme;
  final MusicMetaFetcher onFetchMeta;
  final MemoryMusicSaveCallback onSave;

  const MemoryMusicFormScreen({
    super.key,
    required this.theme,
    required this.onFetchMeta,
    required this.onSave,
  });

  @override
  State<MemoryMusicFormScreen> createState() => _MemoryMusicFormScreenState();
}

class _MemoryMusicFormScreenState extends State<MemoryMusicFormScreen>
    with SingleTickerProviderStateMixin {
  final _titleCtrl = TextEditingController();
  final _artistCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _captionCtrl = TextEditingController();

  String? _coverUrl;
  String? _musicPath;
  String? _musicFileName;

  bool _isFetching = false;
  bool _isSaving = false;
  String? _lastFetchedUrl;
  Timer? _debounce;
  DateTime? _customDate;

  late final AnimationController _spin;

  Color get _primary => widget.theme.primary;

  bool get _hasTrack =>
      _coverUrl != null ||
      _titleCtrl.text.trim().isNotEmpty ||
      _musicPath != null;

  bool get _canSave =>
      !_isSaving &&
      (_titleCtrl.text.trim().isNotEmpty ||
          _urlCtrl.text.trim().isNotEmpty ||
          _musicPath != null);

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _spin.dispose();
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _urlCtrl.dispose();
    _captionCtrl.dispose();
    super.dispose();
  }

  // ── Fetch metadata ──────────────────────────────────────────────────────────

  void _onUrlChanged(String value) {
    setState(() {}); // обновить canSave / бейдж платформы
    final url = value.trim();
    _debounce?.cancel();
    if (!url.startsWith('http') || !url.contains('.')) return;
    // Авто-подгрузка с дебаунсом — «магия» при вставке ссылки.
    _debounce = Timer(const Duration(milliseconds: 700), () {
      if (url != _lastFetchedUrl) _fetchMeta(url);
    });
  }

  Future<void> _fetchMeta(String rawUrl) async {
    final url = rawUrl.trim();
    if (url.isEmpty || _isFetching) return;
    FocusScope.of(context).unfocus();
    setState(() => _isFetching = true);
    _lastFetchedUrl = url;
    try {
      final meta = await widget.onFetchMeta(url);
      if (!mounted) return;
      setState(() {
        final t = meta['title'];
        final a = meta['artist'];
        final c = meta['cover'];
        if (t != null && t.isNotEmpty) _titleCtrl.text = t;
        if (a != null && a.isNotEmpty) _artistCtrl.text = a;
        if (c != null && c.isNotEmpty) _coverUrl = c;
      });
      if (mounted &&
          (meta['title']?.isEmpty ?? true) &&
          (meta['cover']?.isEmpty ?? true)) {
        _snack(LocaleService.current.autoFetchSongInfo);
      }
    } catch (_) {
      // тихо — пользователь может заполнить вручную
    } finally {
      if (mounted) setState(() => _isFetching = false);
    }
  }

  Future<void> _pickAudioFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.audio);
      if (result == null || result.files.isEmpty) return;
      final f = result.files.first;
      if (!mounted) return;
      setState(() {
        _musicPath = f.path;
        _musicFileName = f.name;
        if (_titleCtrl.text.trim().isEmpty) {
          _titleCtrl.text = f.name.split('.').first;
        }
      });
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _isSaving = true);
    Navigator.pop(context);
    await widget.onSave(
      musicTitle: _titleCtrl.text.trim(),
      musicArtist: _artistCtrl.text.trim(),
      musicUrl: _urlCtrl.text.trim(),
      musicCoverUrl: _coverUrl,
      musicPath: _musicPath,
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

  // ── Build ─────────────────────────────────────────────────────────────────--

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
            _buildHero(s),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildLinkCard(s),
                  const SizedBox(height: 16),
                  _buildDetailsCard(s),
                  const SizedBox(height: 16),
                  _buildCaptionField(s),
                  const SizedBox(height: 16),
                  MemoryDateField(
                    value: _customDate,
                    onChanged: (d) => setState(() => _customDate = d),
                    accent: _primary,
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
        s.music,
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

  // ── Hero «now playing» ────────────────────────────────────────────────────--

  Widget _buildHero(AppStrings s) {
    final service = _MusicService.detect(_urlCtrl.text);
    final accent = service?.color ?? _primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: 0.10),
            accent.withValues(alpha: 0.02),
            widget.theme.cardSurface,
          ],
        ),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 200,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // ── Винил, выезжающий из-за обложки ──
                AnimatedBuilder(
                  animation: _spin,
                  builder: (_, child) => Transform.rotate(
                    angle: _hasTrack ? _spin.value * 2 * math.pi : 0,
                    child: child,
                  ),
                  child: Transform.translate(
                    offset: const Offset(64, 0),
                    child: CustomPaint(
                      size: const Size(176, 176),
                      painter: _VinylPainter(labelColor: accent),
                    ),
                  ),
                ),
                // ── Квадратная обложка ──
                Transform.translate(
                  offset: const Offset(-28, 0),
                  child: _buildCover(accent),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // ── Платформа / источник ──
          if (service != null) ...[
            _platformChip(service),
            const SizedBox(height: 10),
          ],
          // ── Название ──
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(
              _titleCtrl.text.trim().isNotEmpty
                  ? _titleCtrl.text.trim()
                  : s.songName,
              key: ValueKey(_titleCtrl.text.trim()),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.15,
                color: _titleCtrl.text.trim().isNotEmpty
                    ? widget.theme.textPrimary
                    : widget.theme.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 4),
          // ── Исполнитель ──
          if (_artistCtrl.text.trim().isNotEmpty)
            Text(
              _artistCtrl.text.trim(),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCover(Color accent) {
    return Container(
      width: 150,
      height: 150,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.30),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_coverUrl != null)
              Image.network(
                _coverUrl!,
                fit: BoxFit.cover,
                loadingBuilder: (ctx, child, progress) =>
                    progress == null ? child : _coverPlaceholder(accent),
                errorBuilder: (ctx, err, stack) => _coverPlaceholder(accent),
              )
            else
              _coverPlaceholder(accent),
            // Лёгкий блик сверху для «глянца» обложки
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
            if (_isFetching)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder(Color accent) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.85),
            accent.withValues(alpha: 0.55),
          ],
        ),
      ),
      child: const Center(
        child: Icon(Icons.music_note_rounded, color: Colors.white, size: 48),
      ),
    );
  }

  Widget _platformChip(_MusicService service) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: service.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(service.icon, size: 15, color: service.color),
          const SizedBox(width: 6),
          Text(
            service.name,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: service.color,
            ),
          ),
        ],
      ),
    );
  }

  // ── Link card ─────────────────────────────────────────────────────────────--

  Widget _buildLinkCard(AppStrings s) {
    final hasCover = _coverUrl != null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.theme.surfaceMuted,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: widget.theme.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF22C55E).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.link_rounded,
                    size: 16, color: Color(0xFF22C55E)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.streamingLink,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: widget.theme.textPrimary,
                  ),
                ),
              ),
              if (hasCover)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          size: 12, color: Color(0xFF22C55E)),
                      const SizedBox(width: 4),
                      Text(
                        s.fetched,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF22C55E),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _urlCtrl,
            style: const TextStyle(fontSize: 14),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.search,
            onChanged: _onUrlChanged,
            onSubmitted: _fetchMeta,
            decoration: InputDecoration(
              hintText: s.pasteLinkFromService,
              hintStyle:
                  TextStyle(color: widget.theme.textMuted, fontSize: 13),
              prefixIcon: Icon(Icons.link_rounded, color: _primary, size: 20),
              suffixIcon: _isFetching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.grey),
                      ),
                    )
                  : IconButton(
                      icon: Icon(Icons.manage_search_rounded, color: _primary),
                      tooltip: s.autoFetchSongInfo,
                      onPressed: () => _fetchMeta(_urlCtrl.text),
                    ),
              filled: true,
              fillColor: widget.theme.cardSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: _primary, width: 1.5),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
          const SizedBox(height: 12),
          _orDivider(s),
          const SizedBox(height: 12),
          _buildFilePicker(s),
        ],
      ),
    );
  }

  Widget _orDivider(AppStrings s) {
    return Row(
      children: [
        Expanded(child: Divider(color: widget.theme.divider, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            s.orDivider,
            style: TextStyle(
              fontSize: 11,
              color: widget.theme.textMuted,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(child: Divider(color: widget.theme.divider, height: 1)),
      ],
    );
  }

  Widget _buildFilePicker(AppStrings s) {
    final selected = _musicPath != null;
    final color = selected ? const Color(0xFF22C55E) : _primary;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _pickAudioFile,
        icon: Icon(
          selected ? Icons.check_circle_rounded : Icons.upload_file_rounded,
          size: 18,
        ),
        label: Text(
          selected
              ? (_musicFileName ?? '${s.fileSelected} ✓')
              : s.pickAudioFromDevice,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  // ── Details card (title + artist) ─────────────────────────────────────────--

  Widget _buildDetailsCard(AppStrings s) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _primary.withValues(alpha: 0.04),
            const Color(0xFFEC4899).withValues(alpha: 0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _primary.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child:
                    Icon(Icons.music_note_rounded, size: 16, color: _primary),
              ),
              const SizedBox(width: 10),
              Text(
                s.songDetails,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: widget.theme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _fieldFor(
            controller: _titleCtrl,
            hint: s.songName,
            icon: Icons.audiotrack_rounded,
          ),
          const SizedBox(height: 10),
          _fieldFor(
            controller: _artistCtrl,
            hint: s.artistsCommaSeparated,
            helper: s.egArtists,
            icon: Icons.person_rounded,
          ),
        ],
      ),
    );
  }

  Widget _fieldFor({
    required TextEditingController controller,
    required String hint,
    String? helper,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 15),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: hint,
        helperText: helper,
        helperStyle: TextStyle(fontSize: 11, color: widget.theme.textMuted),
        hintStyle: TextStyle(color: widget.theme.textMuted),
        prefixIcon: Icon(icon, color: _primary, size: 20),
        filled: true,
        fillColor: widget.theme.cardSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: _primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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

// ── Vinyl record painter ──────────────────────────────────────────────────────

class _VinylPainter extends CustomPainter {
  final Color labelColor;
  const _VinylPainter({required this.labelColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Тело пластинки
    final body = Paint()
      ..shader = RadialGradient(
        colors: [const Color(0xFF2A2A2E), const Color(0xFF111113)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, body);

    // Концентрические бороздки
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.05);
    for (double r = radius * 0.42; r < radius - 2; r += 5) {
      canvas.drawCircle(center, r, groove);
    }

    // Цветная центральная наклейка
    final label = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          labelColor.withValues(alpha: 0.95),
          labelColor.withValues(alpha: 0.7),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius * 0.34));
    canvas.drawCircle(center, radius * 0.34, label);

    // Блик на наклейке
    canvas.drawCircle(
      center.translate(-radius * 0.1, -radius * 0.1),
      radius * 0.1,
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );

    // Центральное отверстие
    canvas.drawCircle(
      center,
      radius * 0.045,
      Paint()..color = const Color(0xFF111113),
    );
  }

  @override
  bool shouldRepaint(_VinylPainter old) => old.labelColor != labelColor;
}
