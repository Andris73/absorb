import 'package:flutter/foundation.dart';
import '../utils/fuzzy_search.dart';
import 'api_service.dart';

/// A scored search result: the raw library item plus whether it matched on the
/// title (so callers can keep a "Books" section to title hits).
class BookSearchHit {
  final Map<String, dynamic> item;
  final double score;
  final bool titleMatch;
  const BookSearchHit(this.item, this.score, this.titleMatch);
}

class _Indexed {
  final Map<String, dynamic> item;
  final String normTitle;
  final List<String> titleTokens; // title + subtitle words
  final List<String> authorTokens;
  final List<String> seriesTokens;
  const _Indexed(this.item, this.normTitle, this.titleTokens, this.authorTokens,
      this.seriesTokens);
}

/// In-memory, per-library index of all book items, used for lenient client-side
/// search (out-of-order words, punctuation, typos) that the strict server
/// `/search` endpoint can't do. Built once per library per session.
class BookSearchIndex {
  BookSearchIndex._();
  static final BookSearchIndex instance = BookSearchIndex._();
  factory BookSearchIndex() => instance;

  final Map<String, List<_Indexed>> _cache = {};
  final Map<String, Future<void>> _inFlight = {};

  bool isReady(String libraryId) => _cache.containsKey(libraryId);

  /// Drop everything (call on logout / account switch so a reused libraryId
  /// can't serve another account's items).
  void clear() {
    _cache.clear();
    _inFlight.clear();
  }

  /// Build the index for [libraryId] if not already cached. Concurrent callers
  /// share the same in-flight build. A failed fetch is not cached, so the next
  /// call retries.
  Future<void> ensureIndex(ApiService api, String libraryId) {
    if (_cache.containsKey(libraryId)) return Future.value();
    final existing = _inFlight[libraryId];
    if (existing != null) return existing;
    final f = _build(api, libraryId);
    _inFlight[libraryId] = f;
    return f.whenComplete(() => _inFlight.remove(libraryId));
  }

  Future<void> _build(ApiService api, String libraryId) async {
    const pageSize = 100;
    const maxPages = 100; // ~10k items safety cap

    final first =
        await api.getLibraryItems(libraryId, page: 0, limit: pageSize);
    if (first == null) return; // offline / error: leave uncached for retry
    final items = <Map<String, dynamic>>[];
    _collect(first, items);
    final total = (first['total'] as num?)?.toInt() ?? items.length;
    final pages = (total / pageSize).ceil();
    final lastPage = pages > maxPages ? maxPages : pages;

    if (lastPage > 1) {
      final futures = <Future<Map<String, dynamic>?>>[
        for (var p = 1; p < lastPage; p++)
          api.getLibraryItems(libraryId, page: p, limit: pageSize),
      ];
      for (final pd in await Future.wait(futures)) {
        if (pd != null) _collect(pd, items);
      }
    }
    if (pages > maxPages) {
      debugPrint('[BookSearchIndex] $libraryId has $total items; indexed first '
          '${maxPages * pageSize}. Search may miss the rest.');
    }
    _cache[libraryId] = items.map(_indexItem).toList();
  }

  void _collect(Map<String, dynamic> page, List<Map<String, dynamic>> out) {
    final results = page['results'] as List<dynamic>? ?? [];
    for (final r in results) {
      final m = (r['libraryItem'] ?? r);
      if (m is Map<String, dynamic>) out.add(m);
    }
  }

  _Indexed _indexItem(Map<String, dynamic> item) {
    final media = item['media'] as Map<String, dynamic>? ?? {};
    final md = media['metadata'] as Map<String, dynamic>? ?? {};
    final title = md['title'] as String? ?? '';
    final subtitle = md['subtitle'] as String? ?? '';
    final author = md['authorName'] as String? ?? '';
    final series = md['seriesName'] as String? ?? '';
    final normTitle = normalizeForSearch(title);
    final titleTokens = tokenize(
        subtitle.isEmpty ? normTitle : '$normTitle ${normalizeForSearch(subtitle)}'.trim());
    return _Indexed(
      item,
      normTitle,
      titleTokens,
      tokenize(normalizeForSearch(author)),
      tokenize(normalizeForSearch(series)),
    );
  }

  List<BookSearchHit> search(String libraryId, String query, {int limit = 40}) {
    final idx = _cache[libraryId];
    if (idx == null) return const [];
    final normQuery = normalizeForSearch(query);
    final qTokens = tokenize(normQuery);
    if (qTokens.isEmpty) return const [];
    final hits = <BookSearchHit>[];
    for (final e in idx) {
      final r = scoreTokens(
        qTokens: qTokens,
        normQuery: normQuery,
        normTitle: e.normTitle,
        titleTokens: e.titleTokens,
        authorTokens: e.authorTokens,
        seriesTokens: e.seriesTokens,
      );
      if (r != null) hits.add(BookSearchHit(e.item, r.score, r.titleMatch));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }
}
