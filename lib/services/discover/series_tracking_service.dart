/// "New in series" pipeline: find books missing from series the user is
/// actively listening to, then resolve them on AudiobookBay.
///
/// Data flow: ABS progress -> owned books per series (position/year via
/// Audnexus when possible) -> Hardcover roster -> missing diff -> ABB
/// resolution -> explicit/ownership filtering.
library;

import 'dart:math';

import '../api_service.dart';
import '../player_settings.dart';
import 'abb_client.dart';
import 'abb_models.dart';
import 'audnexus_client.dart';
import 'hardcover_client.dart';
import 'ownership_service.dart';
import 'title_matching.dart';

class _ActiveSeries {
  final String id;
  final String name;
  final String author;
  const _ActiveSeries(this.id, this.name, this.author);
}

class _Candidate {
  final String seriesName;
  final String title;
  final String author;

  /// Set when the roster gave no usable position; ABB hits older than this
  /// are rejected as re-releases of already-owned books.
  final int? minYear;
  const _Candidate(this.seriesName, this.title, this.author, this.minYear);
}

/// Computes ABB results for tracked-series gaps. Results are cached in
/// memory for an hour (Hardcover allows 60 req/min) and only when non-empty.
class SeriesTrackingService {
  SeriesTrackingService._();
  static final SeriesTrackingService instance = SeriesTrackingService._();

  (DateTime, List<AbbSearchResult>, String)? _cache;

  /// Clear the cached result so the next call recomputes.
  void invalidate() => _cache = null;

  /// Returns the missing-book ABB results plus a human-readable trace of
  /// per-stage counts (shown in the shelf's empty state for diagnostics).
  Future<(List<AbbSearchResult>, String)> missingFromTrackedSeries({
    required ApiService api,
    required String libraryId,
    required String hardcoverToken,
    required String abbBaseUrl,
    int maxSeries = 8,
    int maxResults = 18,
  }) async {
    final cached = _cache;
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(hours: 1)) {
      return (cached.$2, cached.$3);
    }
    if (hardcoverToken.trim().isEmpty) {
      return (const <AbbSearchResult>[], 'hardcover token not set');
    }
    if (abbBaseUrl.trim().isEmpty) {
      return (const <AbbSearchResult>[], 'abb server not set');
    }

    final hardcover = HardcoverClient(hardcoverToken);
    final audnexus = AudnexusClient();
    final abb = AbbClient(abbBaseUrl);
    try {
      final active = await _activeSeries(api, libraryId, maxSeries);
      var ownedCount = 0;
      var rosterCount = 0;
      var missingCount = 0;
      final candidates = <_Candidate>[];
      final seenTitles = <String>{};

      for (final series in active) {
        if (candidates.length >= maxResults) break;
        final owned = await _ownedBooks(api, libraryId, series, audnexus);
        ownedCount += owned.titles.length;

        final slug =
            await hardcover.searchSeriesSlug(series.name, author: series.author);
        if (slug == null) continue;
        final roster = await hardcover.roster(slug);
        if (roster == null || roster.books.isEmpty) continue;

        // Editions duplicate roster entries per position.
        final dedupedRoster = <String, HardcoverRosterEntry>{};
        for (final entry in roster.books) {
          dedupedRoster.putIfAbsent(normalizeTitle(entry.title), () => entry);
        }
        rosterCount += dedupedRoster.length;

        for (final entry in dedupedRoster.values) {
          final n = normalizeTitle(entry.title);
          if (n.length < 4) continue;
          final isOwned = owned.titles
              .any((o) => o == n || o.contains(n) || n.contains(o));
          if (isOwned) continue;
          missingCount++;
          final pos = entry.position;
          // x.5 novellas rarely exist as standalone audiobooks.
          if (pos != null && pos != pos.roundToDouble()) continue;
          int? minYear;
          if (pos != null) {
            if (owned.maxPosition != null && pos <= owned.maxPosition!) {
              continue;
            }
          } else {
            minYear = owned.maxYear;
          }
          if (!seenTitles.add(n)) continue;
          candidates.add(
              _Candidate(series.name, entry.title, series.author, minYear));
          if (candidates.length >= maxResults) break;
        }
      }

      // ABB dislikes concurrent scraping (Cloudflare), so resolve serially.
      var abbHits = 0;
      var results = <AbbSearchResult>[];
      for (final c in candidates) {
        final hit = await _resolveOnAbb(abb, c);
        if (hit != null) {
          abbHits++;
          results.add(hit);
        }
      }

      if (await PlayerSettings.getHideExplicitContent()) {
        results = results.where((r) => !r.explicit).toList();
      }
      if (await PlayerSettings.getHideOwnedTitles()) {
        results = await LibraryOwnershipService()
            .filterUnowned(results, api, libraryId);
      }
      final seenIds = <String>{};
      results = results.where((r) => seenIds.add(r.id)).toList();

      final trace = 'series:${active.length} owned:$ownedCount '
          'roster:$rosterCount missing:$missingCount '
          'candidates:${candidates.length} abb:$abbHits '
          'final:${results.length}';
      if (results.isNotEmpty) {
        _cache = (DateTime.now(), results, trace);
      }
      return (results, trace);
    } finally {
      abb.dispose();
      audnexus.dispose();
      hardcover.dispose();
    }
  }

  /// Series the user is actively listening to, from the personalized view's
  /// in-progress and recently-finished shelves. Minified entities often lack
  /// series metadata, so items are resolved to full library items on demand.
  Future<List<_ActiveSeries>> _activeSeries(
      ApiService api, String libraryId, int maxSeries) async {
    final shelves = await api.getPersonalizedView(libraryId);
    final items = <Map<String, dynamic>>[];
    for (final shelf in shelves.whereType<Map<String, dynamic>>()) {
      final id = shelf['id'] as String? ?? '';
      if (id != 'continue-listening' && id != 'listen-again') continue;
      items.addAll((shelf['entities'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .where((e) => (e['mediaType'] as String? ?? 'book') == 'book'));
    }

    final out = <_ActiveSeries>[];
    final seenNames = <String>{};
    var fetches = 0;
    for (final item in items) {
      if (out.length >= maxSeries) break;
      var series = _firstSeries(item);
      if (series == null && fetches < 20) {
        fetches++;
        final itemId = item['id'] as String? ?? '';
        if (itemId.isEmpty) continue;
        final full = await api.getLibraryItem(itemId);
        if (full != null) series = _firstSeries(full);
      }
      if (series == null) continue;
      if (!seenNames.add(series.name.toLowerCase())) continue;
      out.add(series);
    }
    return out;
  }

  _ActiveSeries? _firstSeries(Map<String, dynamic> item) {
    final media = item['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final author = metadata['authorName'] as String? ??
        ((metadata['authors'] as List<dynamic>?) ?? [])
            .whereType<Map<String, dynamic>>()
            .map((a) => a['name'] as String? ?? '')
            .where((n) => n.isNotEmpty)
            .join(', ');
    final series = metadata['series'];
    Map<String, dynamic>? first;
    if (series is List && series.isNotEmpty) {
      first = series.first as Map<String, dynamic>?;
    } else if (series is Map<String, dynamic>) {
      first = series;
    }
    final id = first?['id'] as String? ?? '';
    final name = first?['name'] as String? ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    return _ActiveSeries(id, name, author);
  }

  /// Owned titles (normalized) plus the highest known position and
  /// published year across the owned books. Audnexus (by ASIN) wins over
  /// ABS sequence/year when it resolves.
  Future<({Set<String> titles, double? maxPosition, int? maxYear})>
      _ownedBooks(ApiService api, String libraryId, _ActiveSeries series,
          AudnexusClient audnexus) async {
    final items = await api.getBooksBySeries(libraryId, series.id, limit: 100);
    final titles = <String>{};
    double? maxPosition;
    int? maxYear;
    for (final item in items.whereType<Map<String, dynamic>>()) {
      final media = item['media'] as Map<String, dynamic>? ?? {};
      final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
      final title = metadata['title'] as String? ?? '';
      if (title.isNotEmpty) titles.add(normalizeTitle(title));

      double? position;
      int? year;
      final asin = metadata['asin'] as String? ?? '';
      if (asin.isNotEmpty) {
        final book = await audnexus.book(asin);
        if (book != null) {
          year = book.year;
          for (final s in [book.seriesPrimary, book.seriesSecondary]) {
            if (s != null &&
                s.name.toLowerCase() == series.name.toLowerCase()) {
              position = s.position;
              break;
            }
          }
        }
      }
      if (position == null) {
        final seriesMeta = metadata['series'];
        final sequence = seriesMeta is Map<String, dynamic>
            ? seriesMeta['sequence'] as String? ?? ''
            : '';
        position = double.tryParse(sequence);
      }
      year ??= int.tryParse('${metadata['publishedYear'] ?? ''}');

      if (position != null) maxPosition = max(maxPosition ?? 0, position);
      if (year != null) maxYear = max(maxYear ?? 0, year);
    }
    return (titles: titles, maxPosition: maxPosition, maxYear: maxYear);
  }

  Future<AbbSearchResult?> _resolveOnAbb(AbbClient abb, _Candidate c) async {
    final query = _abbQuery(c);
    var results = <AbbSearchResult>[];
    try {
      results = await abb.searchAlternate(query);
    } catch (_) {}
    if (results.isEmpty) {
      try {
        results = await abb.search(query);
      } catch (_) {}
    }

    AbbSearchResult? best;
    var bestScore = 0.0;
    for (final r in results) {
      if (c.minYear != null && r.year != null && r.year! < c.minYear!) {
        continue;
      }
      final s = score(c.title, r.title);
      if (s > bestScore) {
        bestScore = s;
        best = r;
      }
    }
    return bestScore >= 0.75 ? best : null;
  }

  /// Deduped, diacritic-folded, punctuation-free lowercase words of series
  /// name + title + author, in that order.
  String _abbQuery(_Candidate c) {
    final words = <String>[];
    final seen = <String>{};
    for (final part in [c.seriesName, c.title, c.author]) {
      final folded = foldDiacritics(part.toLowerCase())
          .replaceAll(RegExp(r'[^a-z0-9]'), ' ');
      for (final w in folded.split(RegExp(r'\s+'))) {
        if (w.isEmpty || !seen.add(w)) continue;
        words.add(w);
      }
    }
    return words.join(' ');
  }
}
