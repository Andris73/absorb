import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One-time store review prompt, fired after the user naturally finishes a
/// book. The stores own the display rules: iOS suppresses it entirely on
/// TestFlight and caps prompts per year, Play only shows it for
/// Play-installed builds (isAvailable is false for sideloaded APKs).
///
/// The F-Droid build replaces this file with review_service_stub.dart at
/// build time - the Play Core review dependency would fail the F-Droid
/// scanner (same treatment as the Chromecast plugin).
class ReviewService {
  static const _shownKey = 'review_prompt_shown';
  static const _pendingKey = 'review_prompt_pending';

  /// Call when a book (not a podcast episode) finishes naturally. Neither OS
  /// will display the dialog from the background, so park a pending flag and
  /// fire on the next foreground instead of burning the one shot invisibly.
  static Future<void> onBookFinished({required bool isForeground}) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_shownKey) ?? false) return;
    if (!isForeground) {
      await prefs.setBool(_pendingKey, true);
      return;
    }
    await _request(prefs);
  }

  /// Call on app resume to fire a prompt parked by a background finish.
  static Future<void> onAppForegrounded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_shownKey) ?? false) return;
    if (!(prefs.getBool(_pendingKey) ?? false)) return;
    // Let the resume settle so the dialog doesn't collide with launch UI.
    await Future.delayed(const Duration(seconds: 2));
    await _request(prefs);
  }

  static Future<void> _request(SharedPreferences prefs) async {
    try {
      final review = InAppReview.instance;
      // Not a store install - keep the pending flag so a store build of the
      // same install could still prompt later.
      if (!await review.isAvailable()) return;
      await prefs.setBool(_shownKey, true);
      await prefs.remove(_pendingKey);
      await review.requestReview();
    } catch (e) {
      debugPrint('[Review] requestReview failed: $e');
    }
  }
}
