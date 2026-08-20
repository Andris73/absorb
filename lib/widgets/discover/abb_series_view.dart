import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../services/api_service.dart';
import '../../services/discover/abb_client.dart';
import '../../services/discover/abb_models.dart';
import '../../services/discover/hardcover_client.dart';
import '../../services/discover/series_tracking_service.dart';
import '../../services/discover/title_matching.dart';
import '../../services/player_settings.dart';
import 'abb_book_detail_view.dart';
import 'abb_cover.dart';

/// Books in a series. Primarily resolved from Audible's own series listing
/// (authoritative book order and titles) matched against ABB one book at a
/// time via [SeriesTrackingService.resolveSeriesBooks] - the same resolver
/// "Find Missing Books" uses. The Audible series ASIN itself is found first
/// via a book the user already owns in this series (an approximation of the
/// technique the Library-side "Find on Audible" flow uses - see
/// [_resolveSeriesAsinFromLibrary]'s doc for how it differs), then falls
/// back to a blind Audible search anchored on a real per-book title when the
/// user owns nothing in the series yet. When Audible doesn't carry the
/// series at all, falls back to Hardcover's roster as a second
/// authoritative-ish source via the same resolver, then finally to a raw
/// ABB search, since that's still better than nothing.
class AbbSeriesView extends StatefulWidget {
  final String seriesName;
  final String? author;

  /// Skips Audible series lookup when the caller already has it (e.g. the
  /// Audible series sheet), going straight to [ApiService.discoverAudibleSeries].
  final String? seriesAsin;

  /// A specific book's title in this series (e.g. the ABB post the user was
  /// looking at), used to anchor the Audible search in [_resolveSeriesAsin].
  /// The bare series name usually isn't itself a real Audible book title -
  /// "Lout of Count's Family" finds nothing, but "Lout of Count's Family,
  /// Vol. 4" does - so a real per-book title searches far more reliably.
  final String? anchorTitle;

  const AbbSeriesView({
    super.key,
    required this.seriesName,
    this.author,
    this.seriesAsin,
    this.anchorTitle,
  });

  @override
  State<AbbSeriesView> createState() => _AbbSeriesViewState();
}

class _AbbSeriesViewState extends State<AbbSeriesView> {
  List<AbbSearchResult> _items = const [];
  final _positions = <String, double>{};
  String? _description;
  bool _fullyOrdered = false;
  bool _loading = true;
  bool _partial = false;
  String? _error;
  int _resolveDone = 0;
  int _resolveTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Cleared up front, not just per-path: defends against a future retry
    // path re-running an earlier tier after a partial later one (or vice
    // versa) and leaving stale state from an abandoned attempt.
    _positions.clear();
    _description = null;
    _resolveDone = 0;
    _resolveTotal = 0;
    try {
      String? asin = widget.seriesAsin;
      // Each resolution attempt gets its own try/catch: a failure in the
      // library-owned-book lookup (e.g. an unexpected search response shape)
      // must not deny the anchor-title Audible search a chance to run too -
      // they're independent techniques for finding the same ASIN.
      if (asin == null) {
        try {
          asin = await _resolveSeriesAsinFromLibrary();
        } catch (e) {
          debugPrint('[ABB] Library-owned-book ASIN lookup failed: $e');
        }
      }
      asin ??= await _resolveSeriesAsin();
      if (asin != null && await _loadViaAudible(asin)) return;
    } catch (e) {
      debugPrint('[ABB] Audible-driven series load failed, falling back: $e');
    }
    // Many series ABB hosts (web-novel/manhwa audiobooks in particular)
    // aren't in Audible's catalog at all, so the above finds nothing. Try
    // Hardcover's roster as a second authoritative-ish source before giving
    // up to the raw ABB search, which struggles to tell "Vol. 4" from
    // "Vol. 6" apart from a bare series-name query.
    try {
      if (await _loadViaHardcover()) return;
    } catch (e) {
      debugPrint('[ABB] Hardcover-driven series load failed, falling back: $e');
    }
    await _loadViaAbbSearch();
  }

  /// Find the Audible series ASIN from a name + optional author, the same
  /// technique `series_books_sheet.dart`'s series-lookup fallback uses
  /// (search Audible for a book, then check its Audnexus series field).
  /// Prefers [widget.anchorTitle] (a real per-book title) as the search
  /// query when given, since the bare series name usually isn't itself a
  /// real Audible title and finds nothing - "Lout of Count's Family" is not
  /// a book, but "Lout of Count's Family, Vol. 4" is. Falls back to the
  /// series name when no anchor is available. Because that fallback anchor
  /// is weaker, matches are cross-checked by both series name (token-based,
  /// not raw substring - a short name like "War" would otherwise match
  /// "Warhammer" as a raw substring of the no-separator normalized string)
  /// and author before being accepted, to avoid a same-author-different-
  /// series false positive silently substituting an unrelated series' books.
  Future<String?> _resolveSeriesAsin() async {
    if (!mounted) return null;
    final api = context.read<AuthProvider>().apiService;
    if (api == null) return null;
    // Guards widget.seriesName unconditionally, independent of the anchor
    // below: this is what stops the titlesMatch cross-check further down
    // from accepting a short/generic series name as a false positive (the
    // "War" vs "Warhammer" case) - an anchor being long enough to search on
    // doesn't make a short series name any safer to cross-check against.
    if (normalizeTitle(widget.seriesName).length < 4) return null;

    final anchor = widget.anchorTitle?.trim() ?? '';
    final searchTitle =
        normalizeTitle(anchor).length >= 4 ? anchor : widget.seriesName;

    // Same region the user configured for Find Missing Books / _loadViaAudible
    // - without this, searchBooks/getAudnexusBook fall back to a device-locale
    // region that can differ from the user's actual Audible marketplace and
    // silently return nothing (or the wrong catalog's ASIN) for region-specific
    // titles.
    final region = await PlayerSettings.getAudibleRegion();
    final regionOverride = region.isNotEmpty ? region : null;

    final results = await api.searchBooks(
        title: searchTitle, author: widget.author, region: regionOverride);
    for (final r in results) {
      final asin = r['asin'] as String? ?? '';
      if (asin.isEmpty) continue;
      final candidateAuthor =
          (r['author'] ?? r['authorName']) as String? ?? '';
      if (widget.author != null &&
          widget.author!.isNotEmpty &&
          !authorsMatch(widget.author!, candidateAuthor)) {
        continue;
      }
      final sAsin = await _matchSeriesAsinViaAudnexus(asin, regionOverride);
      if (sAsin != null) return sAsin;
    }
    return null;
  }

  /// Find the Audible series ASIN via a book the user already owns in this
  /// series: search the ABS library (not Audible) for the series name, then
  /// check each hit's own `asin` metadata against Audnexus for a
  /// `seriesPrimary`/`seriesSecondary` match. This is a full-text-search
  /// approximation of what `series_books_sheet.dart`'s "Find on Audible"
  /// does with a series it already has the real, ID-keyed book list for -
  /// Discover has no such series ID to work with, so it substitutes ABS's
  /// own search endpoint and leans on the series-name + author cross-checks
  /// below instead. Tried before [_resolveSeriesAsin] because a real owned
  /// ASIN, when found, is far more reliable than blindly searching Audible's
  /// catalog by title. Returns null (falls through to [_resolveSeriesAsin])
  /// when the user doesn't own anything matching in this series yet, same
  /// as any other lookup miss. Only checks the currently-selected library -
  /// a copy owned in a different library on the same server won't be found.
  Future<String?> _resolveSeriesAsinFromLibrary() async {
    if (!mounted) return null;
    if (normalizeTitle(widget.seriesName).length < 4) return null;

    final libraryId = context.read<LibraryProvider>().selectedLibraryId;
    final api = context.read<AuthProvider>().apiService;
    if (libraryId == null || api == null) return null;

    // Short timeout: this tier runs on every View Series open, and the
    // common case for a Discover-tab series the user is browsing (rather
    // than already tracking) is owning nothing in it at all, so a slow
    // server shouldn't stall the anchor-title fallback below by very long.
    final search = await api.searchLibrary(libraryId, widget.seriesName,
        timeout: const Duration(seconds: 10));
    final books = search?['book'] as List<dynamic>? ?? [];
    if (books.isEmpty) return null;

    final region = await PlayerSettings.getAudibleRegion();
    final regionOverride = region.isNotEmpty ? region : null;

    for (final b in books) {
      if (b is! Map<String, dynamic>) continue;
      final libraryItem = b['libraryItem'] as Map<String, dynamic>? ?? {};
      final media = libraryItem['media'] as Map<String, dynamic>? ?? {};
      final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
      final asin = metadata['asin'] as String? ?? '';
      if (asin.isEmpty) continue;

      final seriesRaw = metadata['series'];
      final seriesList = seriesRaw is List
          ? seriesRaw.whereType<Map<String, dynamic>>()
          : seriesRaw is Map<String, dynamic>
              ? [seriesRaw]
              : const <Map<String, dynamic>>[];
      final matchesSeries = seriesList.any((s) {
        final name = s['name'] as String? ?? '';
        return normalizeTitle(name).length >= 4 &&
            titlesMatch(widget.seriesName, name);
      });
      if (!matchesSeries) continue;

      if (widget.author != null && widget.author!.isNotEmpty) {
        final bookAuthor = metadata['authorName'] as String? ?? '';
        if (!authorsMatch(widget.author!, bookAuthor)) continue;
      }

      final sAsin = await _matchSeriesAsinViaAudnexus(asin, regionOverride);
      if (sAsin != null) return sAsin;
    }
    return null;
  }

  /// Shared tail of both ASIN-resolution tiers above: given a real book
  /// ASIN, fetch Audnexus and return the series ASIN if `seriesPrimary` or
  /// `seriesSecondary` names match [widget.seriesName].
  Future<String?> _matchSeriesAsinViaAudnexus(
      String bookAsin, String? region) async {
    final audnexus =
        await ApiService.getAudnexusBook(bookAsin, region: region);
    if (audnexus == null) return null;
    for (final key in ['seriesPrimary', 'seriesSecondary']) {
      final s = audnexus[key] as Map<String, dynamic>?;
      final sAsin = s?['asin'] as String?;
      final sName = s?['name'] as String? ?? '';
      if (sAsin == null || sAsin.isEmpty) continue;
      if (normalizeTitle(sName).length < 4) continue;
      if (titlesMatch(widget.seriesName, sName)) return sAsin;
    }
    return null;
  }

  /// Returns true once a non-empty result was resolved and state has been
  /// set. Returns false on any failure to find/resolve books via Audible -
  /// including a genuinely book-less Audible series - so the caller always
  /// falls through to the next tier rather than showing an empty page.
  Future<bool> _loadViaAudible(String seriesAsin) async {
    final region = await PlayerSettings.getAudibleRegion();
    final books = await ApiService.discoverAudibleSeries(seriesAsin,
        region: region.isNotEmpty ? region : null);
    if (books.isEmpty) return false;

    final candidates = <({String title, String author, double? position})>[];
    for (final b in books) {
      final title = b['title'] as String? ?? '';
      if (title.isEmpty) continue;
      final authors = b['authors'] as String? ?? '';
      final leadAuthor = authors.split(',').first.trim();
      final position = double.tryParse(b['sequence']?.toString() ?? '');
      candidates.add((
        title: title,
        author: leadAuthor.isNotEmpty ? leadAuthor : (widget.author ?? ''),
        position: position,
      ));
    }
    return _resolveAndShow(candidates);
  }

  /// Second-tier source when the series isn't in Audible's catalog: resolve
  /// each book on ABB individually from Hardcover's roster instead, via the
  /// same [SeriesTrackingService.resolveSeriesBooks] resolver as Audible.
  /// Hardcover's roster gives titles + positions but no per-book author, so
  /// every candidate is anchored on the series' own author for all entries -
  /// a wrong/absent author can't single out one bad volume here the way it
  /// can for Audible, since it applies uniformly to the whole series.
  Future<bool> _loadViaHardcover() async {
    // Reset explicitly rather than relying on _load()'s one-time clear: if
    // the Audible tier ticked this up before failing, it'd otherwise sit
    // frozen at Audible's last count through this tier's own network calls.
    if (mounted) {
      setState(() {
        _resolveDone = 0;
        _resolveTotal = 0;
      });
    }

    final token = (await PlayerSettings.getHardcoverApiToken()).trim();
    if (token.isEmpty) return false;

    final hc = HardcoverClient(token);
    HardcoverRoster? roster;
    try {
      final slug =
          await hc.searchSeriesSlug(widget.seriesName, author: widget.author);
      if (slug == null) return false;
      roster = await hc.roster(slug);
    } finally {
      hc.dispose();
    }
    if (roster == null || roster.books.isEmpty) return false;

    // Editions duplicate roster entries per position, same as
    // missingFromTrackedSeries's roster handling.
    final dedupedRoster = <String, HardcoverRosterEntry>{};
    for (final entry in roster.books) {
      if (entry.title.isEmpty) continue;
      dedupedRoster.putIfAbsent(normalizeTitle(entry.title), () => entry);
    }

    final candidates = <({String title, String author, double? position})>[
      for (final entry in dedupedRoster.values)
        (
          title: entry.title,
          author: widget.author ?? '',
          position: entry.position,
        ),
    ];
    return _resolveAndShow(candidates, description: roster.description);
  }

  /// Shared tail of both source-tier loaders: resolve [candidates] against
  /// ABB one at a time, dedupe, populate `_positions`, and render. Returns
  /// false with state untouched (aside from progress ticks) when there's
  /// nothing to resolve or resolution found nothing, so the caller falls
  /// through to the next tier instead of showing an empty page.
  Future<bool> _resolveAndShow(
    List<({String title, String author, double? position})> candidates, {
    String? description,
  }) async {
    if (candidates.isEmpty) return false;
    if (!mounted) return false;

    final abbUrl = (await PlayerSettings.getAbbServerUrl()).trim();
    if (abbUrl.isEmpty) return false;

    final resolved = await SeriesTrackingService.instance.resolveSeriesBooks(
      abbBaseUrl: abbUrl,
      seriesName: widget.seriesName,
      books: candidates,
      isCancelled: () => !mounted,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _resolveDone = done;
          _resolveTotal = total;
        });
      },
    );
    if (resolved.results.isEmpty) return false;

    // Two different candidates (e.g. a volume and an omnibus covering it,
    // or an edition duplicate) can resolve to the same ABB post - dedupe by
    // id so it doesn't render twice, keeping whichever was resolved first.
    final seenIds = <String>{};
    final deduped = resolved.results.where((r) => seenIds.add(r.result.id));
    for (final r in deduped) {
      if (r.position != null) _positions[r.result.id] = r.position!;
    }

    if (!mounted) return true;
    setState(() {
      _items = _rankAndOrder(deduped.map((r) => r.result).toList());
      if (description != null) _description = description;
      _partial = resolved.blocked;
      _loading = false;
    });
    return true;
  }

  /// Degraded fallback for when no Audible or Hardcover series could be
  /// found at all: the original raw-ABB-search-and-parse approach.
  Future<void> _loadViaAbbSearch() async {
    if (mounted) {
      setState(() {
        _resolveDone = 0;
        _resolveTotal = 0;
      });
    }
    final baseUrl = (await PlayerSettings.getAbbServerUrl()).trim();
    final token = (await PlayerSettings.getHardcoverApiToken()).trim();
    final abb = AbbClient(baseUrl);
    try {
      var results = <AbbSearchResult>[];
      try {
        results = await abb.searchAlternate(widget.seriesName);
      } catch (e) {
        debugPrint('[ABB] searchAlternate failed for series listing: $e');
      }
      if (results.isEmpty) results = await abb.search(widget.seriesName);

      final wanted = widget.seriesName.toLowerCase();
      results = results
          .where((r) => coreTitle(r.title).toLowerCase().contains(wanted))
          .toList();

      // Parsed before deduping: coreTitle alone can't tell "Vol. 4" from
      // "Vol. 6" apart, only the digit does.
      final volumeOf = <String, double?>{
        for (final r in results)
          r.id: AbbClient.parseSeriesFromTitle(r.title)?.number,
      };

      // Dedupe exact re-postings of the same book: same noise-stripped core
      // title (bracket/edition text ABB posters vary between re-uploads)
      // AND same volume number, so different volumes never collapse.
      final seenTitles = <String>{};
      results = results
          .where((r) => seenTitles
              .add('${normalizeTitle(coreTitle(r.title))}|${volumeOf[r.id]}'))
          .toList();

      for (final r in results) {
        final n = volumeOf[r.id];
        if (n != null) _positions[r.id] = n;
      }

      if (token.isNotEmpty) await _enrichFromHardcover(token, results);

      if (!mounted) return;
      setState(() {
        _items = _rankAndOrder(results);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } finally {
      abb.dispose();
    }
  }

  /// Sorts by known position (ABB-parsed volume, Audible sequence, or
  /// Hardcover roster guess, whichever this state's `_positions` holds for
  /// each result) and sets `_fullyOrdered` accordingly. Shared by both load
  /// paths so they can't drift into two different orderings over time.
  List<AbbSearchResult> _rankAndOrder(List<AbbSearchResult> results) {
    final sorted = results.toList()
      ..sort((a, b) {
        final pa = _positions[a.id];
        final pb = _positions[b.id];
        if (pa != null && pb != null) return pa.compareTo(pb);
        if (pa != null) return -1;
        if (pb != null) return 1;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    _fullyOrdered =
        sorted.isNotEmpty && sorted.every((r) => _positions.containsKey(r.id));
    return sorted;
  }

  /// Replace the description and reorder by roster positions, matching
  /// roster entries to ABB titles by normalized-title containment
  /// (min normalized length 4, longest match wins). Only fills in results
  /// ABB's own title didn't give a volume number for - a roster guess must
  /// never overwrite an already-parsed one, or every volume in the series
  /// would risk collapsing onto whichever roster entry matches best.
  ///
  /// Only reached when [_loadViaHardcover] already gave up (no token, no
  /// slug match, or ABB resolution came up empty), so this re-fetches the
  /// same roster in that last case. Left as-is rather than threading a
  /// pre-fetched roster through: Hardcover's rate limit is generous (60
  /// req/min) and the raw-search fallback is already the degraded path.
  Future<void> _enrichFromHardcover(
      String token, List<AbbSearchResult> results) async {
    final hc = HardcoverClient(token);
    try {
      final slug = await hc.searchSeriesSlug(widget.seriesName,
          author: widget.author);
      if (slug == null) return;
      final roster = await hc.roster(slug);
      if (roster == null) return;
      _description = roster.description;
      for (final r in results) {
        if (_positions.containsKey(r.id)) continue;
        final n = normalizeTitle(coreTitle(r.title));
        double? best;
        var bestLen = 0;
        for (final entry in roster.books) {
          if (entry.position == null) continue;
          final ne = normalizeTitle(entry.title);
          if (ne.length < 4 || ne.length <= bestLen) continue;
          if (n.contains(ne) || ne.contains(n)) {
            best = entry.position;
            bestLen = ne.length;
          }
        }
        if (best != null) _positions[r.id] = best;
      }
    } catch (e) {
      // Enrichment is best-effort; ABB results stand on their own.
      debugPrint('[ABB] Hardcover series enrichment failed: $e');
    } finally {
      hc.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;

    Widget body;
    if (_loading) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (_resolveTotal > 0) ...[
              const SizedBox(height: 16),
              Text(
                l.discoverResolvingSeries(_resolveDone, _resolveTotal),
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ),
      );
    } else if (_error != null && _items.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l.discoverLoadFailed(_error!),
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      );
    } else if (_items.isEmpty) {
      body = Center(
        child: Text(
          l.discoverNoBooks,
          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        physics: const BouncingScrollPhysics(),
        children: [
          if (_description != null && _description!.isNotEmpty) ...[
            Text(
              l.discoverAbout,
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _description!,
              style: tt.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.85),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
          ],
          Text(
            _fullyOrdered ? l.discoverSeriesBooksIn : l.discoverSeriesMoreIn,
            style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (_partial) ...[
            const SizedBox(height: 4),
            Text(
              l.discoverSeriesPartial,
              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
          for (final r in _items) _row(context, r, cs, tt),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.seriesName)),
      body: body,
    );
  }

  Widget _row(BuildContext context, AbbSearchResult r, ColorScheme cs,
      TextTheme tt) {
    final pos = _positions[r.id];
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AbbBookDetailView(result: r)),
      ),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              height: 64,
              child: AbbCover(url: r.coverUrl, radius: 6),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                  ),
                  if (r.author != null)
                    Text(
                      r.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            if (pos != null) ...[
              const SizedBox(width: 8),
              Text(
                '#${pos == pos.roundToDouble() ? pos.toInt() : pos}',
                style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
