/// F-Droid stand-in for review_service.dart - the build copies this file
/// over it and strips the in_app_review dependency, since the Play Core
/// review library fails the F-Droid scanner. No store, no review prompt.
class ReviewService {
  static Future<void> onBookFinished({required bool isForeground}) async {}

  static Future<void> onAppForegrounded() async {}
}
