import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/auth_provider.dart';
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
/// "Find Missing Books" uses. Falls back to a raw ABB search when no Audible
/// series can be found, since that's still better than nothing.
class AbbSeriesView extends StatefulWidget {
  final String seriesName;
  final String? author;

  /// Skips Audible series lookup when the caller already has it (e.g. the
  /// Audible series sheet), going straight to [ApiService.discoverAudibleSeries].
  final String? seriesAsin;

  const AbbSeriesView({
    super.key,
    required this.seriesName,
    this.author,
    this.seriesAsin,
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
    // path re-running _loadViaAudible after a partial _loadViaAbbSearch (or
    // vice versa) and leaving stale positions from an abandoned attempt.
    _positions.clear();
    try {
      final asin = widget.seriesAsin ?? await _resolveSeriesAsin();
      if (asin != null && await _loadViaAudible(asin)) return;
    } catch (e) {
      debugPrint('[ABB] Audible-driven series load failed, falling back: $e');
    }
    await _loadViaAbbSearch();
  }

  /// Find the Audible series ASIN from just a name + optional author, the
  /// same technique `series_books_sheet.dart`'s series-lookup fallback uses
  /// (search Audible for a book, then check its Audnexus series field) -
  /// except there's no owned book to anchor on here, so the series name
  /// itself seeds the search. Because that anchor is weaker, matches are
  /// cross-checked by both series name (token-based, not raw substring - a
  /// short name like "War" would otherwise match "Warhammer" as a raw
  /// substring of the no-separator normalized string) and author before
  /// being accepted, to avoid a same-author-different-series false
  /// positive silently substituting an unrelated series' books.
  Future<String?> _resolveSeriesAsin() async {
    if (!mounted) return null;
    final api = context.read<AuthProvider>().apiService;
    if (api == null) return null;
    if (normalizeTitle(widget.seriesName).length < 4) return null;

    final results =
        await api.searchBooks(title: widget.seriesName, author: widget.author);
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
      final audnexus = await ApiService.getAudnexusBook(asin);
      if (audnexus == null) continue;
      for (final key in ['seriesPrimary', 'seriesSecondary']) {
        final s = audnexus[key] as Map<String, dynamic>?;
        final sAsin = s?['asin'] as String?;
        final sName = s?['name'] as String? ?? '';
        if (sAsin == null || sAsin.isEmpty) continue;
        if (normalizeTitle(sName).length < 4) continue;
        if (titlesMatch(widget.seriesName, sName)) return sAsin;
      }
    }
    return null;
  }

  /// Returns true once a non-empty result was resolved and state has been
  /// set. Returns false on any failure to find/resolve books via Audible -
  /// including a genuinely book-less Audible series - so the caller always
  /// falls back to the raw ABB search rather than showing an empty page.
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

    // Two different Audible candidates (e.g. a volume and an omnibus
    // covering it) can resolve to the same ABB post - dedupe by id so it
    // doesn't render twice, keeping whichever was resolved first.
    final seenIds = <String>{};
    final deduped = resolved.results.where((r) => seenIds.add(r.result.id));
    for (final r in deduped) {
      if (r.position != null) _positions[r.result.id] = r.position!;
    }

    if (!mounted) return true;
    setState(() {
      _items = _rankAndOrder(deduped.map((r) => r.result).toList());
      _partial = resolved.blocked;
      _loading = false;
    });
    return true;
  }

  /// Degraded fallback for when no Audible series could be found at all:
  /// the original raw-ABB-search-and-parse approach.
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
