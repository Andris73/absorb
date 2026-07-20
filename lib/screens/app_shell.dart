import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import '../services/chromecast_service.dart';
import '../services/home_widget_service.dart';
import '../services/sleep_timer_service.dart';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../utils/cover_accent.dart';
import '../main.dart'
    show snappyTransitionsNotifier, coverSchemeNotifier, rootNavigatorKey, applyOrientationLock;
import '../l10n/app_localizations.dart';
import '../services/wording.dart';
import '../services/android_auto_service.dart';
import '../services/carplay_service.dart';
import '../widgets/expanded_card.dart';
import 'absorbing_screen.dart';
import 'discover_screen.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'stats_screen.dart';
import 'settings_screen.dart';
import '../widgets/library_picker_sheet.dart';
import '../widgets/welcome_sheet.dart';
import '../services/review_service.dart';
import '../services/update_checker_service.dart';
import '../widgets/update_dialog.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Navigate to the Absorbing tab using BuildContext (ancestor lookup).
  static void goToAbsorbing(BuildContext context) {
    final state = context.findAncestorStateOfType<_AppShellState>();
    state?._switchToAbsorbing();
  }

  /// Navigate to the Absorbing tab without needing a context.
  static void goToAbsorbingGlobal() {
    _AppShellState._instance?._switchToAbsorbing();
  }

  /// Track when expanded card is opened/closed externally (e.g. chevron tap).
  static void setExpandedOpen(bool open) {
    _AppShellState._instance?._expandedIsOpen = open;
  }

  /// Switch to the Library tab and focus the search bar. Used by the
  /// app-icon "Search" shortcut. Returns false when the shell isn't mounted
  /// yet so callers can retry during cold start.
  static bool openSearchGlobal() {
    final inst = _AppShellState._instance;
    if (inst == null) return false;
    inst._openSearch();
    return true;
  }

  /// Switch to the Library tab and apply a tag filter. Used by the book
  /// detail sheet's tag chip so tapping a tag jumps the user to the library
  /// view filtered by that tag. Returns false when the shell or library
  /// state isn't mounted yet.
  static bool openLibraryWithTagFilterGlobal(String tag) =>
      _applyLibraryFilterGlobal((s) => s.applyTagFilter(tag));

  /// Switch to the Library tab and apply a genre filter. Mirrors the tag
  /// version above; used by the genre chip in book detail.
  static bool openLibraryWithGenreFilterGlobal(String genre) =>
      _applyLibraryFilterGlobal((s) => s.applyGenreFilter(genre));

  static bool _applyLibraryFilterGlobal(
    void Function(LibraryScreenState) apply,
  ) {
    final inst = _AppShellState._instance;
    if (inst == null) return false;
    // If the full-screen expanded player is on top of the shell, pop it
    // first. Otherwise switching to the Library tab leaves the player
    // covering the filtered library underneath. Caller (e.g. the book
    // detail sheet) has already popped its own modal route at this point.
    if (inst._expandedIsOpen && inst.mounted) {
      Navigator.of(inst.context, rootNavigator: true).maybePop();
    }
    inst._navigateTo(1);
    // The retry budget has to survive the fade transition (~200ms by
    // default, see `_fadeController` and `_navigateTo`) plus the library
    // widget's own mount + first build. On cold start that easily takes
    // 300-500ms before `_libraryKey.currentState` becomes non-null. ~3s
    // worth of frames is generous enough to cover slow devices and stingy
    // enough to give up if something is genuinely broken.
    const maxAttempts = 180; // ~3s at 60fps
    var attempts = 0;
    void tryApply() {
      if (!inst.mounted) return;
      final state = inst._libraryKey.currentState;
      if (state != null) {
        apply(state);
        return;
      }
      if (++attempts < maxAttempts) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tryApply());
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tryApply());
    return true;
  }

  /// Called by Home (callingTab=0) and Library (callingTab=1) after their
  /// first frame. Lets the AppShell re-sync the bottom-nav listener to the
  /// right notifier — handles both "screen state didn't exist on initial
  /// attach" and "lazy attach attached to the wrong tab during a fade
  /// transition" (LibraryProvider notify can rebuild AppShell mid-fade and
  /// schedule a postFrame that fires before _currentIndex transitions).
  static void notifyScreenReady(int callingTab) {
    _AppShellState._instance?._reattachIfNeeded(callingTab);
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static _AppShellState? _instance;

  // Stack pages: 0=Home, 1=Library, 2=Absorbing (default), 3=Stats,
  // 4=Settings, 5=Discover (optional tab)
  int _currentIndex = 2; // overridden by user preference in initState

  // Dedicated Podcasts tab (optional 6th destination, display order Home,
  // Library, Podcasts, Absorbing, Stats, Settings). Stack pages keep their
  // historic 0-4 indexes: the Podcasts and Library destinations share page 1,
  // and which one is highlighted is derived from the selected library.
  bool _podcastTabEnabled = false;
  String _podcastTabLibraryId = '';
  // Dedicated Discover tab (optional destination) with its own stack page 5.
  bool _discoverTabEnabled = false;

  // User-arranged bottom nav. `_tabOrder` is the display order of tab ids and
  // `_hiddenTabs` the ones hidden from the bar. Podcasts and Discover carry
  // their own enable flags (above); the rest are governed by `_hiddenTabs`.
  // Settings is never hidden so the user can always get back here.
  List<String> _tabOrder = List.of(PlayerSettings.navTabIds);
  Set<String> _hiddenTabs = {};

  int _stackPageForTab(String id) {
    switch (id) {
      case 'home': return 0;
      case 'library': return 1;
      case 'podcasts': return 1; // shares the Library page
      case 'absorbing': return 2;
      case 'stats': return 3;
      case 'settings': return 4;
      case 'discover': return 5;
    }
    return 0;
  }

  bool _tabVisible(String id, LibraryProvider lib) {
    switch (id) {
      case 'settings':
        return true; // always reachable so the user can re-enable tabs
      case 'podcasts':
        return _podcastsShown(lib);
      case 'discover':
        return _discoverTabEnabled;
      default:
        return !_hiddenTabs.contains(id);
    }
  }

  List<String> _visibleTabs(LibraryProvider lib) {
    final merged = PlayerSettings.mergeNavOrder(_tabOrder);
    final visible = merged.where((id) => _tabVisible(id, lib)).toSet();
    // NavigationBar needs >= 2 destinations; if a bad import or over-eager
    // hiding left too few, reveal generic tabs (in order) until we have two.
    if (visible.length < 2) {
      for (final id in ['home', 'library', 'stats', 'absorbing']) {
        visible.add(id);
        if (visible.length >= 2) break;
      }
    }
    return merged.where(visible.contains).toList();
  }
  final _homeKey = GlobalKey<HomeScreenState>();
  final _libraryKey = GlobalKey<LibraryScreenState>();
  final _player = AudioPlayerService();
  final _cast = ChromecastService();
  bool _playerHadBook = false;
  bool _wasPlaying = false;
  bool _lifecycleBackgrounded = false;
  String? _lastItemId;
  bool _expandedIsOpen = false;
  bool _wasCasting = false;
  DateTime? _lastBackPress;
  // Tracks which item's cover we derived the scheme from.
  String? _lastCoverItemId;

  // ── Scroll-to-hide bottom nav (driven by Library screen) ──
  late final AnimationController _navBarAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: 1.0,
  );
  VoidCallback? _navBarListener;

  // Lazily build tabs so startup on Absorbing does not initialize Home/Library
  // work until the user actually visits those tabs.
  final List<Widget?> _pages = List<Widget?>.filled(6, null, growable: false);

  void _openSearch() {
    if (!mounted) return;
    // If the user triggered Search while a pushed route (Downloads, Bookmarks,
    // Settings pages, etc.) is on top of the shell, pop back so the shell's
    // Library tab actually becomes visible.
    final nav = rootNavigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.popUntil((r) => r.isFirst);
    }
    _navigateTo(1);
    // Library tab may need a frame to mount its state before we can focus
    // the search field. Retry up to a few frames to cover fade transitions.
    int attempts = 0;
    void tryFocus() {
      if (!mounted) return;
      final state = _libraryKey.currentState;
      if (state != null) {
        state.focusSearch();
        return;
      }
      if (++attempts < 10) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tryFocus());
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tryFocus());
  }

  void _switchToAbsorbing() {
    if (mounted) {
      _navigateTo(2);
      // Scroll to the currently playing book after the tab switch
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AbsorbingScreen.scrollToActive();
      });
    }
  }

  void _navigateTo(int index) {
    if (index == _currentIndex) {
      // Already on this tab — handle re-tap actions
      if (index == 2) {
        // Absorbing tab: scroll to first card
        AbsorbingScreen.scrollToFirst();
      }
      return;
    }
    _ensurePageBuilt(index);
    _syncNavBarListener(index);
    if (snappyTransitionsNotifier.value) {
      setState(() => _currentIndex = index);
    } else {
      _fadeController.reverse().then((_) {
        if (!mounted) return;
        setState(() {
          _currentIndex = index;
        });
        _fadeController.forward();
      });
    }
  }

  /// Subscribe to the active screen's barsRevealNotifier when on Home or
  /// Library tab, and ensure the nav bar is visible on all other tabs.
  void _syncNavBarListener(int index) {
    _detachNavBarListener();
    // Snap visible immediately on every tab change so a partial-hide state
    // from another tab can never bleed into the new tab.
    _navBarAnimController.value = 1.0;
    ValueListenable<double>? notifier;
    if (index == 0) {
      notifier = _homeKey.currentState?.barsRevealNotifier;
    } else if (index == 1) {
      notifier = _libraryKey.currentState?.barsRevealNotifier;
    }
    if (notifier != null) {
      _activeBarNotifier = notifier;
      // Mirror the screen's continuous 0..1 reveal value directly onto the
      // controller so the bottom nav slides in lockstep with the header.
      _navBarListener = () {
        final v = notifier!.value.clamp(0.0, 1.0);
        // Skip no-op controller writes. AnimationController.value setter
        // notifies listeners (and triggers SizeTransition + Scaffold layout)
        // even when the value didn't change, which causes scroll jank when
        // the bar is already fully open/closed.
        if ((_navBarAnimController.value - v).abs() < 0.005) return;
        _navBarAnimController.value = v;
      };
      notifier.addListener(_navBarListener!);
      _navBarListener!();
    }
  }

  ValueListenable<double>? _activeBarNotifier;

  void _detachNavBarListener() {
    if (_navBarListener != null && _activeBarNotifier != null) {
      _activeBarNotifier!.removeListener(_navBarListener!);
    }
    _navBarListener = null;
    _activeBarNotifier = null;
  }

  /// Hook called by Home/Library when their state finishes mounting so we can
  /// pick up (or correct) the listener attach. Re-syncs unconditionally when
  /// the calling tab matches the current tab, even if a listener is already
  /// attached — that listener may have been attached to the wrong tab by the
  /// lazy-attach race during a fade transition.
  void _reattachIfNeeded(int callingTab) {
    if (!mounted) return;
    // Only act when the screen calling us is actually the active one. If the
    // user has navigated away in the meantime, leave the existing attachment
    // to whatever screen they're on.
    if (_currentIndex != callingTab) return;
    _syncNavBarListener(_currentIndex);
  }

  void _ensurePageBuilt(int index) {
    if (_pages[index] != null) return;
    switch (index) {
      case 0:
        _pages[index] = HomeScreen(key: _homeKey);
        break;
      case 1:
        _pages[index] = LibraryScreen(key: _libraryKey);
        break;
      case 2:
        _pages[index] = AbsorbingScreen(key: AbsorbingScreen.globalKey);
        break;
      case 3:
        _pages[index] = const StatsScreen();
        break;
      case 4:
        _pages[index] = const SettingsScreen();
        break;
      case 5:
        _pages[index] = const DiscoverScreen();
        break;
    }
  }

  late final AnimationController _fadeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1.0,
  );

  void _loadStartScreen() {
    PlayerSettings.getStartScreen().then((idx) {
      if (mounted && idx != _currentIndex && idx >= 0 && idx <= 4) {
        setState(() => _currentIndex = idx);
        _ensurePageBuilt(idx);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _instance = this;
    _loadStartScreen();
    _ensurePageBuilt(_currentIndex);
    _playerHadBook = _player.hasBook;
    _wasPlaying = _player.isPlaying;
    _lastItemId = _player.currentItemId;
    WidgetsBinding.instance.addObserver(this);
    AudioPlayerService.setOnEpisodePlayStartedCallback(
      AppShell.goToAbsorbingGlobal,
    );
    _player.addListener(_onPlayerChanged);
    _wasCasting = _cast.isCasting;
    _cast.addListener(_onCastChanged);
    // Try immediately; _onLibraryChanged picks it up once data loads.
    // Deferred to post-frame so Theme.of(context) inside _deriveCoverScheme
    // doesn't establish an inherited-widget dependency during initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _deriveCoverScheme();
    });
    context.read<LibraryProvider>().addListener(_onLibraryChanged);
    _loadOptionalTabPrefs();
    PlayerSettings.settingsChanged.addListener(_loadOptionalTabPrefs);
    WelcomeSheet.showIfNeeded(context);
    _checkForUpdate();
  }

  Future<void> _loadOptionalTabPrefs() async {
    final enabled = await PlayerSettings.getPodcastTabEnabled();
    final libId = await PlayerSettings.getPodcastTabLibraryId();
    final discover = await PlayerSettings.getDiscoverTabEnabled();
    final order = await PlayerSettings.getNavTabOrder();
    final hidden = (await PlayerSettings.getNavHiddenTabs()).toSet();
    if (!mounted) return;
    final resolvedOrder =
        order.isEmpty ? List.of(PlayerSettings.navTabIds) : order;
    if (enabled != _podcastTabEnabled ||
        libId != _podcastTabLibraryId ||
        discover != _discoverTabEnabled ||
        !listEquals(resolvedOrder, _tabOrder) ||
        !setEquals(hidden, _hiddenTabs)) {
      setState(() {
        _podcastTabEnabled = enabled;
        _podcastTabLibraryId = libId;
        _discoverTabEnabled = discover;
        _tabOrder = resolvedOrder;
        _hiddenTabs = hidden;
        // Tear down the Discover page when its tab is switched off so its
        // polling loop and caches don't keep living offstage forever.
        if (!discover) _pages[5] = null;
      });
      // Don't strand the user on a now-hidden tab: if nothing visible maps to
      // the current page, jump to the first visible tab.
      final lib = context.read<LibraryProvider>();
      final visible = _visibleTabs(lib);
      final stillShown =
          visible.any((id) => _stackPageForTab(id) == _currentIndex);
      if (!stillShown) _navigateTo(_stackPageForTab(visible.first));
    }
  }

  bool _podcastsShown(LibraryProvider lib) =>
      _podcastTabEnabled &&
      _podcastTabLibraryId.isNotEmpty &&
      lib.libraries.any((l) => l['id'] == _podcastTabLibraryId);

  // Display slot (dest) <-> stack page is derived from the visible tab list:
  // `_stackPageForTab(_visibleTabs(lib)[dest])`. Library and Podcasts both map
  // to stack page 1; which one is highlighted is decided by the selected
  // library.
  int _selectedDest(LibraryProvider lib) {
    final tabs = _visibleTabs(lib);
    String? current;
    if (_currentIndex == 1) {
      final onPodcast = _podcastTabLibraryId.isNotEmpty &&
          lib.selectedLibraryId == _podcastTabLibraryId;
      current = onPodcast && tabs.contains('podcasts') ? 'podcasts' : 'library';
    } else {
      for (final id in tabs) {
        if (_stackPageForTab(id) == _currentIndex) {
          current = id;
          break;
        }
      }
    }
    final dest = current == null ? -1 : tabs.indexOf(current);
    // A hidden tab can be current for a frame while _navigateTo lands.
    return dest >= 0 ? dest : 0;
  }

  /// Keep the selected library in step with the tab being entered: Podcasts
  /// pins its library; Home/Library return to the remembered book library.
  /// Uses the light switch so playback and cached shelves survive.
  void _syncTabLibraryForTab(String tab) {
    final lib = context.read<LibraryProvider>();
    if (tab == 'podcasts') {
      if (_podcastTabLibraryId.isNotEmpty &&
          lib.selectedLibraryId != _podcastTabLibraryId) {
        lib.selectLibraryLight(_podcastTabLibraryId);
      }
    } else if (tab == 'home' || tab == 'library') {
      if (_podcastTabLibraryId.isNotEmpty &&
          lib.selectedLibraryId == _podcastTabLibraryId) {
        lib.lastBookLibraryId().then((bookLib) {
          if (mounted && bookLib != null && bookLib != _podcastTabLibraryId) {
            lib.selectLibraryLight(bookLib);
          }
        });
      }
    }
  }

  static const _isGithubBuild = bool.fromEnvironment('GITHUB_BUILD');

  void _checkForUpdate() async {
    if (!_isGithubBuild) return;
    final includePreReleases = await PlayerSettings.getIncludePreReleases();
    final info = await UpdateCheckerService.check(
      includePreReleases: includePreReleases,
    );
    if (info == null || !mounted) return;
    await UpdateDialog.show(context, info);
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _detachNavBarListener();
    _navBarAnimController.dispose();
    _player.removeListener(_onPlayerChanged);
    _cast.removeListener(_onCastChanged);
    PlayerSettings.settingsChanged.removeListener(_loadOptionalTabPrefs);
    try {
      context.read<LibraryProvider>().removeListener(_onLibraryChanged);
    } catch (_) {}
    if (_instance == this) _instance = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    // Re-derive cover scheme whenever absorbing list changes so the app
    // theme always reflects the current [0] book.
    _deriveCoverScheme();
    // With the dedicated Podcasts tab, Home never shows the podcast library.
    // Covers the cold start restoring last_selected_library onto page 0.
    final lib = context.read<LibraryProvider>();
    if (_currentIndex == 0 &&
        _podcastsShown(lib) &&
        lib.selectedLibraryId == _podcastTabLibraryId) {
      _syncTabLibraryForTab('home');
    }
  }

  /// Attempt to derive cover scheme. Returns true if successful.
  bool _deriveCoverScheme() {
    if (!mounted) return false;
    // Use player's current item, or fall back to absorbing list's first item
    var itemId = _player.currentItemId;
    if (itemId == null) {
      final lib = context.read<LibraryProvider>();
      final ids = lib.absorbingBookIds;
      if (ids.isNotEmpty) {
        final key = ids.first;
        // Composite keys are "itemId-episodeId"; extract the item ID
        itemId = key.length > 36 ? key.substring(0, 36) : key;
      }
    }
    if (itemId == null) {
      return false;
    }
    if (itemId == _lastCoverItemId) return true;

    final lib = context.read<LibraryProvider>();
    final coverUrl = lib.getCoverUrl(itemId, width: 400);
    if (coverUrl == null) {
      return false;
    }
    _lastCoverItemId = itemId;

    final ImageProvider provider;
    if (coverUrl.startsWith('/')) {
      provider = FileImage(File(coverUrl));
    } else {
      provider = CachedNetworkImageProvider(
        coverUrl,
        headers: lib.mediaHeaders,
      );
    }

    final brightness = Theme.of(context).brightness;
    PaletteGenerator.fromImageProvider(provider, maximumColorCount: 16)
        .then((palette) {
          final seedColor = accentFromCoverPalette(palette);
          if (seedColor == null) {
            _lastCoverItemId = null;
            return;
          }
          final scheme = ColorScheme.fromSeed(
            seedColor: seedColor,
            brightness: brightness,
          );
          coverSchemeNotifier.value = scheme;
          PlayerSettings.setCoverSeedColor(seedColor.toARGB32());
        })
        .catchError((_) {
          _lastCoverItemId = null;
        });
    return true; // cover URL found, image load in progress
  }

  void _onPlayerChanged() {
    final hasBook = _player.hasBook;
    final playing = _player.isPlaying;
    final itemId = _player.currentItemId;

    // Detect playback starting: new book loaded, play resumed, or item changed
    final newBook = hasBook && !_playerHadBook;
    final playStarted = playing && !_wasPlaying;
    final itemChanged = itemId != null && itemId != _lastItemId;

    _playerHadBook = hasBook;
    _wasPlaying = playing;
    _lastItemId = itemId;

    if (itemChanged || newBook) _deriveCoverScheme();

    if ((newBook || playStarted || itemChanged) && !_expandedIsOpen) {
      _maybeAutoExpand();
    }
  }

  void _onCastChanged() {
    final casting = _cast.isCasting;
    if (casting && !_wasCasting) {
      _switchToAbsorbing();
    }
    _wasCasting = casting;
  }

  Future<void> _maybeAutoExpand() async {
    // Only auto-open the full-screen player from the Absorbing tab - starting
    // playback from elsewhere (another tab, the nav long-press) shouldn't
    // yank the user into the player.
    if (_currentIndex != 2) return;
    final enabled = await PlayerSettings.getFullScreenPlayer();
    if (!enabled || !mounted || !_player.hasBook) return;

    // Synthesize item data from player state
    final itemId = _player.currentItemId;
    if (itemId == null) return;

    final lib = context.read<LibraryProvider>();
    // Try to find the real item data from the library
    Map<String, dynamic>? item;
    for (final section in lib.personalizedSections) {
      for (final e in (section['entities'] as List<dynamic>? ?? [])) {
        if (e is Map<String, dynamic> && e['id'] == itemId) {
          item = e;
          break;
        }
      }
      if (item != null) break;
    }
    // Fallback: synthesize from player data
    item ??= {
      'id': itemId,
      'libraryId': _player.currentLibraryId,
      'media': {
        'metadata': {
          'title': _player.currentTitle ?? 'Unknown',
          'authorName': _player.currentAuthor ?? '',
        },
        'duration': _player.totalDuration,
        'chapters': _player.chapters,
      },
    };
    if (_player.currentEpisodeId != null) {
      item['recentEpisode'] = {
        'id': _player.currentEpisodeId,
        'title': _player.currentEpisodeTitle ?? _player.currentTitle,
        'duration': _player.totalDuration,
      };
    }

    _expandedIsOpen = true;
    final nav = Navigator.of(context, rootNavigator: true);
    await nav.push(
      ExpandedCardRoute(
        child: ExpandedCard(item: item, player: _player),
      ),
    );
    // Route was popped — expanded view closed
    _expandedIsOpen = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // Before the backgrounded guard: when the activity attaches to an
        // engine that has never drawn (born from a headless Android Auto /
        // media-button start, kept alive because audio is playing), nothing
        // schedules a frame for the new surface and the launch sits on the
        // splash screen - and that engine never saw a backgrounded state.
        WidgetsBinding.instance.scheduleForcedFrame();
        _handleAppForegrounded();
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // `hidden` fires on desktop (macOS/Windows) when the window is
        // minimized or hidden, where `paused` often never arrives - without
        // handling it, every background timer and the socket keep running at
        // full foreground cadence forever and drain the battery. On mobile
        // `hidden` precedes `paused`; the _lifecycleBackgrounded guard makes
        // the second call a no-op (and stops `hidden` on the way back up from
        // flapping the socket).
        _handleAppBackgrounded();
        break;
      case AppLifecycleState.detached:
        final cast = ChromecastService();
        if (cast.isConnected) cast.disconnect();
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _handleAppForegrounded() {
    if (!_lifecycleBackgrounded) return;
    _lifecycleBackgrounded = false;
    // The rotation lock lives on the Activity, and Android can recreate the
    // activity over the still-running cached engine (swipe away from recents
    // while playback keeps the service alive). main() doesn't re-run then, so
    // re-apply the saved lock on every return to the foreground.
    applyOrientationLock();
    // Belt-and-suspenders: never let the nav bar come back hidden after a
    // resume. The screens snap their own driver back to shown on next scroll
    // anyway, but mirror it here in case the user resumes onto a stale tab.
    _navBarAnimController.value = 1.0;
    context.read<LibraryProvider>().onAppForegrounded();
    SleepTimerService().onAppForegrounded();
    AudioPlayerService.onAppForegrounded();
    HomeWidgetService().onAppForegrounded();
    ReviewService.onAppForegrounded();
    _refreshDataForTab(_currentIndex);
    // Check auto sleep in case we resumed into the window
    SleepTimerService().checkAutoSleep();
    _checkForUpdate();
  }

  void _handleAppBackgrounded() {
    if (_lifecycleBackgrounded) return;
    _lifecycleBackgrounded = true;
    context.read<LibraryProvider>().onAppBackgrounded();
    SleepTimerService().onAppBackgrounded();
    AudioPlayerService.onAppBackgrounded();
    HomeWidgetService().onAppBackgrounded();
  }

  @override
  void didChangeMetrics() {
    // Orientation change, software keyboard, anything that resizes the window:
    // make sure the bottom nav isn't stuck partway hidden.
    _navBarAnimController.value = 1.0;
    _homeKey.currentState?.resetReveal();
    _libraryKey.currentState?.resetReveal();
  }

  DateTime? _lastRefresh;
  static const _refreshCooldown = Duration(minutes: 1);

  void _refreshDataForTab(int tabIndex) {
    final now = DateTime.now();
    final lib = context.read<LibraryProvider>();

    // Always sync local progress (cheap, no network)
    lib.refreshLocalProgress();

    // Tabs that do not need full personalized shelf rebuilds.
    if (tabIndex == 1 || tabIndex == 2 || tabIndex == 3) {
      unawaited(lib.refreshProgressOnly());
      return;
    }

    // Only do a full server refresh if enough time has passed
    if (_lastRefresh == null ||
        now.difference(_lastRefresh!) > _refreshCooldown) {
      _lastRefresh = now;
      lib.refresh();
      // Keep Android Auto / CarPlay browse tree in sync
      AndroidAutoService().refresh();
      CarPlayService().refreshTemplates();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;

        // If on Library tab with active search, clear search first
        if (_currentIndex == 1 &&
            _libraryKey.currentState?.isSearchActive == true) {
          _libraryKey.currentState?.clearSearch();
          return;
        }

        // If already on Absorbing tab, require double-back to exit
        if (_currentIndex == 2) {
          final now = DateTime.now();
          if (_lastBackPress != null &&
              now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
            SystemChannels.platform.invokeMethod('SystemNavigator.pop', true);
            return;
          }
          _lastBackPress = now;
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context)!.appShellPressBackToExit,
              ),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
          return;
        }

        // From any other tab, go to Absorbing
        _switchToAbsorbing();
      },
      child: Scaffold(
        body: FadeTransition(
          opacity: _fadeController,
          child: IndexedStack(
            index: _currentIndex,
            children: List<Widget>.generate(
              _pages.length,
              (i) => _pages[i] ?? const SizedBox.shrink(),
            ),
          ),
        ),
        bottomNavigationBar: _buildBottomNav(context),
      ),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    // Determine the *correct* notifier for the active tab so we can detect
    // both "no listener" and "listener attached to the wrong tab" — the
    // second happens when LibraryProvider.notify() rebuilds AppShell mid-fade
    // and the lazy attach captures the pre-fade _currentIndex.
    final isHomeOrLibrary = _currentIndex == 0 || _currentIndex == 1;
    ValueListenable<double>? correctNotifier;
    if (_currentIndex == 0) {
      correctNotifier = _homeKey.currentState?.barsRevealNotifier;
    } else if (_currentIndex == 1) {
      correctNotifier = _libraryKey.currentState?.barsRevealNotifier;
    }
    final wrongAttachment =
        isHomeOrLibrary &&
        _navBarListener != null &&
        correctNotifier != null &&
        !identical(_activeBarNotifier, correctNotifier);
    final missingAttachment = isHomeOrLibrary && _navBarListener == null;

    if (missingAttachment || wrongAttachment) {
      final scheduledIndex = _currentIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _currentIndex != scheduledIndex) return;
        _syncNavBarListener(_currentIndex);
        if (_navBarListener == null && _currentIndex == scheduledIndex) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _currentIndex == scheduledIndex) {
              _syncNavBarListener(_currentIndex);
            }
          });
        }
      });
    } else if (!isHomeOrLibrary && _navBarListener != null) {
      // Stale listener left over from a fade transition — detach and snap the
      // nav bar visible so it doesn't get hidden by the previous tab's notifier.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_currentIndex != 0 &&
            _currentIndex != 1 &&
            _navBarListener != null) {
          _detachNavBarListener();
          _navBarAnimController.value = 1.0;
        }
      });
    }
    // On phone landscape, shrink the nav bar so it doesn't eat ~20% of the
    // shorter screen height. Tablets keep the full-size bar in any orientation.
    final mq = MediaQuery.of(context);
    final isTablet = mq.size.shortestSide >= 600;
    final isPhoneLandscape =
        !isTablet && mq.orientation == Orientation.landscape;
    final lib = context.watch<LibraryProvider>();
    final tabs = _visibleTabs(lib);
    final destinations = _buildDestinations(context, tabs);
    return SizeTransition(
      sizeFactor: _navBarAnimController,
      axisAlignment: 1.0,
      // NavigationBar has no per-destination long-press, so map the press x
      // to a destination slot. Plain taps pass through untouched.
      child: GestureDetector(
        onLongPressStart: (details) =>
            _onNavLongPress(details.localPosition.dx, tabs),
        child: NavigationBar(
          selectedIndex: _selectedDest(lib),
          height: isPhoneLandscape ? 56 : null,
          labelBehavior: isPhoneLandscape
              ? NavigationDestinationLabelBehavior.alwaysHide
              : NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (dest) {
            final tab = tabs[dest];
            final page = _stackPageForTab(tab);
            // Re-tapping the active Library destination clears search
            if (tab == 'library' &&
                _currentIndex == 1 &&
                dest == _selectedDest(lib) &&
                _libraryKey.currentState?.isSearchActive == true) {
              _libraryKey.currentState?.clearSearch();
              return;
            }
            _syncTabLibraryForTab(tab);
            _navigateTo(page);
            // Refresh data on switching to Library, Home, Absorbing, or Stats
            if (page == 0 || page == 1 || page == 2 || page == 3) {
              _refreshDataForTab(page);
            }
          },
          destinations: destinations,
        ),
      ),
    );
  }

  void _onNavLongPress(double dx, List<String> tabs) {
    final width = MediaQuery.sizeOf(context).width;
    final count = tabs.length;
    if (width <= 0 || count <= 0) return;
    final slot = (dx / (width / count)).floor().clamp(0, count - 1);
    final tab = tabs[slot];
    if (tab == 'home') {
      // Home: quick library switcher.
      final lib = context.read<LibraryProvider>();
      if (lib.libraries.length < 2) return;
      HapticFeedback.mediumImpact();
      showLibraryPickerSheet(context, lib);
    } else if (tab == 'library') {
      // Library: focus search.
      HapticFeedback.mediumImpact();
      _syncTabLibraryForTab('library');
      _openSearch();
    } else if (tab == 'absorbing') {
      // Absorbing: toggle playback without leaving the current tab.
      if (!_player.hasBook) return;
      HapticFeedback.mediumImpact();
      if (_player.isPlaying) {
        _player.pause();
      } else {
        _player.play();
      }
    }
  }

  List<NavigationDestination> _buildDestinations(
    BuildContext context,
    List<String> tabs,
  ) {
    final l = AppLocalizations.of(context)!;
    final lib = context.watch<LibraryProvider>();
    // Legacy podcast-library relabel (Home->Discover, Library->Shows) only
    // applies when neither real optional tab is present, so the label can't
    // collide with an actual Podcasts/Discover destination.
    final isPodcast = !tabs.contains('podcasts') &&
        !tabs.contains('discover') &&
        lib.isPodcastLibrary;

    // tooltip: '' everywhere: the default label Tooltip registers its own
    // long-press recognizer, which silently wins the gesture arena over the
    // bar-level long-press handler (quick actions per slot).
    NavigationDestination dest(String id) {
      switch (id) {
        case 'home':
          return NavigationDestination(
            icon: Icon(isPodcast ? Icons.explore_outlined : Icons.home_outlined),
            selectedIcon:
                Icon(isPodcast ? Icons.explore_rounded : Icons.home_rounded),
            label: isPodcast ? l.appShellDiscoverTab : l.appShellHomeTab,
            tooltip: '',
          );
        case 'library':
          return NavigationDestination(
            icon: Icon(isPodcast
                ? Icons.podcasts_outlined
                : Icons.library_books_outlined),
            selectedIcon: Icon(isPodcast
                ? Icons.podcasts_rounded
                : Icons.library_books_rounded),
            label: isPodcast ? l.appShellShowsTab : l.appShellLibraryTab,
            tooltip: '',
          );
        case 'podcasts':
          return NavigationDestination(
            icon: const Icon(Icons.podcasts_outlined),
            selectedIcon: const Icon(Icons.podcasts_rounded),
            label: l.appShellPodcastsTab,
            tooltip: '',
          );
        case 'discover':
          return NavigationDestination(
            icon: const Icon(Icons.travel_explore_outlined),
            selectedIcon: const Icon(Icons.travel_explore_rounded),
            label: l.appShellDiscoverTab,
            tooltip: '',
          );
        case 'absorbing':
          return NavigationDestination(
            icon: const _AnimatedWaveIcon(size: 24, active: false),
            selectedIcon: const _AnimatedWaveIcon(size: 24, active: true),
            label: Wording.of(context).appShellAbsorbingTab,
            tooltip: '',
          );
        case 'stats':
          return NavigationDestination(
            icon: const Icon(Icons.bar_chart_rounded),
            selectedIcon: const Icon(Icons.bar_chart_rounded),
            label: l.appShellStatsTab,
            tooltip: '',
          );
        default: // settings
          return NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings_rounded),
            label: l.appShellSettingsTab,
            tooltip: '',
          );
      }
    }

    return [for (final id in tabs) dest(id)];
  }
}

// ─── Animated wave icon for nav bar matching notification icon ────
class _AnimatedWaveIcon extends StatefulWidget {
  final double size;
  final bool active;

  const _AnimatedWaveIcon({required this.size, required this.active});

  @override
  State<_AnimatedWaveIcon> createState() => _AnimatedWaveIconState();
}

class _AnimatedWaveIconState extends State<_AnimatedWaveIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final _player = AudioPlayerService();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _player.addListener(_onPlayerChanged);
    _syncAnimation();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  void _onPlayerChanged() {
    _syncAnimation();
    if (mounted) setState(() {});
  }

  void _syncAnimation() {
    if (_player.isPlaying) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      if (_ctrl.isAnimating) _ctrl.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final playing = _player.isPlaying;

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        size: Size(widget.size, widget.size),
        painter: _NavWavePainter(
          phase: _ctrl.value,
          color: widget.active ? cs.primary : cs.onSurfaceVariant,
          playing: playing,
        ),
      ),
    );
  }
}

class _NavWavePainter extends CustomPainter {
  final double phase;
  final Color color;
  final bool playing;

  _NavWavePainter({
    required this.phase,
    required this.color,
    required this.playing,
  });

  static const _barHeights = [0.35, 0.6, 1.0, 0.6, 0.35];
  static const _barCount = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    final totalWidth = size.width * 0.6;
    final startX = (size.width - totalWidth) / 2;
    final spacing = totalWidth / (_barCount - 1);
    final midY = size.height / 2;
    final maxHalf = size.height * 0.38;

    for (int i = 0; i < _barCount; i++) {
      final x = startX + spacing * i;
      final baseRatio = _barHeights[i];

      if (playing) {
        final barPhase = phase * 2 * math.pi + i * 1.2;
        final ratio = (baseRatio * (0.5 + 0.5 * math.sin(barPhase))).clamp(
          0.2,
          1.0,
        );
        final half = maxHalf * ratio;
        canvas.drawLine(Offset(x, midY - half), Offset(x, midY + half), paint);
      } else {
        final half = maxHalf * baseRatio;
        canvas.drawLine(Offset(x, midY - half), Offset(x, midY + half), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_NavWavePainter old) =>
      old.phase != phase || old.playing != playing || old.color != color;
}
