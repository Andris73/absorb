import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/discover/abb_client.dart';
import '../../services/discover/abb_models.dart';
import '../../services/discover/hardcover_client.dart';
import '../../services/discover/title_matching.dart';
import '../../services/player_settings.dart';
import 'abb_book_detail_view.dart';
import 'abb_cover.dart';

/// Books in a series, resolved via ABB search and best-effort ordered and
/// described via the Hardcover roster when a token is configured.
class AbbSeriesView extends StatefulWidget {
  final String seriesName;
  final String? author;

  const AbbSeriesView({super.key, required this.seriesName, this.author});

  @override
  State<AbbSeriesView> createState() => _AbbSeriesViewState();
}

class _AbbSeriesViewState extends State<AbbSeriesView> {
  List<AbbSearchResult> _items = const [];
  final _positions = <String, double>{};
  String? _description;
  bool _fullyOrdered = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final baseUrl = (await PlayerSettings.getAbbServerUrl()).trim();
    final token = (await PlayerSettings.getHardcoverApiToken()).trim();
    final abb = AbbClient(baseUrl);
    try {
      var results = <AbbSearchResult>[];
      try {
        results = await abb.searchAlternate(widget.seriesName);
      } catch (_) {}
      if (results.isEmpty) results = await abb.search(widget.seriesName);

      final wanted = widget.seriesName.toLowerCase();
      results = results
          .where((r) => coreTitle(r.title).toLowerCase().contains(wanted))
          .toList();
      final seenTitles = <String>{};
      results = results
          .where((r) => seenTitles.add(normalizeTitle(coreTitle(r.title))))
          .toList();

      for (final r in results) {
        final parsed = AbbClient.parseSeriesFromTitle(r.title);
        if (parsed != null) _positions[r.id] = parsed.number;
      }

      if (token.isNotEmpty) await _enrichFromHardcover(token, results);

      results.sort((a, b) {
        final pa = _positions[a.id];
        final pb = _positions[b.id];
        if (pa != null && pb != null) return pa.compareTo(pb);
        if (pa != null) return -1;
        if (pb != null) return 1;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _items = results;
        _fullyOrdered = results.isNotEmpty &&
            results.every((r) => _positions.containsKey(r.id));
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

  /// Replace the description and reorder by roster positions, matching
  /// roster entries to ABB titles by normalized-title containment
  /// (min normalized length 4, longest match wins).
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
    } catch (_) {
      // Enrichment is best-effort; ABB results stand on their own.
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
      body = const Center(child: CircularProgressIndicator());
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
