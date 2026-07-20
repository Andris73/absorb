/// Hardcover GraphQL client for series rosters.
///
/// Hardcover disables `_ilike` filters and caps query depth at 3, so series
/// resolution is a two-step flow: full-text search for the slug, then an
/// exact-slug roster query.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'title_matching.dart' show tokenize;

/// One roster entry: a book title at a series position.
class HardcoverRosterEntry {
  final double? position;
  final String title;

  const HardcoverRosterEntry({this.position, required this.title});
}

/// A series roster from Hardcover, ordered by position ascending.
class HardcoverRoster {
  final String name;
  final String? description;
  final List<HardcoverRosterEntry> books;

  const HardcoverRoster({
    required this.name,
    this.description,
    this.books = const [],
  });
}

/// Series membership of a single book (from `findBookSeries`).
class HardcoverBookSeries {
  final String name;
  final String slug;
  final double? position;

  const HardcoverBookSeries({
    required this.name,
    required this.slug,
    this.position,
  });
}

/// GraphQL client for api.hardcover.app. Rate limit is 60 req/min, so
/// callers should cache aggressively.
class HardcoverClient {
  /// [token] is the user's API token; "Bearer " is prefixed automatically
  /// when missing.
  HardcoverClient(String token)
      : _auth = token.startsWith('Bearer ') ? token : 'Bearer $token';

  final String _auth;
  final http.Client _client = http.Client();

  void dispose() => _client.close();

  Future<Map<String, dynamic>?> _query(String query,
      [Map<String, dynamic>? variables]) async {
    final resp = await _client
        .post(
          Uri.parse('https://api.hardcover.app/v1/graphql'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': _auth,
            'User-Agent': 'Absorb (Discover)',
          },
          body: jsonEncode({
            'query': query,
            if (variables != null) 'variables': variables,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    return decoded['data'] as Map<String, dynamic>?;
  }

  /// Search hits from the typesense-style `search` field. `results` may be
  /// an object or a JSON-encoded string depending on API version.
  List<Map<String, dynamic>> _searchHits(Map<String, dynamic>? data) {
    var results = data?['search']?['results'];
    if (results is String) {
      try {
        results = jsonDecode(results);
      } catch (_) {
        return [];
      }
    }
    if (results is! Map<String, dynamic>) return [];
    final hits = results['hits'] as List<dynamic>? ?? [];
    return hits
        .whereType<Map<String, dynamic>>()
        .map((h) => h['document'])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  String _docAuthors(Map<String, dynamic> doc) {
    final single = doc['author_name'];
    if (single is String && single.isNotEmpty) return single;
    final many = doc['author_names'];
    if (many is List) return many.whereType<String>().join(' ');
    return '';
  }

  bool _authorOverlap(String a, String b) {
    final ta = tokenize(a).toSet();
    final tb = tokenize(b).toSet();
    if (ta.isEmpty || tb.isEmpty) return false;
    return ta.intersection(tb).isNotEmpty;
  }

  /// Find the best-matching series slug for a series name. When [author] is
  /// given, hits whose author overlaps score higher.
  Future<String?> searchSeriesSlug(String name, {String? author}) async {
    try {
      final data = await _query(
        r'query Search($q: String!) { search(query: $q, query_type: "Series", per_page: 5) { results } }',
        {'q': name},
      );
      String? bestSlug;
      var bestScore = 0;
      final wanted = name.toLowerCase().trim();
      for (final doc in _searchHits(data)) {
        final hitName = (doc['name'] as String? ?? '').toLowerCase().trim();
        final slug = doc['slug'] as String? ?? '';
        if (hitName.isEmpty || slug.isEmpty) continue;
        int s;
        if (hitName == wanted) {
          s = 3;
        } else if (hitName.contains(wanted) || wanted.contains(hitName)) {
          s = 2;
        } else {
          continue;
        }
        if (author != null &&
            author.isNotEmpty &&
            _authorOverlap(_docAuthors(doc), author)) {
          s += 2;
        }
        if (s > bestScore) {
          bestScore = s;
          bestSlug = slug;
        }
      }
      return bestSlug;
    } catch (_) {
      return null;
    }
  }

  /// Fetch the full roster for a series slug, ordered by position.
  /// Entries may repeat per edition; callers should dedupe titles.
  Future<HardcoverRoster?> roster(String slug) async {
    try {
      final data = await _query(
        r'query Roster($slug: String!) { series(where: {slug: {_eq: $slug}}, limit: 1) { name description book_series(order_by: {position: asc}) { position book { title } } } }',
        {'slug': slug},
      );
      final series = (data?['series'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (series.isEmpty) return null;
      final s = series.first;
      final books = <HardcoverRosterEntry>[];
      for (final bs in (s['book_series'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()) {
        final title =
            (bs['book'] as Map<String, dynamic>?)?['title'] as String? ?? '';
        if (title.isEmpty) continue;
        books.add(HardcoverRosterEntry(
          position: (bs['position'] as num?)?.toDouble(),
          title: title,
        ));
      }
      return HardcoverRoster(
        name: s['name'] as String? ?? slug,
        description: s['description'] as String?,
        books: books,
      );
    } catch (_) {
      return null;
    }
  }

  /// Validate the token. Returns the username, or null when invalid.
  Future<String?> verifyToken() async {
    try {
      final data = await _query('query { me { username } }');
      final me = data?['me'];
      if (me is List && me.isNotEmpty) {
        return (me.first as Map<String, dynamic>?)?['username'] as String?;
      }
      if (me is Map<String, dynamic>) return me['username'] as String?;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Find the featured series a single book belongs to. When [author] is
  /// known, candidate hits must share at least one author token.
  Future<HardcoverBookSeries?> findBookSeries(String title,
      {String? author}) async {
    try {
      final data = await _query(
        r'query Search($q: String!) { search(query: $q, query_type: "Book", per_page: 5) { results } }',
        {'q': title},
      );
      HardcoverBookSeries? best;
      var bestScore = 0;
      final wanted = title.toLowerCase().trim();
      for (final doc in _searchHits(data)) {
        final hitTitle =
            (doc['title'] as String? ?? '').toLowerCase().trim();
        if (hitTitle.isEmpty) continue;
        if (author != null &&
            author.isNotEmpty &&
            !_authorOverlap(_docAuthors(doc), author)) {
          continue;
        }
        int s;
        if (hitTitle == wanted) {
          s = 3;
        } else if (hitTitle.contains(wanted) || wanted.contains(hitTitle)) {
          s = 1;
        } else {
          continue;
        }
        final featured = doc['featured_series'] as Map<String, dynamic>?;
        final series = featured?['series'] as Map<String, dynamic>?;
        final name = series?['name'] as String? ?? '';
        final slug = series?['slug'] as String? ?? '';
        if (name.isEmpty || slug.isEmpty) continue;
        if (s > bestScore) {
          bestScore = s;
          best = HardcoverBookSeries(
            name: name,
            slug: slug,
            position: (featured?['position'] as num?)?.toDouble(),
          );
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }
}
