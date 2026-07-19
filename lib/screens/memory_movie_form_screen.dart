import 'dart:async';

import 'package:flutter/material.dart';

import '../services/locale_service.dart';
import '../services/movie_search_service.dart';
import '../theme/app_theme.dart';
import '../widgets/memory_date_field.dart';
import '../widgets/rating_widgets.dart';

/// Сохранение воспоминания-фильма/сериала.
typedef MemoryMovieSaveCallback = Future<void> Function({
  required String movieTitle,
  String? movieOriginalTitle,
  String? moviePosterUrl,
  String? movieYear,
  String? movieKind,
  String? movieGenres,
  String? movieCountry,
  String? movieRatingKp,
  String? movieInfoUrl,
  int? rating,
  required String caption,
  DateTime? customDate,
});

/// Полноэкранная форма «Фильмы и сериалы».
///
/// По аналогии с книжной формой: поиск по бесплатному API kinopoisk.dev
/// (русские и английские названия), выбор из списка, стильное превью постера,
/// личная оценка 1–10 и отзыв.
class MemoryMovieFormScreen extends StatefulWidget {
  final AppTheme theme;
  final MemoryMovieSaveCallback onSave;

  const MemoryMovieFormScreen({
    super.key,
    required this.theme,
    required this.onSave,
  });

  @override
  State<MemoryMovieFormScreen> createState() => _MemoryMovieFormScreenState();
}

class _MemoryMovieFormScreenState extends State<MemoryMovieFormScreen> {
  final _searchCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _originalCtrl = TextEditingController();
  final _reviewCtrl = TextEditingController();

  String? _posterUrl;
  String? _year;
  String _kind = 'movie';
  String? _genres;
  String? _country;
  String? _ratingKp;
  String? _infoUrl;
  int? _rating; // личная оценка 1–10
  DateTime? _customDate;

  List<MovieResult> _results = const [];
  bool _isSearching = false;
  bool _searchFailed = false;
  bool _noToken = false; // токен не задан → сразу ручной ввод
  bool _picked = false;
  bool _manualMode = false;
  Timer? _debounce;
  String _lastQuery = '';

  Color get _primary => widget.theme.primary;

  bool get _canSave => _titleCtrl.text.trim().isNotEmpty;

  bool get _isRu => LocaleService.instance.isRussian;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _titleCtrl.dispose();
    _originalCtrl.dispose();
    _reviewCtrl.dispose();
    super.dispose();
  }

  // ── Поиск ───────────────────────────────────────────────────────────────────

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q.length < 2) {
      setState(() {
        _results = const [];
        _isSearching = false;
        _searchFailed = false;
      });
      return;
    }
    setState(() {
      _manualMode = false;
      _searchFailed = false;
    });
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q));
  }

  Future<void> _search(String query) async {
    if (query.isEmpty) return;
    _lastQuery = query;
    setState(() {
      _isSearching = true;
      _searchFailed = false;
      _noToken = false;
    });
    try {
      final results = await MovieSearchService.search(query);
      if (!mounted || query != _lastQuery) return;
      // Поднимаем результаты с русским названием — для русских запросов важно
      // показать локализованные варианты выше.
      results.sort((a, b) {
        if (a.isRussianTitle == b.isRussianTitle) return 0;
        return a.isRussianTitle ? -1 : 1;
      });
      setState(() {
        _results = results;
        _searchFailed = results.isEmpty;
      });
    } on MovieSearchException catch (e) {
      if (!mounted || query != _lastQuery) return;
      setState(() {
        _results = const [];
        _searchFailed = true;
        _noToken = e.notConfigured || e.unauthorized;
      });
    } catch (_) {
      if (!mounted || query != _lastQuery) return;
      setState(() {
        _results = const [];
        _searchFailed = true;
      });
    } finally {
      if (mounted && query == _lastQuery) {
        setState(() => _isSearching = false);
      }
    }
  }

  void _enterManualMode() {
    _debounce?.cancel();
    FocusScope.of(context).unfocus();
    setState(() {
      _manualMode = true;
      _isSearching = false;
      _searchFailed = false;
      _results = const [];
    });
  }

  void _pick(MovieResult m) {
    FocusScope.of(context).unfocus();
    setState(() {
      _titleCtrl.text = m.title;
      _originalCtrl.text = m.originalTitle ?? '';
      _posterUrl = m.posterUrl;
      _year = m.year;
      _kind = m.kind;
      _genres = m.genres;
      _country = m.country;
      _ratingKp = m.ratingKp;
      _infoUrl = m.infoUrl;
      _picked = true;
      _manualMode = false;
      _searchFailed = false;
      _results = const [];
      _searchCtrl.clear();
    });
  }

  void _clearSelection() {
    setState(() {
      _picked = false;
      _posterUrl = null;
      _year = null;
      _kind = 'movie';
      _genres = null;
      _country = null;
      _ratingKp = null;
      _infoUrl = null;
      _titleCtrl.clear();
      _originalCtrl.clear();
    });
  }

  Future<void> _save() async {
    if (!_canSave) return;
    Navigator.pop(context);
    await widget.onSave(
      movieTitle: _titleCtrl.text.trim(),
      movieOriginalTitle: _originalCtrl.text.trim().isNotEmpty
          ? _originalCtrl.text.trim()
          : null,
      moviePosterUrl: _posterUrl,
      movieYear: _year,
      movieKind: _kind,
      movieGenres: _genres,
      movieCountry: _country,
      movieRatingKp: _ratingKp,
      movieInfoUrl: _infoUrl,
      rating: _rating,
      caption: _reviewCtrl.text.trim(),
      customDate: _customDate,
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

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
              padding: EdgeInsets.fromLTRB(
                16,
                4,
                16,
                28 + MediaQuery.of(context).padding.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_manualMode) _buildSearchCard(s),
                  if (!_manualMode &&
                      (_isSearching || _results.isNotEmpty || _searchFailed)) ...[
                    const SizedBox(height: 12),
                    _buildResults(s),
                  ],
                  if (_manualMode) ...[
                    const SizedBox(height: 16),
                    _buildManualEntryCard(s),
                  ],
                  if (_picked || _manualMode) ...[
                    const SizedBox(height: 16),
                    _buildDetailsCard(s),
                    const SizedBox(height: 16),
                    _buildRatingCard(s),
                    const SizedBox(height: 16),
                    _buildReviewField(s),
                    const SizedBox(height: 16),
                    MemoryDateField(
                      value: _customDate,
                      onChanged: (d) => setState(() => _customDate = d),
                      accent: _primary,
                    ),
                  ],
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
        s.movies,
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

  // ── Hero: poster preview ────────────────────────────────────────────────────

  Widget _buildHero(AppStrings s) {
    final accent = _primary;
    final hasMovie = _picked && _titleCtrl.text.trim().isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: 0.12),
            accent.withValues(alpha: 0.02),
            widget.theme.cardSurface,
          ],
        ),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 220,
            child: Center(
              child: _MoviePoster(
                accent: accent,
                posterUrl: _posterUrl,
                title: _titleCtrl.text.trim(),
                kind: _kind,
                ratingKp: _ratingKp,
                isRu: _isRu,
              ),
            ),
          ),
          const SizedBox(height: 18),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(
              hasMovie ? _titleCtrl.text.trim() : s.movies,
              key: ValueKey(hasMovie ? _titleCtrl.text.trim() : '_'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.15,
                color: hasMovie ? widget.theme.textPrimary : widget.theme.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 4),
          if (hasMovie && _originalCtrl.text.trim().isNotEmpty)
            Text(
              _originalCtrl.text.trim(),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            )
          else if (!hasMovie)
            Text(
              s.searchMoviesPrompt,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: widget.theme.textMuted),
            ),
          if (hasMovie && (_year != null || _genres != null)) ...[
            const SizedBox(height: 10),
            _metaChips(accent),
          ],
        ],
      ),
    );
  }

  Widget _metaChips(Color accent) {
    final chips = <Widget>[];
    if (_year != null && _year!.isNotEmpty) {
      chips.add(_chip(Icons.calendar_today_rounded, _year!, accent));
    }
    if (_genres != null && _genres!.isNotEmpty) {
      chips.add(_chip(Icons.theaters_rounded, _genres!, accent));
    }
    if (_country != null && _country!.isNotEmpty) {
      chips.add(_chip(Icons.public_rounded, _country!, accent));
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: chips,
    );
  }

  Widget _chip(IconData icon, String label, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: accent),
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

  // ── Search card ─────────────────────────────────────────────────────────────

  Widget _buildSearchCard(AppStrings s) {
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
                  color: _primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.movie_filter_rounded, size: 16, color: _primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _picked ? s.movieDetails : s.searchMoviesPrompt,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: widget.theme.textPrimary,
                  ),
                ),
              ),
              if (_picked)
                TextButton(
                  onPressed: _clearSelection,
                  style: TextButton.styleFrom(
                    foregroundColor: _primary,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    s.movieSearchAgain,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _searchCtrl,
            style: const TextStyle(fontSize: 14),
            textInputAction: TextInputAction.search,
            onChanged: _onQueryChanged,
            onSubmitted: (v) => _search(v.trim()),
            decoration: InputDecoration(
              hintText: s.movieSearchHint,
              hintStyle: TextStyle(color: widget.theme.textMuted, fontSize: 13),
              prefixIcon: Icon(Icons.search_rounded, color: _primary, size: 20),
              suffixIcon: _isSearching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.grey),
                      ),
                    )
                  : (_searchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear_rounded,
                              color: widget.theme.textMuted, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            _onQueryChanged('');
                          },
                        )
                      : null),
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
        ],
      ),
    );
  }

  // ── Results ─────────────────────────────────────────────────────────────────

  Widget _buildResults(AppStrings s) {
    if (_isSearching && _results.isEmpty) {
      return Container(
        height: 80,
        alignment: Alignment.center,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: _primary),
        ),
      );
    }
    if (_results.isEmpty) {
      final failed = _searchFailed;
      return Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        decoration: BoxDecoration(
          color: failed ? Colors.orange.shade50 : widget.theme.surfaceMuted,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: failed ? Colors.orange.shade200 : widget.theme.divider,
          ),
        ),
        child: Column(
          children: [
            Icon(
              _noToken
                  ? Icons.vpn_key_off_rounded
                  : (failed ? Icons.cloud_off_rounded : Icons.search_off_rounded),
              color: failed ? Colors.orange.shade400 : widget.theme.textMuted,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              _noToken
                  ? s.movieNoToken
                  : (failed ? s.movieSearchFailed : s.noMoviesFound),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: failed ? Colors.orange.shade700 : widget.theme.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (failed && !_noToken) ...[
              const SizedBox(height: 4),
              Text(
                s.movieSearchFailedHint,
                textAlign: TextAlign.center,
                style: TextStyle(color: widget.theme.textMuted, fontSize: 11.5),
              ),
            ],
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _enterManualMode,
              icon: const Icon(Icons.edit_rounded, size: 16),
              label: Text(s.movieEnterManually),
              style: TextButton.styleFrom(
                foregroundColor: _primary,
                backgroundColor: _primary.withValues(alpha: 0.08),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                textStyle:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: widget.theme.cardSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: widget.theme.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _results.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: widget.theme.divider),
            itemBuilder: (_, i) => _resultTile(_results[i]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: TextButton.icon(
              onPressed: _enterManualMode,
              icon: const Icon(Icons.edit_rounded, size: 15),
              label: Text(s.movieEnterManually),
              style: TextButton.styleFrom(
                foregroundColor: _primary,
                textStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildManualEntryCard(AppStrings s) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _primary.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _primary.withValues(alpha: 0.20)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.edit_rounded, size: 16, color: _primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.movieManualEntryHint,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: widget.theme.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _manualMode = false),
            style: TextButton.styleFrom(
              foregroundColor: _primary,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              s.movieSearchAgain,
              style:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultTile(MovieResult m) {
    final hasRussian = m.isRussianTitle;
    return InkWell(
      onTap: () => _pick(m),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            _miniPoster(m.posterUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          m.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: widget.theme.textPrimary,
                            height: 1.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _langTag(hasRussian ? 'RU' : 'EN'),
                    ],
                  ),
                  if (m.originalTitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        m.originalTitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(fontSize: 12, color: widget.theme.textMuted),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _kindTag(m.kind),
                      if (m.year != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          m.year!,
                          style: TextStyle(
                              fontSize: 11, color: widget.theme.textMuted),
                        ),
                      ],
                      if (m.ratingKp != null) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.star_rounded,
                            size: 12, color: Colors.amber.shade600),
                        const SizedBox(width: 2),
                        Text(
                          m.ratingKp!,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.amber.shade700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.add_circle_outline_rounded, color: _primary, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _kindTag(String kind) {
    final label = movieKindLabel(kind, isRu: _isRu);
    final isSeries = kind != 'movie' && kind != 'cartoon';
    final color = isSeries ? const Color(0xFF8B5CF6) : _primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
          color: color,
        ),
      ),
    );
  }

  Widget _langTag(String code) {
    final isRu = code == 'RU';
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isRu
            ? Colors.green.withValues(alpha: 0.12)
            : Colors.blueGrey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        code,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
          color: isRu ? Colors.green.shade700 : Colors.blueGrey.shade600,
        ),
      ),
    );
  }

  Widget _miniPoster(String? url) {
    return Container(
      width: 44,
      height: 62,
      decoration: BoxDecoration(
        color: _primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: (url != null && url.isNotEmpty)
          ? Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _posterIcon(),
            )
          : _posterIcon(),
    );
  }

  Widget _posterIcon() => Center(
        child: Icon(Icons.movie_rounded,
            color: _primary.withValues(alpha: 0.5), size: 20),
      );

  // ── Details (editable) ──────────────────────────────────────────────────────

  Widget _buildDetailsCard(AppStrings s) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _primary.withValues(alpha: 0.04),
            _primary.withValues(alpha: 0.02),
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
                    Icon(Icons.local_movies_rounded, size: 16, color: _primary),
              ),
              const SizedBox(width: 10),
              Text(
                s.movieDetails,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: widget.theme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _field(
            controller: _titleCtrl,
            hint: s.movieTitleHint,
            icon: Icons.title_rounded,
          ),
          const SizedBox(height: 10),
          _field(
            controller: _originalCtrl,
            hint: s.movieOriginalTitleHint,
            icon: Icons.translate_rounded,
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 15),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: hint,
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

  Widget _buildRatingCard(AppStrings s) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.theme.surfaceMuted,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: widget.theme.divider),
      ),
      child: RatingPicker(
        value: _rating,
        accent: _primary,
        onChanged: (v) => setState(() => _rating = v),
      ),
    );
  }

  Widget _buildReviewField(AppStrings s) {
    return TextField(
      controller: _reviewCtrl,
      maxLines: 4,
      minLines: 2,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: s.yourReview,
        labelStyle: TextStyle(color: _primary, fontWeight: FontWeight.w600),
        hintText: s.reviewHint,
        hintStyle: TextStyle(color: widget.theme.textMuted),
        alignLabelWithHint: true,
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

/// Стильное превью постера фильма с тенью, бейджем типа и рейтингом КП.
class _MoviePoster extends StatelessWidget {
  final Color accent;
  final String? posterUrl;
  final String title;
  final String kind;
  final String? ratingKp;
  final bool isRu;

  const _MoviePoster({
    required this.accent,
    this.posterUrl,
    required this.title,
    required this.kind,
    this.ratingKp,
    required this.isRu,
  });

  @override
  Widget build(BuildContext context) {
    const w = 150.0;
    const h = 210.0; // постер ~2:3
    return SizedBox(
      width: w + 16,
      height: h + 12,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            bottom: 0,
            child: Container(
              width: w * 0.8,
              height: 16,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(40),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    blurRadius: 16,
                  ),
                ],
              ),
            ),
          ),
          Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.28),
                  blurRadius: 26,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
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
                  // Затемнение снизу под бейджи
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 56,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.55),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Бейдж типа (Фильм/Сериал)
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        movieKindLabel(kind, isRu: isRu),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: accent,
                        ),
                      ),
                    ),
                  ),
                  // Рейтинг КП
                  if (ratingKp != null)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.star_rounded,
                                size: 12, color: Colors.amber.shade400),
                            const SizedBox(width: 3),
                            Text(
                              ratingKp!,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // Глянцевый блик
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
                          stops: const [0.0, 0.4],
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
        padding: const EdgeInsets.fromLTRB(16, 18, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.movie_rounded, color: Colors.white, size: 30),
            const Spacer(),
            if (title.isNotEmpty)
              Text(
                title,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
