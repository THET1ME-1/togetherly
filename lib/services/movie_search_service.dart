import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Поиск фильмов и сериалов через бесплатный API poiskkino.dev
/// (бывший kinopoisk.dev — сервис прошёл ребрендинг, сменив домен и бота).
///
/// Токен бесплатный — получить можно в Telegram-боте `@poiskkinodev_bot`
/// (команда `/api`, бесплатный тариф ~200 запросов в день). Вставьте его в
/// [_fallbackToken] ниже **или** передайте при сборке:
/// `flutter build apk --dart-define=KINOPOISK_TOKEN=ВАШ_ТОКЕН`.
/// Документация: https://poiskkino.dev/documentation
///
/// Без токена поиск отключается «мягко»: форма сразу предложит ввести
/// данные вручную, остальная часть фичи продолжает работать.
class MovieSearchService {
  MovieSearchService._();

  // Токен из --dart-define имеет приоритет над захардкоженным.
  static const String _envToken = String.fromEnvironment('KINOPOISK_TOKEN');

  /// ⬇️ Бесплатный токен poiskkino.dev (получен через @poiskkinodev_bot).
  static const String _fallbackToken = 'TM3RQXB-DCZMAJ5-GF7RGGM-NSKB7JS';

  static String get _token => _envToken.isNotEmpty ? _envToken : _fallbackToken;

  /// `true`, если токен задан — иначе форма уходит в ручной ввод.
  static bool get isConfigured => _token.trim().isNotEmpty;

  /// Ищет фильмы/сериалы по названию (русскому или английскому).
  ///
  /// Бросает [MovieSearchException] при сетевой/серверной ошибке, чтобы форма
  /// показала запасной путь «ввести вручную».
  static Future<List<MovieResult>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    if (!isConfigured) {
      throw const MovieSearchException(notConfigured: true);
    }

    // v1.4 /movie/search — текстовый поиск по релевантности, отдаёт и фильмы,
    // и сериалы. Запрашиваем только нужные поля, чтобы ответ был компактным.
    final uri = Uri.https('api.poiskkino.dev', '/v1.4/movie/search', {
      'page': '1',
      'limit': '25',
      'query': q,
    });
    debugPrint('[MovieSearch] GET $uri');
    try {
      final resp = await http.get(
        uri,
        headers: {
          'accept': 'application/json',
          'X-API-KEY': _token,
        },
      ).timeout(const Duration(seconds: 10));

      debugPrint('[MovieSearch] ← ${resp.statusCode}, ${resp.body.length} bytes');
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw const MovieSearchException(unauthorized: true);
      }
      if (resp.statusCode != 200) {
        throw MovieSearchException(message: 'HTTP ${resp.statusCode}');
      }
      final data = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final docs = (data['docs'] as List?) ?? const [];
      final parsed = docs
          .whereType<Map<String, dynamic>>()
          .map(MovieResult.fromKinopoiskDoc)
          .where((m) => m.title.isNotEmpty)
          .toList();
      debugPrint('[MovieSearch] parsed ${parsed.length} titles');
      return parsed;
    } on MovieSearchException {
      rethrow;
    } on TimeoutException {
      throw const MovieSearchException(message: 'timeout');
    } catch (e, st) {
      debugPrint('[MovieSearch] error: $e\n$st');
      throw MovieSearchException(message: e.toString());
    }
  }
}

/// Ошибка поиска — несёт причину для подходящего сообщения в UI.
class MovieSearchException implements Exception {
  final bool notConfigured; // токен не задан
  final bool unauthorized; // токен неверный / просрочен
  final String? message;

  const MovieSearchException({
    this.notConfigured = false,
    this.unauthorized = false,
    this.message,
  });

  @override
  String toString() =>
      'MovieSearchException(notConfigured: $notConfigured, '
      'unauthorized: $unauthorized, message: $message)';
}

/// Один фильм/сериал из результатов поиска kinopoisk.dev.
class MovieResult {
  final int id;

  /// Локализованное (русское) название. Если его нет — оригинальное.
  final String title;

  /// Оригинальное / английское название (если отличается от [title]).
  final String? originalTitle;

  final String? posterUrl;

  /// Год выпуска. Для сериалов — диапазон «2018–2022», если известен.
  final String? year;

  /// Сырой тип kinopoisk: movie / tv-series / cartoon / anime / animated-series.
  final String kind;

  final String? genres; // «драма, мелодрама»
  final String? country; // основная страна
  final String? ratingKp; // рейтинг КП, напр. «7.5»
  final String? description;

  const MovieResult({
    required this.id,
    required this.title,
    this.originalTitle,
    this.posterUrl,
    this.year,
    required this.kind,
    this.genres,
    this.country,
    this.ratingKp,
    this.description,
  });

  bool get isSeries =>
      kind == 'tv-series' || kind == 'animated-series' || kind == 'anime';

  /// `true`, если основное название на кириллице.
  bool get isRussianTitle => _cyr.hasMatch(title);

  /// Ссылка на карточку на Кинопоиске.
  String get infoUrl => 'https://www.kinopoisk.ru/film/$id/';

  factory MovieResult.fromKinopoiskDoc(Map<String, dynamic> doc) {
    final ruName = (doc['name'] as String?)?.trim();
    final altName = (doc['alternativeName'] as String?)?.trim();
    final enName = (doc['enName'] as String?)?.trim();
    // Приоритет — русское название. Если его нет, берём оригинальное.
    final original = (altName?.isNotEmpty == true ? altName : enName);
    final title =
        (ruName?.isNotEmpty == true ? ruName! : (original ?? '')).trim();

    final yearRaw = doc['year'];
    String? year = (yearRaw is num) ? yearRaw.toInt().toString() : null;
    // Для сериалов API может отдавать диапазон в releaseYears.
    final releaseYears = doc['releaseYears'];
    if (releaseYears is List && releaseYears.isNotEmpty) {
      final ry = releaseYears.first;
      if (ry is Map) {
        final start = ry['start'];
        final end = ry['end'];
        if (start is num) {
          year = end is num
              ? (end == start ? '$start' : '$start–$end')
              : '$start–…';
        }
      }
    }

    String? poster;
    final posterObj = doc['poster'];
    if (posterObj is Map) {
      poster = (posterObj['previewUrl'] ?? posterObj['url']) as String?;
    }

    final genres = (doc['genres'] as List?)
        ?.whereType<Map>()
        .map((g) => g['name']?.toString() ?? '')
        .where((g) => g.isNotEmpty)
        .take(3)
        .join(', ');

    String? country;
    final countries = doc['countries'];
    if (countries is List && countries.isNotEmpty) {
      final first = countries.first;
      if (first is Map) country = first['name']?.toString();
    }

    String? ratingKp;
    final rating = doc['rating'];
    if (rating is Map) {
      final kp = rating['kp'];
      if (kp is num && kp > 0) ratingKp = kp.toStringAsFixed(1);
    }

    return MovieResult(
      id: (doc['id'] as num?)?.toInt() ?? 0,
      title: title,
      // originalTitle храним только если реально отличается от заголовка.
      originalTitle: (original != null && original.isNotEmpty && original != title)
          ? original
          : null,
      posterUrl: (poster != null && poster.isNotEmpty) ? poster : null,
      year: year,
      kind: (doc['type'] as String?) ?? 'movie',
      genres: (genres != null && genres.isNotEmpty) ? genres : null,
      country: country,
      ratingKp: ratingKp,
      description: (doc['shortDescription'] as String?)?.trim().isNotEmpty == true
          ? (doc['shortDescription'] as String).trim()
          : (doc['description'] as String?)?.trim(),
    );
  }

  static final RegExp _cyr = RegExp(r'[Ѐ-ӿ]');
}

/// Человекочитаемая метка типа («Фильм» / «Сериал» / «Мультфильм» / «Аниме»).
String movieKindLabel(String? kind, {required bool isRu}) {
  switch (kind) {
    case 'tv-series':
      return isRu ? 'Сериал' : 'Series';
    case 'cartoon':
      return isRu ? 'Мультфильм' : 'Cartoon';
    case 'animated-series':
      return isRu ? 'Мультсериал' : 'Animated series';
    case 'anime':
      return isRu ? 'Аниме' : 'Anime';
    case 'movie':
    default:
      return isRu ? 'Фильм' : 'Movie';
  }
}
