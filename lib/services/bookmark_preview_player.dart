import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'api_service.dart';
import 'audio_player_service.dart';
import 'download_service.dart';

/// Auditions a book at a given position WITHOUT moving the user's real playback
/// position. Resolves audio for ANY book - downloaded (local files) or streamed
/// (per-file URLs built on demand). Pauses the main player while auditioning and
/// restores it on stop/dispose. Owned by the bookmark detail dialog.
class BookmarkPreviewPlayer extends ChangeNotifier {
  BookmarkPreviewPlayer({required this.itemId, this.api});

  final String itemId;
  final ApiService? api;

  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSub;
  bool _loading = false;
  bool _playing = false;
  bool _disposed = false;
  bool? _mainWasPlaying;
  Timer? _autoStop;

  /// The audition auto-stops after this long so a single tap never plays the
  /// rest of the book (a single-file m4b would otherwise run for hours). Plenty
  /// for a bookmark preview; easy to bump or wire to a setting.
  static const Duration _autoStopAfter = Duration(seconds: 60);

  // (source path/url, track duration seconds, isLocal) resolved once per book.
  List<({String source, double duration, bool local})>? _tracks;

  bool get isLoading => _loading;
  bool get isPlaying => _playing;

  /// Toggle playback at [globalSeconds]. Pauses if playing, resumes if paused,
  /// otherwise loads + plays from that position. Throws on resolve/playback
  /// failure so the UI can show a message.
  Future<void> toggleAt(double globalSeconds) async {
    final p = _player;
    if (p != null) {
      if (p.playing) {
        _autoStop?.cancel();
        await p.pause();
      } else {
        _pauseMain();
        _startAutoStop();
        await p.play();
      }
      return;
    }
    await _playAt(globalSeconds);
  }

  Future<void> _playAt(double globalSeconds) async {
    _loading = true;
    notifyListeners();
    _pauseMain();

    final tracks = await _resolveTracks();
    if (_disposed) return;
    if (tracks == null || tracks.isEmpty) {
      debugPrint('[BookmarkPreview] $itemId: no tracks resolved');
      _loading = false;
      notifyListeners();
      throw StateError('no audio for $itemId');
    }

    // Map the global position to a track + local offset.
    var acc = 0.0;
    var idx = tracks.length - 1;
    var local = globalSeconds;
    for (var i = 0; i < tracks.length; i++) {
      if (globalSeconds < acc + tracks[i].duration || i == tracks.length - 1) {
        idx = i;
        final upper = tracks[i].duration > 0 ? tracks[i].duration : globalSeconds;
        local = (globalSeconds - acc).clamp(0.0, upper);
        break;
      }
      acc += tracks[i].duration;
    }
    final track = tracks[idx];
    debugPrint('[BookmarkPreview] $itemId: play ${globalSeconds.toStringAsFixed(1)}s -> '
        'track[$idx] ${track.local ? "local" : "stream"} @${local.toStringAsFixed(1)}s');

    try {
      await _disposePlayer();
      // Match the main player: no localhost proxy on Android. The proxy was
      // aborting large seeks into single-file streamed books ("Connection
      // aborted"); without it ExoPlayer ranges the server directly. Token auth
      // rides in the URL (buildFileUrl), so streaming still authenticates.
      final player = AudioPlayer(useProxyForRequestHeaders: false);
      _player = player;
      _stateSub = player.playerStateStream.listen((s) {
        if (_disposed) return;
        final done = s.processingState == ProcessingState.completed;
        _loading = s.processingState == ProcessingState.loading ||
            s.processingState == ProcessingState.buffering;
        _playing = s.playing && !done;
        notifyListeners();
        if (done) player.pause();
      });
      if (track.local) {
        await player.setAudioSource(AudioSource.file(track.source));
      } else {
        await player.setAudioSource(
            AudioSource.uri(Uri.parse(track.source), headers: api?.mediaHeaders));
      }
      await player.seek(Duration(milliseconds: (local * 1000).round()));
      // Start the auto-stop BEFORE awaiting play(): just_audio's play() future
      // doesn't complete until playback ends, so a timer after it never armed -
      // that's why the 60s cap wasn't firing.
      _startAutoStop();
      await player.play();
    } catch (e) {
      debugPrint('[BookmarkPreview] $itemId: playback error: $e');
      _loading = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<List<({String source, double duration, bool local})>?> _resolveTracks() async {
    if (_tracks != null) return _tracks;

    // Downloaded book: local files + cached track durations.
    final localPaths = DownloadService().getLocalPaths(itemId);
    final sessionRaw = DownloadService().getCachedSessionData(itemId);
    if (localPaths != null && localPaths.isNotEmpty && sessionRaw != null) {
      try {
        final session = jsonDecode(sessionRaw) as Map<String, dynamic>;
        final audioTracks = session['audioTracks'] as List<dynamic>?;
        if (audioTracks != null && audioTracks.length == localPaths.length) {
          _tracks = [
            for (var i = 0; i < localPaths.length; i++)
              (
                source: localPaths[i],
                duration: ((audioTracks[i] as Map<String, dynamic>)['duration'] as num?)?.toDouble() ?? 0,
                local: true,
              ),
          ];
          debugPrint('[BookmarkPreview] $itemId: ${_tracks!.length} local track(s)');
          return _tracks;
        }
      } catch (_) {}
    }

    // Streamed book: build per-file URLs from the library item.
    if (api == null) {
      debugPrint('[BookmarkPreview] $itemId: no api (not downloaded, not logged in?)');
      return null;
    }
    final item = await api!.getLibraryItem(itemId);
    if (item == null) {
      debugPrint('[BookmarkPreview] $itemId: getLibraryItem returned null');
      return null;
    }
    final media = item['media'] as Map<String, dynamic>? ?? {};
    final audioFiles = ((media['audioFiles'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList()
      ..sort((a, b) => ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0));
    if (audioFiles.isEmpty) {
      debugPrint('[BookmarkPreview] $itemId: library item has no audioFiles');
      return null;
    }
    _tracks = [
      for (final af in audioFiles)
        (
          source: api!.buildFileUrl(itemId, af['ino']?.toString() ?? ''),
          duration: (af['duration'] as num?)?.toDouble() ?? 0,
          local: false,
        ),
    ];
    debugPrint('[BookmarkPreview] $itemId: ${_tracks!.length} streamed track(s)');
    return _tracks;
  }

  void _pauseMain() {
    final main = AudioPlayerService();
    _mainWasPlaying ??= main.isPlaying;
    if (main.isPlaying) main.pause();
  }

  void _startAutoStop() {
    _autoStop?.cancel();
    _autoStop = Timer(_autoStopAfter, () {
      debugPrint('[BookmarkPreview] auto-stop after ${_autoStopAfter.inSeconds}s');
      _player?.pause();
    });
  }

  Future<void> _disposePlayer() async {
    _autoStop?.cancel();
    _autoStop = null;
    await _stateSub?.cancel();
    _stateSub = null;
    final p = _player;
    _player = null;
    _playing = false;
    if (p != null) {
      try {
        await p.stop();
        await p.dispose();
      } catch (_) {}
    }
  }

  /// Stop the audition and resume the main player if we had paused it.
  Future<void> stop() async {
    await _disposePlayer();
    if (_mainWasPlaying == true) {
      _mainWasPlaying = null;
      await AudioPlayerService().play();
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _autoStop?.cancel();
    _stateSub?.cancel();
    _player?.dispose();
    if (_mainWasPlaying == true) AudioPlayerService().play();
    super.dispose();
  }
}
