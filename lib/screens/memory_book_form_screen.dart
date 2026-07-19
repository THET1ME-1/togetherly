import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/locale_service.dart';
import '../theme/app_theme.dart';
import '../widgets/memory_date_field.dart';
import '../widgets/rating_widgets.dart';

/// Сохранение книжного воспоминания.
typedef MemoryBookSaveCallback = Future<void> Function({
  required String bookTitle,
  required String bookAuthor,
  String? bookCoverUrl,
  String? bookYear,
  String? bookPublisher,
  String? bookInfoUrl,
  int? rating,
  required String caption,
  DateTime? customDate,
});

/// Одна книга из результатов поиска.
class _BookResult {
  final String title;
  final String author;
  final String? coverUrl;
  final String? year;
  final String? publisher;
  final String? infoUrl;
  /// `true`, если в заголовке есть кириллица — то есть название
  /// уже на русском. Open Library хранит `title` в исходном языке
  /// произведения, поэтому для переводных книг (Harry Potter и т.п.)
  /// поле будет `false`, даже если искали на русском.
  final bool isRussianTitle;

  const _BookResult({
    required this.title,
    required this.author,
    this.coverUrl,
    this.year,
    this.publisher,
    this.infoUrl,
    this.isRussianTitle = false,
  });

  /// Парсит документ Open Library (https://openlibrary.org/dev/docs/api/search).
  factory _BookResult.fromOpenLibraryDoc(Map<String, dynamic> doc) {
    final title = doc['title']?.toString().trim() ?? '';
    final authors =
        (doc['author_name'] as List?)?.cast<String>().where((a) => a.isNotEmpty) ??
            const [];
    // publisher — список издательств; берём самое релевантное.
    final publishers =
        (doc['publisher'] as List?)?.cast<String>().where((p) => p.isNotEmpty) ??
            const [];
    // first_publish_year — int; в title может быть year у конкретного издания.
    final firstYear = doc['first_publish_year'];
    final year = (firstYear is num) ? firstYear.toInt().toString() : null;
    // cover_i — числовой id обложки. Формируем прямую ссылку размера L.
    final coverId = doc['cover_i'];
    String? coverUrl;
    if (coverId is num) {
      coverUrl = 'https://covers.openlibrary.org/b/id/${coverId.toInt()}-L.jpg';
    } else if (coverId is String && coverId.isNotEmpty) {
      coverUrl = 'https://covers.openlibrary.org/b/id/$coverId-L.jpg';
    }
    // key — путь вроде "/works/OL468431W" — ссылка на карточку книги.
    final key = doc['key']?.toString();
    final infoUrl = (key != null && key.isNotEmpty)
        ? 'https://openlibrary.org$key'
        : null;
    return _BookResult(
      title: title,
      author: authors.join(', '),
      coverUrl: coverUrl,
      year: year,
      publisher: publishers.isNotEmpty ? publishers.first : null,
      infoUrl: infoUrl,
      // Open Library не отдаёт локализованные названия в `search.json`,
      // поэтому проверяем наличие кириллицы в самом title.
      isRussianTitle: _cyr.hasMatch(title),
    );
  }

  static final RegExp _cyr = RegExp(r'[\u0400-\u04FF]');
}

/// Полноэкранная форма создания книжного воспоминания.
///
/// Поиск по бесплатному Open Library API (название или автор, без ключа
/// и квот, отлично индексирует русскоязычные книги), выбор из списка,
/// подтверждение и редактирование, а также живое 3D-превью обложки
/// в теме приложения.
class MemoryBookFormScreen extends StatefulWidget {
  final AppTheme theme;
  final MemoryBookSaveCallback onSave;

  const MemoryBookFormScreen({
    super.key,
    required this.theme,
    required this.onSave,
  });

  @override
  State<MemoryBookFormScreen> createState() => _MemoryBookFormScreenState();
}

class _MemoryBookFormScreenState extends State<MemoryBookFormScreen> {
  final _searchCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _authorCtrl = TextEditingController();
  final _captionCtrl = TextEditingController();

  String? _coverUrl;
  String? _year;
  String? _publisher;
  String? _infoUrl;
  int? _rating; // личная оценка 1–10
  DateTime? _customDate;

  List<_BookResult> _results = const [];
  bool _isSearching = false;
  bool _searchFailed = false; // последний запрос упал — покажем «ввести вручную»
  bool _picked = false; // выбрана конкретная книга → показываем превью/детали
  bool _manualMode = false; // пользователь выбрал «ввести вручную» (минуя API)
  Timer? _debounce;
  String _lastQuery = '';

  Color get _primary => widget.theme.primary;

  bool get _canSave => _titleCtrl.text.trim().isNotEmpty;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _titleCtrl.dispose();
    _authorCtrl.dispose();
    _captionCtrl.dispose();
    super.dispose();
  }

  // ── Поиск ─────────────────────────────────────────────────────────────────

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
    });
    // Open Library: дефолтная сортировка — релевантность,
    // параметр sort=relevance ломает ответ (500), поэтому не передаём.
    final uri = Uri.https('openlibrary.org', '/search.json', {
      'q': query,
      'limit': '20',
    });
    debugPrint('[BookForm] GET $uri');
    try {
      final resp = await http
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              // UA обязателен — без него Open Library отбивает некоторые запросы.
              'User-Agent':
                  'Mozilla/5.0 (compatible; TogetherlyApp/1.0; +https://togetherly.app)',
            },
          )
          // Жёсткий таймаут: на мобильной сети ответ может висеть вечно,
          // и пользователь не понимает, что поиск не сработал.
          .timeout(const Duration(seconds: 10));
      if (!mounted || query != _lastQuery) return;
      debugPrint(
        '[BookForm] ← ${resp.statusCode}, ${resp.body.length} bytes, '
        'q="$query"',
      );
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final docs = (data['docs'] as List?) ?? const [];
        final parsed = docs
            .map((e) =>
                _BookResult.fromOpenLibraryDoc(e as Map<String, dynamic>))
            .where((b) => b.title.isNotEmpty)
            .toList();
        // Поднимаем книги с русским названием — Open Library отдаёт
        // оригинальные (часто английские) тайтлы, поэтому для русских
        // запросов важно показать локализованные варианты сверху списка.
        parsed.sort((a, b) {
          if (a.isRussianTitle == b.isRussianTitle) return 0;
          return a.isRussianTitle ? -1 : 1;
        });
        debugPrint('[BookForm] parsed ${parsed.length} books '
            '(${parsed.where((b) => b.isRussianTitle).length} RU-titled)');
        setState(() {
          _results = parsed;
          _searchFailed = parsed.isEmpty;
        });
      } else {
        debugPrint('[BookForm] non-200: ${resp.statusCode}');
        setState(() {
          _results = const [];
          _searchFailed = true;
        });
      }
    } on TimeoutException {
      debugPrint('[BookForm] timeout for "$query"');
      if (!mounted || query != _lastQuery) return;
      setState(() {
        _results = const [];
        _searchFailed = true;
      });
    } catch (e, st) {
      debugPrint('[BookForm] error: $e\n$st');
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

  void _pick(_BookResult book) {
    FocusScope.of(context).unfocus();
    setState(() {
      // Подставляем то, что нашли. Если title не на русском —
      // оставляем в нём подсказку для пользователя, чтобы было удобно
      // отредактировать вручную (кнопка "Edit" в детальной карточке
      // уже разлочивает поле title).
      _titleCtrl.text = book.title;
      _authorCtrl.text = book.author;
      _coverUrl = book.coverUrl;
      _year = book.year;
      _publisher = book.publisher;
      _infoUrl = book.infoUrl;
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
      _coverUrl = null;
      _year = null;
      _publisher = null;
      _infoUrl = null;
      _titleCtrl.clear();
      _authorCtrl.clear();
    });
  }

  Future<void> _save() async {
    if (!_canSave) return;
    Navigator.pop(context);
    await widget.onSave(
      bookTitle: _titleCtrl.text.trim(),
      bookAuthor: _authorCtrl.text.trim(),
      bookCoverUrl: _coverUrl,
      bookYear: _year,
      bookPublisher: _publisher,
      bookInfoUrl: _infoUrl,
      rating: _rating,
      caption: _captionCtrl.text.trim(),
      customDate: _customDate,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

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
                      (_isSearching ||
                          _results.isNotEmpty ||
                          _searchFailed)) ...[
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
                    _buildCaptionField(s),
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
        s.books,
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

  // ── Hero: 3D book preview ───────────────────────────────────────────────────

  Widget _buildHero(AppStrings s) {
    final accent = _primary;
    final hasBook = _picked && _titleCtrl.text.trim().isNotEmpty;

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
            height: 210,
            child: Center(
              child: _Book3D(
                accent: accent,
                coverUrl: _coverUrl,
                title: _titleCtrl.text.trim(),
                author: _authorCtrl.text.trim(),
              ),
            ),
          ),
          const SizedBox(height: 18),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(
              hasBook ? _titleCtrl.text.trim() : s.books,
              key: ValueKey(hasBook ? _titleCtrl.text.trim() : '_'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.15,
                color: hasBook ? widget.theme.textPrimary : widget.theme.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 4),
          if (hasBook && _authorCtrl.text.trim().isNotEmpty)
            Text(
              _authorCtrl.text.trim(),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            )
          else if (!hasBook)
            Text(
              s.searchBooksPrompt,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: widget.theme.textMuted),
            ),
          if (hasBook && (_year != null || _publisher != null)) ...[
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
    if (_publisher != null && _publisher!.isNotEmpty) {
      chips.add(_chip(Icons.business_rounded, _publisher!, accent));
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
            constraints: const BoxConstraints(maxWidth: 160),
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
                child: Icon(Icons.menu_book_rounded, size: 16, color: _primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _picked ? s.bookDetails : s.searchBooksPrompt,
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
                    s.bookSearchAgain,
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
              hintText: s.bookSearchHint,
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
      // Не нашлось — даём пользователю путь выхода: ввести вручную.
      final failed = _searchFailed;
      return Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        decoration: BoxDecoration(
          color: failed
              ? Colors.orange.shade50
              : widget.theme.surfaceMuted,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: failed
                ? Colors.orange.shade200
                : widget.theme.divider,
          ),
        ),
        child: Column(
          children: [
            Icon(
              failed
                  ? Icons.cloud_off_rounded
                  : Icons.search_off_rounded,
              color: failed
                  ? Colors.orange.shade400
                  : widget.theme.textMuted,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              failed ? s.bookSearchFailed : s.noBooksFound,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: failed
                    ? Colors.orange.shade700
                    : widget.theme.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (failed) ...[
              const SizedBox(height: 4),
              Text(
                s.bookSearchFailedHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.theme.textMuted,
                  fontSize: 11.5,
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _enterManualMode,
              icon: const Icon(Icons.edit_rounded, size: 16),
              label: Text(s.bookEnterManually),
              style: TextButton.styleFrom(
                foregroundColor: _primary,
                backgroundColor: _primary.withValues(alpha: 0.08),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
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
          // Внизу списка — запасной вариант «ввести вручную»,
          // чтобы не заставлять пользователя стирать запрос.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: TextButton.icon(
              onPressed: _enterManualMode,
              icon: const Icon(Icons.edit_rounded, size: 15),
              label: Text(s.bookEnterManually),
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

  // ── Manual entry card — запасной режим, если API не ответил ────────────────
  Widget _buildManualEntryCard(AppStrings s) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _primary.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _primary.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                  s.bookManualEntryHint,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: widget.theme.textPrimary,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _manualMode = false;
                  });
                },
                style: TextButton.styleFrom(
                  foregroundColor: _primary,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  s.bookSearchAgain,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _resultTile(_BookResult book) {
    // Подсказка про язык: Open Library отдаёт название в исходном языке,
    // поэтому для переводных книг показываем, что title не на русском —
    // пользователь сможет поправить его в ручном режиме.
    final hasRussian = book.isRussianTitle;
    return InkWell(
      onTap: () => _pick(book),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            _miniCover(book.coverUrl),
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
                          book.title,
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
                  if (book.author.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: widget.theme.textMuted),
                      ),
                    ),
                  if (book.year != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        book.year!,
                        style: TextStyle(
                            fontSize: 11, color: widget.theme.textMuted),
                      ),
                    ),
                ],
              ),
            ),
            Icon(Icons.add_circle_outline_rounded,
                color: _primary, size: 22),
          ],
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

  Widget _miniCover(String? url) {
    return Container(
      width: 42,
      height: 60,
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
              errorBuilder: (_, __, ___) => _coverIcon(),
            )
          : _coverIcon(),
    );
  }

  Widget _coverIcon() => Center(
        child: Icon(Icons.menu_book_rounded,
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
                child: Icon(Icons.auto_stories_rounded,
                    size: 16, color: _primary),
              ),
              const SizedBox(width: 10),
              Text(
                s.bookDetails,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: widget.theme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Подсказка, что название в Open Library хранится в исходном
          // языке произведения — можно переписать на русский.
          if (_titleCtrl.text.isNotEmpty &&
              !_BookResult._cyr.hasMatch(_titleCtrl.text))
            _nonRussianTitleHint(),
          _field(
            controller: _titleCtrl,
            hint: s.bookTitleHint,
            icon: Icons.title_rounded,
          ),
          const SizedBox(height: 10),
          _field(
            controller: _authorCtrl,
            hint: s.bookAuthorHint,
            icon: Icons.person_rounded,
          ),
        ],
      ),
    );
  }

  Widget _nonRussianTitleHint() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.amber.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.amber.shade200),
        ),
        child: Row(
          children: [
            Icon(Icons.translate_rounded, size: 14, color: Colors.amber.shade800),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                LocaleService.current.bookTitleLanguageHint,
                style: TextStyle(
                  fontSize: 11.5,
                  color: Colors.amber.shade900,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
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

  Widget _buildCaptionField(AppStrings s) {
    return TextField(
      controller: _captionCtrl,
      maxLines: 4,
      minLines: 2,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: s.yourReview,
        labelStyle: TextStyle(color: _primary, fontWeight: FontWeight.w600),
        alignLabelWithHint: true,
        hintText: s.reviewHint,
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

/// Стилизованная 3D-обложка книги с корешком и тенью.
class _Book3D extends StatelessWidget {
  final Color accent;
  final String? coverUrl;
  final String title;
  final String author;

  const _Book3D({
    required this.accent,
    this.coverUrl,
    required this.title,
    required this.author,
  });

  @override
  Widget build(BuildContext context) {
    const w = 138.0;
    const h = 196.0;
    return SizedBox(
      width: w + 16,
      height: h + 12,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Тень-«подставка» под книгой
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
          // Сама книга
          Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(8),
                bottomRight: Radius.circular(8),
                topLeft: Radius.circular(3),
                bottomLeft: Radius.circular(3),
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.28),
                  blurRadius: 26,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(8),
                bottomRight: Radius.circular(8),
                topLeft: Radius.circular(3),
                bottomLeft: Radius.circular(3),
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
                  // Корешок слева — тёмная полоса
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 10,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.black.withValues(alpha: 0.28),
                            Colors.black.withValues(alpha: 0.04),
                          ],
                        ),
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
                            Colors.white.withValues(alpha: 0.18),
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
        padding: const EdgeInsets.fromLTRB(18, 22, 12, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.menu_book_rounded, color: Colors.white, size: 30),
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
            if (author.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                author,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 11,
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
