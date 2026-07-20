import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../main.dart' show flatNotifier, gradientIntensityNotifier;
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/discover/abb_client.dart';
import '../services/discover/abb_models.dart';
import '../services/discover/download_tracker.dart';
import '../services/discover/ownership_service.dart';
import '../services/discover/series_tracking_service.dart';
import '../services/discover/transmission_client.dart';
import '../services/player_settings.dart';
import '../widgets/absorb_page_header.dart';
import '../widgets/discover/abb_book_detail_view.dart';
import '../widgets/discover/abb_config_sheet.dart';
import '../widgets/discover/abb_cover.dart';
import '../widgets/discover/abb_genre_view.dart';
import '../widgets/discover/abb_shelf.dart';
import '../widgets/discover/transmission_config_sheet.dart';
import '../widgets/shimmer.dart';

const _maxTrendingShelves = 4;

/// Discover tab: AudiobookBay browsing/search with Transmission downloads.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  // ── Config (mirrors PlayerSettings, reloaded on settingsChanged) ──
  bool _configLoaded = false;
  String _abbUrl = '';
  String _transmissionUrl = '';
  String _transmissionUser = '';
  String _transmissionPass = '';
  String _hardcoverToken = '';
  bool _hideExplicit = false;
  bool _hideOwned = true;
  List<String> _pinned = const [];

  AbbClient? _abb;
  TransmissionClient? _transmission;
  final _ownership = LibraryOwnershipService();

  // ── Search ──
  final _searchController = TextEditingController();
  int _searchGen = 0;
  bool _searching = false;
  List<AbbSearchResult> _searchResults = const [];
  final _searchOwnedIds = <String>{};

  // ── Genres / shelves ──
  List<AbbGenre>? _genres;
  bool _genresLoading = false;
  // null = fine, true = Cloudflare challenge, false = other load failure.
  bool? _abbUnreachable;
  String _abbErrorDetail = '';
  final _trending = <String, List<AbbSearchResult>?>{};

  bool _seriesLoading = false;
  List<AbbSearchResult>? _seriesResults;
  String? _seriesTrace;

  // ── Downloads ──
  List<TrackedDownload> _downloads = const [];

  @override
  void initState() {
    super.initState();
    PlayerSettings.settingsChanged.addListener(_onSettingsChanged);
    DownloadTracker.instance.addListener(_onDownloadsChanged);
    _onDownloadsChanged();
    _loadConfig();
    _pollLoop();
  }

  @override
  void dispose() {
    PlayerSettings.settingsChanged.removeListener(_onSettingsChanged);
    DownloadTracker.instance.removeListener(_onDownloadsChanged);
    _searchController.dispose();
    _abb?.dispose();
    _transmission?.dispose();
    super.dispose();
  }

  void _onSettingsChanged() => _loadConfig();

  void _onDownloadsChanged() {
    DownloadTracker.instance.all().then((items) {
      if (mounted) setState(() => _downloads = items);
    });
  }

  Future<void> _loadConfig() async {
    final abbUrl = (await PlayerSettings.getAbbServerUrl()).trim();
    final transUrl = (await PlayerSettings.getTransmissionUrl()).trim();
    final transUser = await PlayerSettings.getTransmissionUsername();
    final transPass = await PlayerSettings.getTransmissionPassword();
    final token = (await PlayerSettings.getHardcoverApiToken()).trim();
    final hideExplicit = await PlayerSettings.getHideExplicitContent();
    final hideOwned = await PlayerSettings.getHideOwnedTitles();
    final pinned = await PlayerSettings.getPinnedGenreSlugs();
    if (!mounted) return;

    final abbChanged = abbUrl != _abbUrl || !_configLoaded;
    final filtersChanged =
        hideExplicit != _hideExplicit || hideOwned != _hideOwned;
    final tokenChanged = token != _hardcoverToken;
    final transChanged = transUrl != _transmissionUrl ||
        transUser != _transmissionUser ||
        transPass != _transmissionPass ||
        !_configLoaded;

    setState(() {
      _abbUrl = abbUrl;
      _transmissionUrl = transUrl;
      _transmissionUser = transUser;
      _transmissionPass = transPass;
      _hardcoverToken = token;
      _hideExplicit = hideExplicit;
      _hideOwned = hideOwned;
      _pinned = pinned;
      _configLoaded = true;
      if (abbChanged) {
        _abb?.dispose();
        _abb = abbUrl.isEmpty ? null : AbbClient(abbUrl);
        _genres = null;
        _genresLoading = false;
      }
      if (abbChanged || filtersChanged || tokenChanged) {
        _trending.clear();
        _seriesResults = null;
        _seriesTrace = null;
        _seriesLoading = false;
        SeriesTrackingService.instance.invalidate();
      }
      if (transChanged) {
        _transmission?.dispose();
        _transmission = transUrl.isEmpty
            ? null
            : TransmissionClient(
                baseUrl: transUrl,
                username: transUser,
                password: transPass,
              );
      }
    });

    if ((abbChanged || filtersChanged) &&
        _searchController.text.trim().isNotEmpty) {
      _onSearchChanged(_searchController.text);
    }
    _ensureGenres();
    _ensureTrending();
    _ensureSeriesShelf();
  }

  Future<void> _refresh() async {
    setState(() {
      _genres = null;
      _genresLoading = false;
      _abbUnreachable = null;
      _trending.clear();
      _seriesResults = null;
      _seriesTrace = null;
      _seriesLoading = false;
    });
    SeriesTrackingService.instance.invalidate();
    await _loadConfig();
    _onDownloadsChanged();
  }

  // ── Genres ──

  Future<void> _ensureGenres() async {
    final abb = _abb;
    if (abb == null || _genres != null || _genresLoading) return;
    setState(() => _genresLoading = true);
    try {
      final genres = await abb.genres();
      if (!mounted || _abb != abb) return;
      setState(() {
        _genres = genres;
        _abbUnreachable = null;
      });
    } catch (e) {
      // Distinguish "ABB unreachable" from "no results" so the user knows to
      // check their mirror instead of staring at an empty page.
      if (mounted && _abb == abb) {
        setState(() {
          _genres = const [];
          _abbUnreachable = e is AbbCloudflareException;
          _abbErrorDetail = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _genresLoading = false);
    }
  }

  Future<void> _togglePin(AbbGenre genre) async {
    HapticFeedback.selectionClick();
    final pinned = List.of(_pinned);
    if (!pinned.remove(genre.slug)) pinned.add(genre.slug);
    // settingsChanged fires and _loadConfig picks up the new pin order.
    await PlayerSettings.setPinnedGenreSlugs(pinned);
  }

  static String _prettySlug(String slug) => slug
      .split('-')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');

  String _genreName(String slug) {
    for (final g in _genres ?? const <AbbGenre>[]) {
      if (g.slug == slug) return g.name;
    }
    return _prettySlug(slug);
  }

  // ── Trending ──

  void _ensureTrending() {
    if (_abb == null) return;
    for (final slug in _pinned.take(_maxTrendingShelves)) {
      if (_trending.containsKey(slug)) continue;
      _trending[slug] = null;
      _loadTrending(slug);
    }
  }

  Future<void> _loadTrending(String slug) async {
    final abb = _abb;
    if (abb == null) return;
    final api = context.read<AuthProvider>().apiService;
    final libraryId = context.read<LibraryProvider>().selectedLibraryId;
    try {
      var results = await abb.genreListing(slug, page: 1);
      if (_hideExplicit) results = results.where((r) => !r.explicit).toList();
      results = results.take(10).toList();
      if (!mounted || _abb != abb) return;
      setState(() => _trending[slug] = results);
      if (_hideOwned && api != null && libraryId != null) {
        final unowned = (await _ownership.filterUnowned(results, api, libraryId))
            .take(10)
            .toList();
        if (!mounted || _abb != abb) return;
        setState(() => _trending[slug] = unowned);
      }
    } catch (_) {
      if (mounted && _abb == abb) {
        setState(() => _trending[slug] = const []);
      }
    }
  }

  // ── New in Your Series ──

  Future<void> _ensureSeriesShelf() async {
    if (_hardcoverToken.isEmpty ||
        _abbUrl.isEmpty ||
        _seriesLoading ||
        _seriesResults != null) {
      return;
    }
    final api = context.read<AuthProvider>().apiService;
    final libraryId = context.read<LibraryProvider>().selectedLibraryId;
    if (api == null || libraryId == null) return;
    setState(() => _seriesLoading = true);
    final (results, trace) =
        await SeriesTrackingService.instance.missingFromTrackedSeries(
      api: api,
      libraryId: libraryId,
      hardcoverToken: _hardcoverToken,
      abbBaseUrl: _abbUrl,
    );
    if (!mounted) return;
    setState(() {
      _seriesResults = results;
      _seriesTrace = trace;
      _seriesLoading = false;
    });
  }

  // ── Search ──

  void _onSearchChanged(String text) {
    final query = text.trim();
    // Bumping the generation cancels whatever search is in flight.
    final gen = ++_searchGen;
    if (query.isEmpty) {
      setState(() {
        _searching = false;
        _searchResults = const [];
        _searchOwnedIds.clear();
      });
      return;
    }
    setState(() => _searching = true);
    _runSearch(query, gen);
  }

  Future<void> _runSearch(String query, int gen) async {
    final abb = _abb;
    if (abb == null) return;
    // Small settle delay so mid-word keystrokes never hit the scraper.
    await Future.delayed(const Duration(milliseconds: 350));
    if (gen != _searchGen || !mounted) return;
    try {
      var results = await abb.search(query);
      if (gen != _searchGen || !mounted) return;
      if (_hideExplicit) results = results.where((r) => !r.explicit).toList();
      // Phase one: show explicit-filtered results immediately.
      setState(() {
        _searchResults = results;
        _searchOwnedIds.clear();
        _searching = false;
      });
      if (!_hideOwned) return;
      final api = context.read<AuthProvider>().apiService;
      final libraryId = context.read<LibraryProvider>().selectedLibraryId;
      if (api == null || libraryId == null) return;
      // Phase two: owned rows animate out once the ownership check lands.
      final unowned = await _ownership.filterUnowned(results, api, libraryId);
      if (gen != _searchGen || !mounted) return;
      final unownedIds = unowned.map((r) => r.id).toSet();
      setState(() {
        _searchOwnedIds
          ..clear()
          ..addAll(results
              .where((r) => !unownedIds.contains(r.id))
              .map((r) => r.id));
      });
    } catch (_) {
      if (gen == _searchGen && mounted) {
        setState(() {
          _searching = false;
          _searchResults = const [];
        });
      }
    }
  }

  // ── Download polling ──

  Future<void> _pollLoop() async {
    while (mounted) {
      final tc = _transmission;
      final tracked = await DownloadTracker.instance.all();
      if (tc == null || tracked.isEmpty) {
        await Future.delayed(const Duration(seconds: 4));
        continue;
      }
      try {
        final torrents =
            await tc.torrentGet([for (final d in tracked) d.torrentId]);
        final byId = {
          for (final t in torrents) ((t['id'] as num?)?.toInt() ?? -1): t,
        };
        for (final d in tracked) {
          final t = byId[d.torrentId];
          if (t == null) {
            await DownloadTracker.instance.remove(d.infoHash);
            continue;
          }
          final statusKey =
              TransmissionStatus.key((t['status'] as num?)?.toInt() ?? 0);
          final percentDone = (t['percentDone'] as num?)?.toDouble() ?? 0;
          final target = TransmissionClient.seedTarget(
            (t['seedRatioMode'] as num?)?.toInt() ?? 0,
            (t['seedRatioLimit'] as num?)?.toDouble() ?? 0,
          );
          final seedProgress = TransmissionClient.seedProgress(
            (t['uploadRatio'] as num?)?.toDouble() ?? 0,
            target,
          );
          final seeding = statusKey == 'seeding';
          if ((seeding && seedProgress >= 1) ||
              (percentDone >= 1 && statusKey == 'stopped')) {
            // Finished: Transmission and the ABS watched folder own the
            // files from here, so drop it from the tracker.
            await DownloadTracker.instance.remove(d.infoHash);
          } else {
            // The bar deliberately resets to seed progress when seeding
            // starts, so the user sees the seed ratio fill up.
            await DownloadTracker.instance.updateProgress(
              d.infoHash,
              seeding ? seedProgress : percentDone,
              statusKey,
            );
          }
        }
      } catch (_) {
        // Transient RPC errors: keep polling.
      }
      await Future.delayed(const Duration(milliseconds: 2500));
    }
  }

  // ── Navigation ──

  void _openDetail(AbbSearchResult result) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AbbBookDetailView(result: result)),
    );
  }

  void _openGenre(AbbGenre genre) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AbbGenreView(genre: genre, baseUrl: _abbUrl),
      ),
    );
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final lowerFade = Color.lerp(cs.surface, scaffoldBg, 0.55) ?? scaffoldBg;
    final configured = _abbUrl.isNotEmpty && _transmissionUrl.isNotEmpty;
    final inSearch = _searchController.text.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: Container(
        decoration: flatNotifier.value
            ? null
            : BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.22, 0.72, 1.0],
                  colors: [
                    cs.primary
                        .withValues(alpha: gradientIntensityNotifier.value),
                    cs.surface,
                    lowerFade,
                    scaffoldBg,
                  ],
                ),
              ),
        child: SafeArea(
          child: !_configLoaded
              ? const Center(child: CircularProgressIndicator())
              : !configured
                  ? _buildNotConfigured(cs, tt, l)
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: CustomScrollView(
                        physics: const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                        slivers: [
                          SliverToBoxAdapter(
                            child: AbsorbPageHeader(
                              title: l.appShellDiscoverTab,
                              actions: [_settingsMenu(cs)],
                            ),
                          ),
                          SliverToBoxAdapter(child: _searchBar(cs, l)),
                          if (inSearch)
                            ..._searchSlivers(cs, tt, l)
                          else
                            SliverToBoxAdapter(
                              child: _browseColumn(cs, tt, l),
                            ),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 32),
                          ),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }

  Widget _buildNotConfigured(ColorScheme cs, TextTheme tt, AppLocalizations l) {
    return Column(
      children: [
        AbsorbPageHeader(title: l.appShellDiscoverTab),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.settings_input_antenna,
                    size: 56,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l.discoverNotConfiguredTitle,
                    textAlign: TextAlign.center,
                    style:
                        tt.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l.discoverNotConfiguredBody,
                    textAlign: TextAlign.center,
                    style:
                        tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.tonal(
                    onPressed: () => showAbbConfigSheet(context),
                    child: Text(l.discoverConfigureAbb),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () => showTransmissionConfigSheet(context),
                    child: Text(l.discoverConfigureTransmission),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _settingsMenu(ColorScheme cs) {
    final l = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      icon: Icon(Icons.settings_outlined, size: 20, color: cs.onSurfaceVariant),
      onSelected: (value) {
        if (value == 'abb') {
          showAbbConfigSheet(context);
        } else {
          showTransmissionConfigSheet(context);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'abb', child: Text(l.discoverAbbSettings)),
        PopupMenuItem(
            value: 'transmission',
            child: Text(l.discoverTransmissionSettings)),
      ],
    );
  }

  Widget _searchBar(ColorScheme cs, AppLocalizations l) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: SearchBar(
        controller: _searchController,
        hintText: l.discoverSearchHint,
        leading: const Padding(
          padding: EdgeInsets.only(left: 8),
          child: Icon(Icons.search_rounded),
        ),
        trailing: [
          if (_searchController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_rounded),
              onPressed: () {
                _searchController.clear();
                _onSearchChanged('');
                FocusManager.instance.primaryFocus?.unfocus();
              },
            ),
        ],
        onChanged: _onSearchChanged,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8),
        ),
        side: WidgetStatePropertyAll(
          BorderSide(color: cs.onSurface.withValues(alpha: 0.08)),
        ),
      ),
    );
  }

  List<Widget> _searchSlivers(ColorScheme cs, TextTheme tt, AppLocalizations l) {
    if (_searching && _searchResults.isEmpty) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (_searchResults.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 48),
            child: Center(
              child: Text(
                l.discoverSearchNoResults(_searchController.text.trim()),
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        sliver: SliverList.builder(
          itemCount: _searchResults.length,
          itemBuilder: (context, index) =>
              _searchRow(_searchResults[index], cs, tt),
        ),
      ),
    ];
  }

  Widget _searchRow(AbbSearchResult r, ColorScheme cs, TextTheme tt) {
    final owned = _searchOwnedIds.contains(r.id);
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: owned
          ? const SizedBox(width: double.infinity)
          : InkWell(
              onTap: () => _openDetail(r),
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
                            style: tt.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                          if (r.author != null)
                            Text(
                              r.author!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                    if (r.year != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${r.year}',
                        style: tt.labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _browseColumn(ColorScheme cs, TextTheme tt, AppLocalizations l) {
    // Eager column: every shelf loads on first mount rather than lazily.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        _genrePills(cs, tt),
        for (final slug in _pinned.take(_maxTrendingShelves))
          _trendingShelf(slug, l),
        _seriesShelf(cs, tt, l),
        if (_downloads.isNotEmpty) _downloadsSection(cs, tt, l),
      ],
    );
  }

  Widget _genrePills(ColorScheme cs, TextTheme tt) {
    final genres = _genres;
    if (genres == null) {
      return SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 4,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, __) =>
              const ShimmerBox(width: 88, height: 32, borderRadius: 16),
        ),
      );
    }
    if (genres.isEmpty) {
      final unreachable = _abbUnreachable;
      if (unreachable == null) return const SizedBox.shrink();
      final l = AppLocalizations.of(context)!;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Icon(Icons.cloud_off_rounded, size: 16, color: cs.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                unreachable
                    ? l.discoverAbbCloudflare
                    : l.discoverLoadFailed(_abbErrorDetail),
                style: tt.bodySmall?.copyWith(color: cs.error),
              ),
            ),
          ],
        ),
      );
    }

    final bySlug = {for (final g in genres) g.slug: g};
    final ordered = <AbbGenre>[
      for (final slug in _pinned)
        bySlug[slug] ?? AbbGenre(slug: slug, name: _prettySlug(slug)),
      ...([
        for (final g in genres)
          if (!_pinned.contains(g.slug)) g
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()))),
    ];

    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        physics: const BouncingScrollPhysics(),
        itemCount: ordered.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final genre = ordered[index];
          final pinned = _pinned.contains(genre.slug);
          return GestureDetector(
            onTap: () => _openGenre(genre),
            onLongPress: () => _togglePin(genre),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: pinned
                    ? cs.primary.withValues(alpha: 0.12)
                    : cs.onSurface.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: pinned
                      ? cs.primary.withValues(alpha: 0.3)
                      : cs.onSurface.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (pinned) ...[
                    Icon(Icons.push_pin_rounded, size: 12, color: cs.primary),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    genre.name,
                    style: tt.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: pinned ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _trendingShelf(String slug, AppLocalizations l) {
    final results = _trending[slug];
    if (results == null) return const ShimmerBookRow();
    if (results.isEmpty) return const SizedBox.shrink();
    return AbbShelf(
      title: l.discoverTrendingIn(_genreName(slug)),
      icon: Icons.trending_up_rounded,
      results: results,
      onTap: _openDetail,
    );
  }

  Widget _seriesShelf(ColorScheme cs, TextTheme tt, AppLocalizations l) {
    if (_hardcoverToken.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
        child: InkWell(
          onTap: () => showAbbConfigSheet(context),
          borderRadius: BorderRadius.circular(8),
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.discoverHardcoverPrompt,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget headed(Widget child) => Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AbbShelfHeader(
                  title: l.discoverNewInSeries,
                  icon: Icons.auto_stories_rounded),
              child,
            ],
          ),
        );

    final results = _seriesResults;
    if (_seriesLoading || results == null) {
      return headed(const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ));
    }
    if (results.isEmpty) {
      return headed(Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.discoverCaughtUp,
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (_seriesTrace != null) ...[
              const SizedBox(height: 4),
              Text(
                _seriesTrace!,
                style: tt.labelSmall?.copyWith(color: cs.tertiary),
              ),
            ],
          ],
        ),
      ));
    }
    return AbbShelf(
      title: l.discoverNewInSeries,
      icon: Icons.auto_stories_rounded,
      results: results,
      onTap: _openDetail,
    );
  }

  Widget _downloadsSection(ColorScheme cs, TextTheme tt, AppLocalizations l) {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AbbShelfHeader(
              title: l.discoverActiveDownloads,
              icon: Icons.download_rounded),
          const SizedBox(height: 4),
          for (final d in _downloads) _downloadRow(d, cs, tt, l),
        ],
      ),
    );
  }

  Widget _downloadRow(
      TrackedDownload d, ColorScheme cs, TextTheme tt, AppLocalizations l) {
    final seeding = d.status == 'seeding';
    final stopped = d.status == 'stopped';
    final barColor = seeding
        ? Colors.green
        : stopped
            ? cs.outline
            : Colors.blue;
    final statusIcon = seeding
        ? Icons.arrow_circle_up
        : stopped
            ? Icons.pause_circle
            : Icons.arrow_circle_down;
    final statusLabel = seeding
        ? l.discoverStatusSeeding
        : stopped
            ? l.discoverStatusPaused
            : l.discoverStatusDownloading;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            d.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
          if (d.author.isNotEmpty)
            Text(
              d.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: d.progress.clamp(0.0, 1.0),
              minHeight: 5,
              color: barColor,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(statusIcon, size: 14, color: barColor),
              const SizedBox(width: 4),
              Text(
                statusLabel,
                style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const Spacer(),
              Text(
                '${(d.progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
                style: tt.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
