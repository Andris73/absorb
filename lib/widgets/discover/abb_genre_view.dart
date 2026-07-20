import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../services/discover/abb_client.dart';
import '../../services/discover/abb_models.dart';
import '../../services/discover/ownership_service.dart';
import '../../services/player_settings.dart';
import 'abb_book_detail_view.dart';
import 'abb_cover.dart';

/// Endless-scroll grid of an ABB genre's listing pages.
class AbbGenreView extends StatefulWidget {
  final AbbGenre genre;
  final String baseUrl;

  const AbbGenreView({super.key, required this.genre, required this.baseUrl});

  @override
  State<AbbGenreView> createState() => _AbbGenreViewState();
}

class _AbbGenreViewState extends State<AbbGenreView> {
  late final AbbClient _abb = AbbClient(widget.baseUrl);
  final _ownership = LibraryOwnershipService();
  final _items = <AbbSearchResult>[];
  final _seenIds = <String>{};

  int _page = 1;
  bool _loading = false;
  bool _done = false;
  bool _hideExplicit = false;
  bool _hideOwned = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _abb.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    _hideExplicit = await PlayerSettings.getHideExplicitContent();
    _hideOwned = await PlayerSettings.getHideOwnedTitles();
    if (!mounted) return;
    await _loadMore();
  }

  /// Fetch successive pages until at least one visible (post-filter) result
  /// lands, so an all-filtered page can't stall the endless-scroll trigger.
  Future<void> _loadMore() async {
    if (_loading || _done || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<AuthProvider>().apiService;
    final libraryId = context.read<LibraryProvider>().selectedLibraryId;
    try {
      while (true) {
        final page = await _abb.genreListing(widget.genre.slug, page: _page);
        _page++;
        final fresh = page.where((r) => _seenIds.add(r.id)).toList();
        if (fresh.isEmpty) {
          _done = true;
          break;
        }
        var visible = _hideExplicit
            ? fresh.where((r) => !r.explicit).toList()
            : fresh;
        if (_hideOwned && api != null && libraryId != null) {
          visible = await _ownership.filterUnowned(visible, api, libraryId);
        }
        if (visible.isNotEmpty) {
          _items.addAll(visible);
          break;
        }
      }
    } catch (e) {
      _done = true;
      if (_items.isEmpty) _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;

    Widget body;
    if (_items.isEmpty && _loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_items.isEmpty && _error != null) {
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
      body = LayoutBuilder(
        builder: (context, constraints) {
          final availW = constraints.maxWidth - 40;
          var cols = (availW / 160).ceil().clamp(2, 8);
          double itemW() => (availW - (cols - 1) * 16) / cols;
          while (cols > 2 && itemW() < 100) {
            cols--;
          }
          final extent = itemW() * 1.5 + 44;
          return NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels > n.metrics.maxScrollExtent - 600) {
                _loadMore();
              }
              return false;
            },
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                crossAxisSpacing: 16,
                mainAxisSpacing: 20,
                mainAxisExtent: extent,
              ),
              itemCount: _items.length + (_done ? 0 : 1),
              itemBuilder: (context, index) {
                if (index >= _items.length) {
                  return const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                return _GridCell(result: _items[index]);
              },
            ),
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.genre.name)),
      body: body,
    );
  }
}

class _GridCell extends StatelessWidget {
  final AbbSearchResult result;

  const _GridCell({required this.result});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AbbBookDetailView(result: result),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: AbbCover(url: result.coverUrl),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              result.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tt.labelMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
