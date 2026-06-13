import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_service.dart';
import 'api_service.dart';
import 'download_service.dart';
import 'scoped_prefs.dart';
import 'wear_player_service.dart';

const String _androidWidgetName = 'NowPlayingWidget';
const String _androidWidgetCompactName = 'NowPlayingWidgetCompact';
const String _androidWidgetStatsName = 'StatsWidget';
const String _iOSWidgetName = 'NowPlayingWidget';
const String _iOSStatsWidgetName = 'StatsWidget';
const String _appGroupId = 'group.com.barnabas.absorb';
const Duration _statsThrottle = Duration(minutes: 15);

class HomeWidgetService {
  static final HomeWidgetService _instance = HomeWidgetService._();
  factory HomeWidgetService() => _instance;
  HomeWidgetService._();

  Timer? _progressTimer;
  Timer? _statsTimer;
  Timer? _heartbeatTimer;
  Timer? _pendingUpdate;
  String? _lastCoverItemId;
  DateTime? _lastUpdate;
  DateTime? _lastStatsFetch;
  bool _initialized = false;
  bool _updating = false;
  bool _refreshingStats = false;
  StreamSubscription? _clickSub;
  String? _groupContainerPath;

  static const _widgetChannel = MethodChannel('com.absorb.widget');

  // Last authoritative values from the server, plus local additions since
  // then. Lets us tick the widget forward on every playback sync without a
  // network round-trip; refreshStats overwrites the base and resets the
  // accumulators so drift is corrected on every successful server fetch.
  int _todayBase = 0;
  int _weekBase = 0;
  int _localAddedToday = 0;
  int _localAddedWeek = 0;

  /// Call after AudioPlayerService is initialized to start pushing state.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Set up App Group for iOS widget data sharing.
    if (Platform.isIOS) {
      await HomeWidget.setAppGroupId(_appGroupId);
      debugPrint('[WidgetDebug] setAppGroupId=$_appGroupId');
      try {
        _groupContainerPath =
            await _widgetChannel.invokeMethod<String>('getGroupContainerPath');
        debugPrint(
            '[WidgetDebug] groupContainerPath=${_groupContainerPath ?? "<null>"}');
      } catch (e) {
        debugPrint('[WidgetDebug] Failed to get group container path: $e');
      }

      // Receive widget AppIntent actions (and bridged Swift log lines)
      // forwarded from AppDelegate.
      _widgetChannel.setMethodCallHandler((call) async {
        if (call.method == 'widgetAction') {
          final action = (call.arguments as Map?)?['action'] as String?;
          debugPrint('[WidgetDebug] widgetAction received: $action');
          switch (action) {
            case 'playPause':
              await _handlePlayPause();
              break;
            case 'skipBack':
              _handleSkipBack();
              break;
            case 'skipForward':
              _handleSkipForward();
              break;
          }
        } else if (call.method == 'log') {
          final msg = (call.arguments as Map?)?['msg'] as String?;
          if (msg != null) debugPrint('[WidgetDebug] $msg');
        }
        return null;
      });
    }

    final player = AudioPlayerService();
    player.addListener(_onPlayerChanged);

    // Listen for widget click actions (e.g. play/pause button)
    _clickSub = HomeWidget.widgetClicked.listen(_onWidgetClicked);

    // Check if the app was cold-started from a widget tap
    final launchUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    debugPrint('[HomeWidget] initiallyLaunchedFromHomeWidget=$launchUri');
    if (launchUri != null) {
      _onWidgetClicked(launchUri);
    }

    // Push current state in case a widget already exists.
    _scheduleUpdate();
    // Fetch stats in the background so the StatsWidget renders fresh on launch.
    refreshStats();

    // Stats timer runs even while the app is backgrounded so "today" keeps
    // ticking on the widget during long listening sessions without needing
    // the user to open the app. 15-min cadence matches the refresh throttle.
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(_statsThrottle, (_) => refreshStats());

    // Phase 1.4 hand-off heartbeat. The iOS native player core checks this
    // before driving audio: a recent timestamp means Flutter is alive and
    // owns playback, so the native side bails. Stale or missing means
    // Flutter is dead and the widget can take over.
    if (Platform.isIOS) {
      _writeOwnerHeartbeat();
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _writeOwnerHeartbeat(),
      );
    }
  }

  Future<void> _writeOwnerHeartbeat() async {
    try {
      await HomeWidget.saveWidgetData<int>(
        'audio_owner_alive_at',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('[WidgetDebug] heartbeat write failed: $e');
    }
  }

  /// Phase 1.6: read the native player core's last position for an item, so
  /// when Flutter wakes up after a widget-driven session it can pick up
  /// where native left off. Returns null if the stashed `np_item_id` doesn't
  /// match (the app group has data for some other item) or if reads fail.
  ///
  /// iOS only - Android doesn't have the native core path.
  Future<double?> getNativeNowPlayingPosition(
      String itemId, String? episodeId) async {
    if (!Platform.isIOS) return null;
    try {
      final stashedItem = await HomeWidget.getWidgetData<String>('np_item_id');
      if (stashedItem != itemId) return null;
      final stashedEpisode =
          await HomeWidget.getWidgetData<String>('np_episode_id');
      if (stashedEpisode != episodeId) return null;
      final pos = await HomeWidget.getWidgetData<double>('np_position_s');
      return pos;
    } catch (e) {
      debugPrint('[WidgetDebug] getNativeNowPlayingPosition failed: $e');
      return null;
    }
  }

  void dispose() {
    _progressTimer?.cancel();
    _statsTimer?.cancel();
    _heartbeatTimer?.cancel();
    _pendingUpdate?.cancel();
    _clickSub?.cancel();
    AudioPlayerService().removeListener(_onPlayerChanged);
  }

  void _onWidgetClicked(Uri? uri) {
    debugPrint('[HomeWidget] widgetClicked: $uri');
    if (uri == null) return;
    if (uri.host == 'widget') {
      switch (uri.path) {
        case '/play_pause':
          _handlePlayPause();
          break;
        case '/skip_back':
          _handleSkipBack();
          break;
        case '/skip_forward':
          _handleSkipForward();
          break;
        case '/play_item':
          // Triggered by WearPlayerCommandListenerService when the watch
          // taps an item in Continue Listening. Unconditional — replaces
          // any current session (the watch already knows what it picked).
          final itemId = uri.queryParameters['itemId'];
          final rawEpisode = uri.queryParameters['episodeId'];
          final episodeId = (rawEpisode == null || rawEpisode.isEmpty) ? null : rawEpisode;
          if (itemId != null && itemId.isNotEmpty) {
            _handlePlayItem(itemId, episodeId);
          }
          break;
      }
    }
  }

  /// Public entry point for cold-start resume of the last-played item.
  ///
  /// Wraps the original widget play/pause handler so the same restore path
  /// can be invoked from elsewhere (for example from AudioPlayerService when
  /// a media button press hits the service before the UI has bootstrapped
  /// the current item).
  Future<void> resumeLastPlayedIfAvailable() => _handlePlayPause();

  void _handleSkipBack() {
    final player = AudioPlayerService();
    debugPrint('[WidgetDebug] _handleSkipBack hasBook=${player.hasBook}');
    if (!player.hasBook) return;
    player.skipBackward();
  }

  void _handleSkipForward() {
    final player = AudioPlayerService();
    debugPrint('[WidgetDebug] _handleSkipForward hasBook=${player.hasBook}');
    if (!player.hasBook) return;
    player.skipForward();
  }

  /// Start playback of a specific item. Used by the watch's Continue
  /// Listening tap → WearPlayerCommandListenerService → /play_item URI.
  /// Always plays (no toggle path) — the watch already chose which book
  /// it wants and the user expects an immediate switch.
  Future<void> _handlePlayItem(String itemId, String? episodeId) async {
    debugPrint('[HomeWidget] _handlePlayItem itemId=$itemId episodeId=$episodeId');
    final player = AudioPlayerService();

    final prefs = await SharedPreferences.getInstance();
    final serverUrl = prefs.getString('server_url');
    final token = prefs.getString('token');
    if (serverUrl == null || token == null) {
      debugPrint('[HomeWidget] play_item: no session in prefs');
      return;
    }
    final refreshToken = prefs.getString('refresh_token');

    Map<String, String>? customHeaders;
    final headersJson = prefs.getString('custom_headers');
    if (headersJson != null) {
      try {
        customHeaders =
            Map<String, String>.from(jsonDecode(headersJson) as Map);
      } catch (_) {}
    }

    final api = ApiService(
      baseUrl: serverUrl,
      token: token,
      refreshToken: refreshToken,
      isLegacyToken: refreshToken == null,
      customHeaders: customHeaders ?? const {},
    );

    try {
      final fullItem = await api.getLibraryItem(itemId);
      if (fullItem == null) {
        debugPrint('[HomeWidget] play_item: getLibraryItem returned null');
        return;
      }
      final media = fullItem['media'] as Map<String, dynamic>? ?? {};
      final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
      final title = metadata['title'] as String? ?? '';
      final author = metadata['authorName'] as String? ?? '';
      final coverUrl = api.getCoverUrl(itemId);
      final duration = (media['duration'] is num)
          ? (media['duration'] as num).toDouble()
          : 0.0;
      final chapters = (media['chapters'] as List<dynamic>?) ?? [];

      if (episodeId != null) {
        final episodes = (media['episodes'] as List<dynamic>?) ?? [];
        final episode = episodes.cast<Map<String, dynamic>>().firstWhere(
              (e) => e['id'] == episodeId,
              orElse: () => <String, dynamic>{},
            );
        final epTitle = episode['title'] as String? ?? title;
        final epDuration =
            (episode['duration'] as num?)?.toDouble() ?? duration;
        await player.playItem(
          api: api,
          itemId: itemId,
          title: epTitle,
          author: title,
          coverUrl: coverUrl,
          totalDuration: epDuration,
          chapters: const [],
          episodeId: episodeId,
          episodeTitle: epTitle,
        );
      } else {
        await player.playItem(
          api: api,
          itemId: itemId,
          title: title,
          author: author,
          coverUrl: coverUrl,
          totalDuration: duration,
          chapters: chapters,
        );
      }
    } catch (e) {
      debugPrint('[HomeWidget] play_item failed: $e');
    }
  }

  Future<void> _handlePlayPause() async {
    final player = AudioPlayerService();
    debugPrint(
        '[WidgetDebug] _handlePlayPause hasBook=${player.hasBook} isPlaying=${player.isPlaying}\n'
        'Caller:\n${StackTrace.current}');

    // When there's an active session the widget uses a MediaSession media button
    // instead of launching the app, so this path is only hit for cold resume.
    if (player.hasBook) {
      // On iOS, widget links always come through here (no MediaSession shortcut).
      if (Platform.isIOS) {
        if (player.isPlaying) {
          debugPrint('[WidgetDebug]   -> pause()');
          player.pause();
        } else {
          debugPrint('[WidgetDebug]   -> play()');
          player.play();
        }
      }
      return;
    }

    // No active session — cold resume (app stays open for initial setup)
    final prefs = await SharedPreferences.getInstance();
    final itemId = prefs.getString('widget_item_id');
    debugPrint('[HomeWidget] play_pause: cold resume, itemId=$itemId');
    if (itemId == null) return;

    final serverUrl = prefs.getString('server_url');
    final token = prefs.getString('token');
    final refreshToken = prefs.getString('refresh_token');
    debugPrint('[HomeWidget] play_pause: server=${serverUrl != null}, token=${token != null}');
    if (serverUrl == null || token == null) return;

    Map<String, String>? customHeaders;
    final headersJson = prefs.getString('custom_headers');
    if (headersJson != null) {
      try {
        customHeaders =
            Map<String, String>.from(jsonDecode(headersJson) as Map);
      } catch (_) {}
    }

    final api = ApiService(
      baseUrl: serverUrl,
      token: token,
      refreshToken: refreshToken,
      isLegacyToken: refreshToken == null,
      customHeaders: customHeaders ?? const {},
    );

    final episodeId = prefs.getString('widget_episode_id');

    try {
      debugPrint('[HomeWidget] play_pause: fetching item $itemId (episode=$episodeId)');
      final fullItem = await api.getLibraryItem(itemId);
      if (fullItem == null) {
        debugPrint('[HomeWidget] play_pause: getLibraryItem returned null');
        return;
      }

      final media = fullItem['media'] as Map<String, dynamic>? ?? {};
      final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
      final title = metadata['title'] as String? ?? '';
      final author = metadata['authorName'] as String? ?? '';
      final coverUrl = api.getCoverUrl(itemId);
      final duration = (media['duration'] is num)
          ? (media['duration'] as num).toDouble()
          : 0.0;
      final chapters = (media['chapters'] as List<dynamic>?) ?? [];

      if (episodeId != null) {
        final episodes = (media['episodes'] as List<dynamic>?) ?? [];
        final episode = episodes.cast<Map<String, dynamic>>().firstWhere(
              (e) => e['id'] == episodeId,
              orElse: () => <String, dynamic>{},
            );
        final epTitle = episode['title'] as String? ?? title;
        final epDuration =
            (episode['duration'] as num?)?.toDouble() ?? duration;

        await player.playItem(
          api: api,
          itemId: itemId,
          title: epTitle,
          author: title,
          coverUrl: coverUrl,
          totalDuration: epDuration,
          chapters: [],
          episodeId: episodeId,
          episodeTitle: epTitle,
        );
      } else {
        await player.playItem(
          api: api,
          itemId: itemId,
          title: title,
          author: author,
          coverUrl: coverUrl,
          totalDuration: duration,
          chapters: chapters,
        );
      }
    } catch (e) {
      debugPrint('[HomeWidget] Resume playback failed: $e');
    }
  }

  void _onPlayerChanged() {
    // Throttle to max once per 2 seconds, but never drop an update —
    // schedule a deferred one so the final state always gets pushed.
    final now = DateTime.now();
    if (_lastUpdate != null &&
        now.difference(_lastUpdate!).inMilliseconds < 2000) {
      _pendingUpdate?.cancel();
      _pendingUpdate = Timer(const Duration(seconds: 2), _scheduleUpdate);
      return;
    }
    _scheduleUpdate();
  }

  /// Schedule an update on the next microtask so we never do async work
  /// inside the synchronous ChangeNotifier callback.
  void _scheduleUpdate() {
    if (_updating) return;
    _updating = true;
    Future.microtask(() async {
      try {
        await _updateWidgetData();
      } catch (e) {
        debugPrint('[HomeWidget] Update failed: $e');
      } finally {
        _updating = false;
      }
    });
  }

  Future<void> _updateWidgetData() async {
    _lastUpdate = DateTime.now();
    final player = AudioPlayerService();
    final hasBook = player.hasBook;

    debugPrint(
        '[WidgetDebug] _updateWidgetData hasBook=$hasBook isPlaying=${player.isPlaying} title="${player.currentTitle ?? ""}" itemId=${player.currentItemId}');

    await HomeWidget.saveWidgetData<bool>('widget_has_book', hasBook);

    // Push user's skip durations so the widget shows them on the buttons.
    final skipBack = await PlayerSettings.getBackSkip();
    final skipForward = await PlayerSettings.getForwardSkip();
    await HomeWidget.saveWidgetData<int>('widget_skip_back', skipBack);
    await HomeWidget.saveWidgetData<int>('widget_skip_forward', skipForward);

    if (hasBook) {
      await HomeWidget.saveWidgetData<String>(
          'widget_title', player.currentTitle ?? '');
      await HomeWidget.saveWidgetData<String>(
          'widget_author', player.currentAuthor ?? '');
      final chapter = player.currentChapter;
      final chapterTitle = chapter?['title'] as String? ?? '';
      await HomeWidget.saveWidgetData<String>('widget_chapter', chapterTitle);
      await HomeWidget.saveWidgetData<bool>(
          'widget_is_playing', player.isPlaying);

      final totalDur = player.totalDuration;
      final posSec = player.position.inMilliseconds / 1000.0;
      int progress = 0;
      if (totalDur > 0) {
        progress = ((posSec / totalDur) * 1000).round().clamp(0, 1000);
      }
      await HomeWidget.saveWidgetData<int>('widget_progress', progress);

      // Persist item/episode ID so the widget can resume after app kill
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('widget_item_id', player.currentItemId!);
      if (player.currentEpisodeId != null) {
        await prefs.setString('widget_episode_id', player.currentEpisodeId!);
      } else {
        await prefs.remove('widget_episode_id');
      }

      // Phase 1.1: stash the playback state the iOS native player core needs
      // to resume audio without going through Flutter. AbsorbPlayerCore reads
      // these from the app group on widget tap. Keys are `np_*` (Now Playing)
      // to keep them separate from `widget_*` UI fields.
      await _stashPlaybackStateForNativeCore(player);

      // Cover art - fire-and-forget so it doesn't block the update.
      _updateCoverArt(player.currentItemId!);

      if (player.isPlaying) {
        _startProgressTimer();
      } else {
        _stopProgressTimer();
      }
    } else {
      // No active book — just mark as paused but keep the last book's data
      // so the widget still shows it after app close / force stop.
      await HomeWidget.saveWidgetData<bool>('widget_is_playing', false);
      _stopProgressTimer();
    }

    await _updateAllWidgets();
    _pushToWear(player, hasBook, skipBack, skipForward);
  }

  /// Mirror the same snapshot we just wrote to the home widget to the
  /// paired Wear OS companion. No-op off Android / when no watch is
  /// connected; cost is negligible (one MethodChannel call).
  void _pushToWear(
    AudioPlayerService player,
    bool hasBook,
    int skipBack,
    int skipForward,
  ) {
    if (!Platform.isAndroid) return;
    final chapterTitle = player.currentChapter?['title'] as String?;
    WearPlayerService.instance.publish(
      hasBook: hasBook,
      itemId: hasBook ? player.currentItemId : null,
      title: hasBook ? player.currentTitle : null,
      author: hasBook ? player.currentAuthor : null,
      chapter: hasBook ? chapterTitle : null,
      isPlaying: player.isPlaying,
      positionMs: player.position.inMilliseconds,
      durationMs: (player.totalDuration * 1000).round(),
      speed: player.speed.toDouble(),
      skipBackSec: skipBack,
      skipForwardSec: skipForward,
    );
  }

  /// Phase 1.1: write everything the iOS native player core needs to resume
  /// playback without Flutter being alive. Lives in the same app group so
  /// `AbsorbPlayerCore` (Swift) can read it via `UserDefaults(suiteName:)`.
  ///
  /// Streaming case (Phase 2) will need the server URL + auth token too;
  /// for now we only stash the file paths so Phase 1.3 (downloaded books)
  /// can play.
  Future<void> _stashPlaybackStateForNativeCore(AudioPlayerService player) async {
    final itemId = player.currentItemId;
    if (itemId == null) return;
    await HomeWidget.saveWidgetData<String>('np_item_id', itemId);
    await HomeWidget.saveWidgetData<String?>('np_episode_id', player.currentEpisodeId);

    final posSec = player.position.inMilliseconds / 1000.0;
    await HomeWidget.saveWidgetData<double>('np_position_s', posSec);
    await HomeWidget.saveWidgetData<double>('np_total_s', player.totalDuration);
    await HomeWidget.saveWidgetData<double>('np_speed', player.speed);

    // Chapters serialize as a JSON array of {start, end, title} maps. The
    // native side decodes lazily; if decoding fails we fall back to no
    // chapter info and play the file straight through.
    try {
      await HomeWidget.saveWidgetData<String>(
          'np_chapters_json', jsonEncode(player.chapters));
    } catch (e) {
      debugPrint('[WidgetDebug] chapter encode failed: $e');
      await HomeWidget.saveWidgetData<String>('np_chapters_json', '[]');
    }

    // Downloaded audio file paths (one per track for multi-file books).
    final download = DownloadService().getInfo(itemId);
    final paths = download.localPaths;
    await HomeWidget.saveWidgetData<String>(
        'np_audio_paths_json', jsonEncode(paths));
    await HomeWidget.saveWidgetData<bool>('np_is_downloaded', paths.isNotEmpty);

    // Streaming endpoints (token already in URL, plus any reverse-proxy
    // headers like Cloudflare Access). Native picks these up when
    // np_is_downloaded is false.
    await HomeWidget.saveWidgetData<String>(
        'np_stream_urls_json', jsonEncode(player.activeStreamUrls));
    await HomeWidget.saveWidgetData<String>(
        'np_stream_headers_json', jsonEncode(player.activeStreamHeaders));

    // Multi-track support: cumulative track start offsets so the native
    // core can figure out which track contains a given absolute position
    // (e.g. saved-position 4500s in a 3-file book might fall in track 2).
    await HomeWidget.saveWidgetData<String>(
        'np_track_offsets_json', jsonEncode(player.trackStartOffsets));

    // Server URL + API token so the native core can push progress updates
    // directly to ABS while Flutter is dead. Lets users listen for hours
    // via the widget without their server progress falling behind.
    final api = player.currentApi;
    if (api != null) {
      await HomeWidget.saveWidgetData<String>('np_server_url', api.baseUrl);
      await HomeWidget.saveWidgetData<String>('np_api_token', api.token);
    }

    // Cover path piggybacks on the existing widget_cover_path entry, but
    // expose it under the np_ namespace too for clarity on the native side.
    final coverPath = await HomeWidget.getWidgetData<String>('widget_cover_path');
    if (coverPath != null) {
      await HomeWidget.saveWidgetData<String>('np_cover_path', coverPath);
    }
    await HomeWidget.saveWidgetData<String>(
        'np_title', player.currentTitle ?? '');
    await HomeWidget.saveWidgetData<String>(
        'np_author', player.currentAuthor ?? '');

    debugPrint('[WidgetDebug] [NativeCore] Stashed: item=$itemId ep=${player.currentEpisodeId} '
        'pos=${posSec.toStringAsFixed(1)}s tot=${player.totalDuration.toStringAsFixed(0)}s '
        'speed=${player.speed} dl=${paths.isNotEmpty} '
        'streams=${player.activeStreamUrls.length} '
        'tracks=${player.trackStartOffsets.length} '
        'server=${api?.baseUrl ?? "none"}');
  }

  Future<void> _updateAllWidgets() async {
    if (Platform.isAndroid) {
      await HomeWidget.updateWidget(name: _androidWidgetName);
      await HomeWidget.updateWidget(name: _androidWidgetCompactName);
      await HomeWidget.updateWidget(name: _androidWidgetStatsName);
    } else if (Platform.isIOS) {
      await HomeWidget.updateWidget(iOSName: _iOSWidgetName);
      await HomeWidget.updateWidget(iOSName: _iOSStatsWidgetName);
    }
  }

  Future<void> _updateStatsWidget() async {
    if (Platform.isAndroid) {
      await HomeWidget.updateWidget(name: _androidWidgetStatsName);
    } else if (Platform.isIOS) {
      await HomeWidget.updateWidget(iOSName: _iOSStatsWidgetName);
    }
  }

  /// Fetch listening stats from the server and push them to the StatsWidget.
  /// Throttled to once per 15 minutes since stats drift slowly. Pass `force`
  /// to bypass the throttle (e.g. on app foreground after a long gap).
  /// Wipe stats values so a stale user's numbers don't linger on the widget
  /// during an account switch. Call before refreshStats so the widget shows
  /// zeros for the few hundred ms until the new user's data arrives.
  Future<void> clearStats() async {
    try {
      await HomeWidget.saveWidgetData<int>('widget_stats_today', 0);
      await HomeWidget.saveWidgetData<int>('widget_stats_week', 0);
      await HomeWidget.saveWidgetData<int>('widget_stats_streak', 0);
      await HomeWidget.saveWidgetData<int>('widget_stats_books_year', 0);
      await _updateStatsWidget();
      _lastStatsFetch = null;
      debugPrint('[StatsWidget] Cleared (account switch or logout)');
    } catch (e) {
      debugPrint('[StatsWidget] Clear failed: $e');
    }
  }

  Future<void> refreshStats({bool force = false}) async {
    if (_refreshingStats) {
      debugPrint('[StatsWidget] Skipping refresh: already in flight');
      return;
    }
    if (!force && _lastStatsFetch != null) {
      final since = DateTime.now().difference(_lastStatsFetch!);
      if (since < _statsThrottle) {
        debugPrint('[StatsWidget] Skipping refresh: ${since.inSeconds}s since last (throttle=${_statsThrottle.inSeconds}s)');
        return;
      }
    }
    _refreshingStats = true;
    try {
      final api = await _buildApiService();
      if (api == null) {
        debugPrint('[StatsWidget] Skipping refresh: no server/token in prefs');
        return;
      }

      debugPrint('[StatsWidget] Fetching listening-stats and /me');
      final stats = await api.getListeningStats();
      final me = await api.getMe();

      if (stats == null) debugPrint('[StatsWidget] listening-stats returned null');
      if (me == null) debugPrint('[StatsWidget] /me returned null');

      // Both calls failed - the server is unreachable. Don't blow away the
      // widget with zeros; leave whatever it was showing in place.
      if (stats == null && me == null) {
        debugPrint('[StatsWidget] Both fetches failed - keeping last values');
        return;
      }
      _lastStatsFetch = DateTime.now();

      final dailyMap = _extractDailyMap(stats);
      final today = _todaySeconds(dailyMap).round();
      final week = _weekSeconds(dailyMap).round();
      final streak = _currentStreak(dailyMap);
      final hidden = (await ScopedPrefs.getStringList('year_hidden_ids')).toSet();
      final booksYear = _countBooksFinishedThisYear(me, hidden);

      debugPrint('[StatsWidget] Computed: today=${today}s week=${week}s streak=${streak}d booksThisYear=$booksYear (dailyMapKeys=${dailyMap.length})');

      _todayBase = today;
      _weekBase = week;
      _localAddedToday = 0;
      _localAddedWeek = 0;

      await HomeWidget.saveWidgetData<int>('widget_stats_today', today);
      await HomeWidget.saveWidgetData<int>('widget_stats_week', week);
      await HomeWidget.saveWidgetData<int>('widget_stats_streak', streak);
      await HomeWidget.saveWidgetData<int>('widget_stats_books_year', booksYear);
      await _updateStatsWidget();
      debugPrint('[StatsWidget] Pushed and updateWidget(StatsWidget) called');
    } catch (e) {
      debugPrint('[StatsWidget] Refresh failed: $e');
    } finally {
      _refreshingStats = false;
    }
  }

  /// Tick the widget's "today" and "this week" totals forward without hitting
  /// the server. Called from the player's sync path after real playing time
  /// accumulates, so the widget stays fresh while the app is backgrounded and
  /// the 15-min stats timer is throttled by Android Doze.
  Future<void> addLocalListeningSeconds(int seconds) async {
    if (seconds <= 0) return;
    _localAddedToday += seconds;
    _localAddedWeek += seconds;
    try {
      await HomeWidget.saveWidgetData<int>(
          'widget_stats_today', _todayBase + _localAddedToday);
      await HomeWidget.saveWidgetData<int>(
          'widget_stats_week', _weekBase + _localAddedWeek);
      await _updateStatsWidget();
    } catch (e) {
      debugPrint('[StatsWidget] Local add failed: $e');
    }
  }

  Future<ApiService?> _buildApiService() async {
    final prefs = await SharedPreferences.getInstance();
    final remoteUrl = prefs.getString('server_url');
    final token = prefs.getString('token');
    if (remoteUrl == null || token == null) return null;
    final refreshToken = prefs.getString('refresh_token');

    Map<String, String>? customHeaders;
    final headersJson = prefs.getString('custom_headers');
    if (headersJson != null) {
      try {
        customHeaders =
            Map<String, String>.from(jsonDecode(headersJson) as Map);
      } catch (_) {}
    }
    final headers = customHeaders ?? const <String, String>{};

    // Prefer the local server if the user has it enabled and it's reachable -
    // when the device is on home WiFi, the remote URL (reverse proxy) may not
    // route, so always-using-remote would write zeros to the widget.
    String baseUrl = remoteUrl;
    final localEnabled = await PlayerSettings.getLocalServerEnabled();
    final localUrl = await PlayerSettings.getLocalServerUrl();
    if (localEnabled && localUrl.isNotEmpty) {
      final localReachable = await ApiService.pingServer(localUrl, customHeaders: headers)
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
      if (localReachable) baseUrl = localUrl;
    }

    return ApiService(
      baseUrl: baseUrl,
      token: token,
      refreshToken: refreshToken,
      isLegacyToken: refreshToken == null,
      customHeaders: headers,
    );
  }

  Map<String, dynamic> _extractDailyMap(Map<String, dynamic>? stats) {
    if (stats == null) return {};
    for (final key in ['dayListeningMap', 'days']) {
      final val = stats[key];
      if (val is Map<String, dynamic>) return val;
    }
    return {};
  }

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  double _daySeconds(Map<String, dynamic> map, String key) {
    final val = map[key];
    if (val is num) return val.toDouble();
    if (val is Map) {
      final t = val['timeListening'];
      if (t is num && t > 0) return t.toDouble();
      final total = val['totalTime'];
      if (total is num) return total.toDouble();
    }
    return 0;
  }

  double _todaySeconds(Map<String, dynamic> dailyMap) =>
      _daySeconds(dailyMap, _dateKey(DateTime.now()));

  double _weekSeconds(Map<String, dynamic> dailyMap) {
    final now = DateTime.now();
    double total = 0;
    for (int i = 0; i < 7; i++) {
      total += _daySeconds(dailyMap, _dateKey(now.subtract(Duration(days: i))));
    }
    return total;
  }

  int _currentStreak(Map<String, dynamic> dailyMap) {
    int streak = 0;
    final now = DateTime.now();
    final startOffset = _daySeconds(dailyMap, _dateKey(now)) > 0 ? 0 : 1;
    for (int i = startOffset; i < 365; i++) {
      if (_daySeconds(dailyMap, _dateKey(now.subtract(Duration(days: i)))) > 0) {
        streak++;
      } else {
        break;
      }
    }
    return streak;
  }

  int _countBooksFinishedThisYear(Map<String, dynamic>? me, Set<String> hidden) {
    if (me == null) return 0;
    final progress = me['mediaProgress'];
    if (progress is! List) return 0;
    final year = DateTime.now().year;
    var count = 0;
    for (final entry in progress) {
      if (entry is! Map) continue;
      if (entry['isFinished'] != true) continue;
      // episodeId is non-null for podcast entries — exclude so the "books"
      // count doesn't inflate with every finished podcast episode.
      final episodeId = entry['episodeId'];
      if (episodeId is String && episodeId.isNotEmpty) continue;
      final id = entry['libraryItemId'];
      if (id is String && hidden.contains(id)) continue;
      final raw = entry['finishedAt'];
      if (raw is! num) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
      if (dt.year == year) count++;
    }
    return count;
  }

  Future<void> _updateCoverArt(String itemId) async {
    final player = AudioPlayerService();
    final coverUrl = player.currentCoverUrl;
    final cacheKey = '$itemId|$coverUrl';
    if (_lastCoverItemId == cacheKey) {
      debugPrint('[WidgetDebug] cover unchanged, skipping (key=$cacheKey)');
      return;
    }
    _lastCoverItemId = cacheKey;

    String? coverPath;
    String source = 'none';

    try {
      // Check for a locally downloaded cover first.
      final downloadService = DownloadService();
      if (downloadService.isDownloaded(itemId)) {
        coverPath = await downloadService.getLocalCoverPath(itemId);
        source = 'download';
      }

      // If no local cover, download from server to a temp/shared file.
      if (coverPath == null) {
        if (coverUrl != null && coverUrl.isNotEmpty) {
          final coverDir = await _getCoverDirectory();
          final coverFile = File('${coverDir.path}/$itemId.jpg');

          final response = await http
              .get(Uri.parse(coverUrl))
              .timeout(const Duration(seconds: 10));
          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            await coverFile.writeAsBytes(response.bodyBytes);
            coverPath = coverFile.path;
            source = 'network';
          } else {
            source = 'network_failed(${response.statusCode})';
          }
        }
      } else if (Platform.isIOS && _groupContainerPath != null) {
        // On iOS, local cover is in the app sandbox - copy to shared container.
        final sharedDir = await _getCoverDirectory();
        final sharedFile = File('${sharedDir.path}/$itemId.jpg');
        if (!sharedFile.existsSync()) {
          await File(coverPath).copy(sharedFile.path);
        }
        coverPath = sharedFile.path;
        source = 'download_copied_to_group';
      }
    } catch (e) {
      debugPrint('[WidgetDebug] cover update failed: $e');
    }

    final pathInGroup =
        coverPath != null && _groupContainerPath != null && coverPath.startsWith(_groupContainerPath!);
    final exists = coverPath != null && File(coverPath).existsSync();
    debugPrint(
        '[WidgetDebug] cover source=$source path=$coverPath exists=$exists inAppGroup=$pathInGroup');

    try {
      await HomeWidget.saveWidgetData<String?>('widget_cover_path', coverPath);
      await _updateAllWidgets();
    } catch (e) {
      debugPrint('[WidgetDebug] cover save failed: $e');
    }
  }

  /// Returns the directory for widget cover art.
  /// On iOS, uses the App Group shared container so the widget extension can
  /// read the files. On Android, uses the app's temp directory.
  Future<Directory> _getCoverDirectory() async {
    if (Platform.isIOS && _groupContainerPath != null) {
      final dir = Directory('$_groupContainerPath/widget_covers');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
    final cacheDir = await getTemporaryDirectory();
    final dir = Directory('${cacheDir.path}/widget_covers');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  void _startProgressTimer() {
    if (_progressTimer?.isActive == true) return;
    _progressTimer = Timer.periodic(const Duration(seconds: 120), (_) {
      _scheduleUpdate();
      // Piggyback a stats refresh; the 15-min throttle inside refreshStats
      // keeps this cheap even though the timer ticks every 2 minutes.
      refreshStats();
    });
  }

  void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void onAppBackgrounded() {
    _stopProgressTimer();
  }

  void onAppForegrounded() {
    if (AudioPlayerService().isPlaying) {
      _startProgressTimer();
      _scheduleUpdate();
    }
    refreshStats();
  }
}
