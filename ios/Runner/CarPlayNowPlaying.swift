import CarPlay
import Flutter
import UIKit

/// Adds custom buttons (previous/next chapter, playback speed, bookmark) to the
/// CarPlay Now Playing screen.
///
/// These buttons live ONLY on CarPlay's `CPNowPlayingTemplate` and never touch
/// the lock screen / Control Center, which are driven separately by
/// `MPRemoteCommandCenter`. That separation is the whole point: CarPlay gets a
/// richer control set without changing the phone's media player.
///
/// `CPNowPlayingTemplate.shared` is a system singleton, so we can decorate it
/// from here even though flutter_carplay owns the CarPlay scene. Button taps are
/// forwarded to Dart over the `com.absorb.carplay` channel and handled by
/// `AudioPlayerHandler.customAction`.
@objc class CarPlayNowPlaying: NSObject {
  @objc static let shared = CarPlayNowPlaying()

  private var channel: FlutterMethodChannel?

  @objc func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.absorb.carplay", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setupNowPlayingButtons":
        let speed = (call.arguments as? [String: Any])?["speed"] as? Double ?? 1.0
        self?.configureButtons(speed: speed)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func configureButtons(speed: Double) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let prevChapter = CPNowPlayingImageButton(image: Self.symbol("backward.end.fill")) { [weak self] _ in
        self?.send("previousChapter")
      }
      let nextChapter = CPNowPlayingImageButton(image: Self.symbol("forward.end.fill")) { [weak self] _ in
        self?.send("nextChapter")
      }
      // Custom image button that renders the live rate (e.g. "1.5x") so the
      // driver can read the current speed at a glance, then cycle it with a tap.
      let speedButton = CPNowPlayingImageButton(image: Self.speedImage(speed)) { [weak self] _ in
        self?.send("cycleSpeed")
      }
      let bookmark = CPNowPlayingImageButton(image: Self.symbol("bookmark.fill")) { [weak self] _ in
        self?.send("bookmark")
      }
      let buttons: [CPNowPlayingButton] = [prevChapter, nextChapter, speedButton, bookmark]
      CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
      NSLog("[CarPlay] Now Playing buttons configured (speed \(speed)x)")
    }
  }

  private func send(_ action: String) {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("carPlayButton", arguments: ["action": action])
    }
  }

  /// SF Symbols are template images, so CarPlay tints them to match the head
  /// unit theme automatically. We deliberately pass NO size configuration so
  /// CarPlay applies its own now-playing button metrics - forcing a large
  /// point size is what made these icons look oversized and bulky.
  private static func symbol(_ name: String) -> UIImage {
    return UIImage(systemName: name) ?? UIImage()
  }

  /// Renders the current playback rate (e.g. "1.5x") into a template image so it
  /// can sit in a CPNowPlayingImageButton. Template rendering lets CarPlay tint
  /// it to match the head unit theme.
  private static func speedImage(_ speed: Double) -> UIImage {
    let text = formatSpeed(speed) as NSString
    let attrs: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 23, weight: .semibold),
      .foregroundColor: UIColor.white,
    ]
    let textSize = text.size(withAttributes: attrs)
    let size = CGSize(width: ceil(textSize.width) + 8, height: ceil(textSize.height) + 4)
    let image = UIGraphicsImageRenderer(size: size).image { _ in
      let rect = CGRect(
        x: (size.width - textSize.width) / 2,
        y: (size.height - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height)
      text.draw(in: rect, withAttributes: attrs)
    }
    return image.withRenderingMode(.alwaysTemplate)
  }

  /// "1x", "1.25x", "1.5x", "0.75x" — trims trailing zeros so whole speeds stay
  /// compact.
  private static func formatSpeed(_ speed: Double) -> String {
    let rounded = (speed * 100).rounded() / 100
    if rounded == rounded.rounded() {
      return "\(Int(rounded))x"
    }
    var str = String(format: "%.2f", rounded)
    while str.hasSuffix("0") { str.removeLast() }
    if str.hasSuffix(".") { str.removeLast() }
    return "\(str)x"
  }
}
