import Foundation

/// Protocol shared between the host app (Runner) and the widget extension.
///
/// The widget intents declare `@Dependency var core: AbsorbPlayerCoreProtocol`,
/// and the host app's AppDelegate registers a concrete singleton via
/// `AppDependencyManager.shared.add(dependency:)`. This is what tells iOS to
/// run the intent in the host app's process rather than the widget extension
/// process - without that, the widget's `perform()` can't reach the audio
/// engine that lives in the host app.
public protocol AbsorbPlayerCoreProtocol: Sendable {
  func play()
  func pause()
  func toggle()
  func skipForward(seconds: Int)
  func skipBackward(seconds: Int)

  /// What a toggle() issued right now would leave playback doing. The widget
  /// play/pause intent writes this prediction to `widget_is_playing` for
  /// instant icon feedback. Unlike blindly inverting the stored flag, this
  /// stays correct when the flag is stale (e.g. iOS killed the app while it
  /// was playing, so the flag stuck on true and a cold widget play would
  /// otherwise show the wrong icon).
  func willPlayAfterToggle() -> Bool

  /// Routes a log line through to the host app's Flutter log sink so it
  /// surfaces in absorb's in-app log viewer. Widget intents running in the
  /// host app process via @Dependency can use this to record progress
  /// without needing Xcode/Console.app to see NSLog output.
  func log(_ message: String)
}
