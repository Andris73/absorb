import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Pushes the active playback snapshot to the paired Wear OS companion
/// (AbsorbWear) via the Wearable Data Layer.
///
/// Like [WearAuthService] this is best-effort and a no-op off Android.
/// We piggyback on the existing HomeWidgetService update cadence (~2s),
/// so the bandwidth profile is identical to what the home widget
/// already costs.
class WearPlayerService {
  WearPlayerService._();
  static final WearPlayerService instance = WearPlayerService._();

  static const MethodChannel _channel =
      MethodChannel('com.barnabas.absorb/wear_player');

  bool get _supported => !kIsWeb && Platform.isAndroid;

  Future<void> publish({
    required bool hasBook,
    String? itemId,
    String? title,
    String? author,
    String? chapter,
    required bool isPlaying,
    required int positionMs,
    required int durationMs,
    required double speed,
    required int skipBackSec,
    required int skipForwardSec,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('publish', {
        'hasBook': hasBook,
        'itemId': itemId,
        'title': title,
        'author': author,
        'chapter': chapter,
        'isPlaying': isPlaying,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'speed': speed,
        'skipBackSec': skipBackSec,
        'skipForwardSec': skipForwardSec,
      });
    } catch (e) {
      debugPrint('[WearPlayer] publish failed: $e');
    }
  }
}
