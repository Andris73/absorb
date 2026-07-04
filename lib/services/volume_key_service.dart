import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'audio_player_service.dart';

/// Turns the physical volume keys into ebook page turns while a reader is
/// open. The native side (MainActivity / AppDelegate) consumes the presses so
/// system volume never moves; this wrapper decides WHEN to watch - reader
/// setting on, app in the foreground, and audio not playing (unless the
/// while-playing option is on) - and maps presses to page turns.
class EreaderVolumeNav with WidgetsBindingObserver {
  EreaderVolumeNav({required this.onPrev, required this.onNext});

  final VoidCallback onPrev;
  final VoidCallback onNext;

  static const _channel = MethodChannel('com.absorb.volume_keys');
  // Only one reader is ever open; the channel handler routes to it.
  static EreaderVolumeNav? _active;

  String _mode = 'off';
  bool _whilePlaying = false;
  bool _watching = false;
  bool _attached = false;

  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    _active = this;
    _channel.setMethodCallHandler(_onCall);
    WidgetsBinding.instance.addObserver(this);
    AudioPlayerService().addListener(_reevaluate);
    PlayerSettings.settingsChanged.addListener(_reloadSettings);
    await _reloadSettings();
  }

  Future<void> detach() async {
    if (!_attached) return;
    _attached = false;
    if (identical(_active, this)) _active = null;
    WidgetsBinding.instance.removeObserver(this);
    AudioPlayerService().removeListener(_reevaluate);
    PlayerSettings.settingsChanged.removeListener(_reloadSettings);
    await _setWatching(false);
  }

  Future<void> _reloadSettings() async {
    _mode = await PlayerSettings.getEreaderVolumeNav();
    _whilePlaying = await PlayerSettings.getEreaderVolumeNavWhilePlaying();
    _reevaluate();
  }

  void _reevaluate() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    final playing = AudioPlayerService().isPlaying;
    final want =
        _attached && _mode != 'off' && foreground && (_whilePlaying || !playing);
    _setWatching(want);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _reevaluate();

  Future<void> _setWatching(bool want) async {
    if (want == _watching) return;
    _watching = want;
    try {
      await _channel.invokeMethod(want ? 'watch' : 'clearWatch');
    } catch (_) {}
  }

  static Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'volumePressed') return null;
    final nav = _active;
    if (nav == null || !nav._watching) return null;
    final up = (call.arguments as String? ?? '') == 'up';
    // 'normal' matches the ABS app: volume up = previous page, down = next.
    final prev = nav._mode == 'mirrored' ? !up : up;
    if (prev) {
      nav.onPrev();
    } else {
      nav.onNext();
    }
    return null;
  }
}
