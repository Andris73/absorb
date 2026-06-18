import AbsorbPlayerCore
import AppIntents
import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import MediaPlayer
import just_audio

let flutterEngine = FlutterEngine(name: "SharedEngine", project: nil, allowHeadlessExecution: true)

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var widgetChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Start the shared Flutter engine (used by both phone scene and CarPlay scene)
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)

    // Register for remote control events so lock screen / Control Center
    // media controls appear. The audio_service plugin activates
    // MPRemoteCommandCenter but doesn't call this, which can prevent
    // Now Playing from appearing on scene-based lifecycle apps.
    application.beginReceivingRemoteControlEvents()

    // Pre-configure the audio session category for playback so iOS knows this
    // app plays long-form audio (lock screen / Control Center controls) before
    // the Flutter engine finishes initializing. Do NOT activate the session
    // here: setActive(true) at launch interrupts other apps' audio (e.g.
    // Spotify) the moment Absorb opens, before the user presses play. The
    // playback paths (AbsorbAudioEngine / AbsorbPlayerCore / IOSQueueAdvancer)
    // activate the session themselves when audio actually starts.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio)
    } catch {
      print("[AppDelegate] Audio session setup failed: \(error)")
    }

    // Listen for Darwin notifications from the widget extension so controls
    // work without opening the app.
    registerWidgetNotifications()

    // Register platform channels on the shared engine. Must come before the
    // logSink wiring below so widgetChannel exists when we hand it off.
    registerPlatformChannels()

    // Route native player core log output into the Flutter widget channel's
    // "log" method, which surfaces lines as `[WidgetDebug] [NativeCore] ...`
    // in absorb's in-app log viewer. No Mac/Xcode needed to verify behavior.
    AbsorbPlayerCore.logSink = { [weak self] line in
      DispatchQueue.main.async {
        self?.widgetChannel?.invokeMethod("log", arguments: ["msg": line])
      }
    }

    // Same routing for the EQ tap's format diagnostics, so when a user
    // reports "EQ on, this book has no sound" we can see the post-decode
    // PCM format the tap actually received (low-bitrate AAC m4b often
    // shows up here as mono / unusual sample rate).
    AudioEQProcessor.setFormatLogger { [weak self] line in
      DispatchQueue.main.async {
        self?.widgetChannel?.invokeMethod("log", arguments: ["msg": line])
      }
    }
    AbsorbAudioEQProcessor.setFormatLogger { [weak self] line in
      DispatchQueue.main.async {
        self?.widgetChannel?.invokeMethod("log", arguments: ["msg": line])
      }
    }

    IOSQueueAdvancer.logSink = { [weak self] line in
      DispatchQueue.main.async {
        self?.widgetChannel?.invokeMethod("log", arguments: ["msg": line])
      }
    }

    AbsorbAudioEngine.logSink = { [weak self] line in
      DispatchQueue.main.async {
        self?.widgetChannel?.invokeMethod("log", arguments: ["msg": line])
      }
    }
    AbsorbAudioBridge.logSink = { [weak self] line in
      DispatchQueue.main.async {
        self?.widgetChannel?.invokeMethod("log", arguments: ["msg": line])
      }
    }

    // Register the native player core as an AppIntent dependency. The widget
    // intent declares `@Dependency var core: AbsorbPlayerCoreProtocol` - that
    // signals to iOS to launch this host app process to run the intent's
    // perform(), and the dependency manager hands back this concrete instance
    // so the intent can drive audio in-process. Without this, the widget
    // intent runs in the widget extension's sandbox and can't reach our audio
    // engine.
    //
    // AppIntents (and AppDependencyManager) are iOS 16+. Runner ships back
    // to iOS 15 so we have to guard the call. iOS 15 users won't have the
    // widget anyway (widget extension's deployment target is iOS 17).
    if #available(iOS 16.0, *) {
      let core: AbsorbPlayerCoreProtocol = AbsorbPlayerCore.shared
      AppDependencyManager.shared.add(dependency: core)
      AbsorbPlayerCore.logSink?("[NativeCore] Registered as AppIntent dependency")
    }

    // When the app backgrounds, wire the native core's lock-screen / headphone
    // command handlers. They defer to Flutter while it's alive, but staying
    // registered means a play command after iOS suspends a paused Flutter still
    // has a native target - so Absorb resumes instead of iOS handing the play to
    // Apple Music. We arm on background (not launch) because Flutter is
    // guaranteed alive here, and an app must background before iOS suspends it.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil, queue: .main
    ) { _ in AbsorbPlayerCore.shared.armRemoteCommands() }

    registerAudioSessionObservers()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func registerAudioSessionObservers() {
    let nc = NotificationCenter.default
    nc.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
      let reasonName: String
      switch reason {
      case .unknown: reasonName = "unknown"
      case .newDeviceAvailable: reasonName = "newDeviceAvailable"
      case .oldDeviceUnavailable: reasonName = "oldDeviceUnavailable"
      case .categoryChange: reasonName = "categoryChange"
      case .override: reasonName = "override"
      case .wakeFromSleep: reasonName = "wakeFromSleep"
      case .noSuitableRouteForCategory: reasonName = "noSuitableRouteForCategory"
      case .routeConfigurationChange: reasonName = "routeConfigurationChange"
      default: reasonName = "raw=\(reasonRaw)"
      }
      let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        .map { "\($0.portType.rawValue):\($0.portName)" }
        .joined(separator: ",")
      self?.logToFlutter("[AudioSession] routeChange reason=\(reasonName) outputs=[\(outputs)]")
    }

    nc.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 99
      let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
      let typeName: String
      switch type {
      case .began: typeName = "began"
      case .ended: typeName = "ended"
      default: typeName = "raw=\(typeRaw)"
      }
      var details: [String] = ["type=\(typeName)"]
      if let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
        let opts = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
        details.append("shouldResume=\(opts.contains(.shouldResume))")
      }
      if #available(iOS 14.5, *) {
        if let reasonRaw = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt {
          details.append("reasonRaw=\(reasonRaw)")
        }
      }
      self?.logToFlutter("[AudioSession] interruption \(details.joined(separator: " "))")
    }

    nc.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.logToFlutter("[AudioSession] mediaServicesWereReset")
    }

    nc.addObserver(
      forName: AVAudioSession.silenceSecondaryAudioHintNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      let typeRaw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt ?? 99
      self?.logToFlutter("[AudioSession] silenceSecondaryAudioHint type=\(typeRaw)")
    }

    // The patched just_audio fork posts JustAudioDiag notifications with
    // AVPlayer state snapshots (timeControlStatus, rate, reasonForWaitingToPlay,
    // error) right after each play() call. Forward them to the in-app log.
    nc.addObserver(
      forName: Notification.Name("JustAudioDiag"),
      object: nil,
      queue: .main
    ) { [weak self] note in
      if let msg = note.userInfo?["message"] as? String {
        self?.logToFlutter(msg)
      }
    }
  }

  /// Forwards a log line to the Dart LogService via the widget channel so it
  /// appears in the in-app log viewer (NSLog alone only shows in Xcode /
  /// Console.app on a Mac).
  private func logToFlutter(_ message: String) {
    NSLog("[WidgetDebug] %@", message)
    DispatchQueue.main.async { [weak self] in
      self?.widgetChannel?.invokeMethod("log", arguments: ["msg": message])
    }
  }

  private func registerWidgetNotifications() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()

    let names = [
      "com.barnabas.absorb.widget.playPause",
      "com.barnabas.absorb.widget.skipBack",
      "com.barnabas.absorb.widget.skipForward",
    ]
    for name in names {
      CFNotificationCenterAddObserver(
        center, observer,
        { (_, observer, name, _, _) in
          guard let observer = observer,
                let rawName = name?.rawValue as String? else { return }
          NSLog("[WidgetDebug] AppDelegate received Darwin notification: %@", rawName)
          let appDelegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
          let action: String
          switch rawName {
          case "com.barnabas.absorb.widget.playPause":   action = "playPause"
          case "com.barnabas.absorb.widget.skipBack":    action = "skipBack"
          case "com.barnabas.absorb.widget.skipForward": action = "skipForward"
          default: return
          }
          // Re-activate the audio session as soon as the host app process
          // sees the notification, before the async hop to Flutter. The
          // widget extension already activates it in perform(), but doing it
          // again here from the host app's process is the belt-and-suspenders
          // guarantee that AVAudioSession is hot when player.play() runs.
          do {
            try AVAudioSession.sharedInstance().setActive(true)
          } catch {
            NSLog("[WidgetDebug] AppDelegate setActive failed: %@", error.localizedDescription)
          }
          DispatchQueue.main.async {
            NSLog("[WidgetDebug] AppDelegate dispatching widget action to Flutter: %@", action)
            appDelegate.widgetChannel?.invokeMethod("widgetAction", arguments: ["action": action])
          }
        },
        name as CFString,
        nil,
        .deliverImmediately
      )
    }
    NSLog("[WidgetDebug] AppDelegate registered %d Darwin notification observers", names.count)
  }

  private func registerPlatformChannels() {
    let messenger = flutterEngine.binaryMessenger

    IOSQueueAdvancer.shared.register(with: messenger)
    AbsorbAudioBridge.shared.register(with: messenger)

    // CarPlay Now Playing custom buttons (chapter nav, speed, bookmark). These
    // decorate CPNowPlayingTemplate only — the lock screen is untouched.
    CarPlayNowPlaying.shared.register(with: messenger)

    // iOS audio output device switching is not implemented yet — iOS routes
    // through the system's MPVolumeView/AVRoutePicker rather than letting apps
    // pick output devices directly. Stub these so the channel responds.
    let channel = FlutterMethodChannel(name: "com.absorb.audio_output",
                                       binaryMessenger: messenger)
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "getAudioOutputDevices":
        result([])
      case "setAudioOutputDevice", "resetAudioOutput":
        result(false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let storageChannel = FlutterMethodChannel(name: "com.absorb.storage",
                                              binaryMessenger: messenger)
    storageChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "getDeviceStorage":
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let total = (attrs[.systemSize] as? NSNumber)?.int64Value,
           let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value {
          result(["totalBytes": total, "availableBytes": free])
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Bookmark clip export: extract a time window of a book and write a .m4a.
    let clipChannel = FlutterMethodChannel(name: "com.absorb.clip",
                                           binaryMessenger: messenger)
    clipChannel.setMethodCallHandler { (call, result) in
      guard call.method == "exportClip" else { result(FlutterMethodNotImplemented); return }
      let args = call.arguments as? [String: Any]
      guard let source = args?["source"] as? String,
            let outPath = args?["outPath"] as? String else {
        result(FlutterError(code: "CLIP_ARGS", message: "Missing source or outPath", details: nil))
        return
      }
      let isLocal = args?["isLocal"] as? Bool ?? true
      let headers = args?["headers"] as? [String: String]
      let start = args?["startSeconds"] as? Double ?? 0
      let duration = args?["durationSeconds"] as? Double ?? 60
      AudioClipExporter.exportM4a(
        source: source, isLocal: isLocal, headers: headers,
        startSeconds: start, durationSeconds: duration, outPath: outPath
      ) { ok, errMessage in
        DispatchQueue.main.async {
          if ok {
            result(true)
          } else {
            result(FlutterError(code: "CLIP_FAILED", message: errMessage ?? "export failed", details: nil))
          }
        }
      }
    }

    let widgetChannel = FlutterMethodChannel(name: "com.absorb.widget",
                                               binaryMessenger: messenger)
    self.widgetChannel = widgetChannel
    widgetChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "getGroupContainerPath":
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.barnabas.absorb") {
          NSLog("[WidgetDebug] getGroupContainerPath resolved: %@", url.path)
          result(url.path)
        } else {
          NSLog("[WidgetDebug] getGroupContainerPath: containerURL returned nil - app group entitlement missing or misconfigured")
          result(nil)
        }
      case "excludeFromBackup":
        // Stops iCloud from backing up downloaded audio files. Audiobooks
        // are large and re-downloadable, no point eating user's iCloud
        // quota. Called by DownloadService for each file post-download or
        // post-migration.
        let args = call.arguments as? [String: Any]
        guard let path = args?["path"] as? String else { result(false); return }
        var url = URL(fileURLWithPath: path)
        do {
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try url.setResourceValues(values)
          result(true)
        } catch {
          NSLog("[WidgetDebug] excludeFromBackup failed for %@: %@", path, error.localizedDescription)
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eqChannel = FlutterMethodChannel(name: "com.absorb.equalizer",
                                          binaryMessenger: messenger)
    eqChannel.setMethodCallHandler { [weak self] (call, result) in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "isBluetoothAudioConnected":
        result(self?.isBluetoothAudioConnected() ?? false)

      case "getAudioDiagnostics":
        // Snapshot of AVAudioSession state for the "tap play, no sound"
        // diagnosis. Returns category, mode, options, output volume,
        // current route ports, and the session-active hint that iOS
        // exposes. Dart side logs all of it via [AudioDiag] markers.
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs.map { port -> [String: String] in
          [
            "name": port.portName,
            "type": port.portType.rawValue,
            "uid": port.uid,
          ]
        }
        let inputs = route.inputs.map { port -> [String: String] in
          [
            "name": port.portName,
            "type": port.portType.rawValue,
          ]
        }
        let npInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let npTitle = npInfo?[MPMediaItemPropertyTitle] as? String
        let npRate = npInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double
        let npElapsed = npInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
        let info: [String: Any] = [
          "category": session.category.rawValue,
          "mode": session.mode.rawValue,
          "categoryOptions": session.categoryOptions.rawValue,
          "routeSharingPolicy": session.routeSharingPolicy.rawValue,
          "outputVolume": session.outputVolume,
          "isOtherAudioPlaying": session.isOtherAudioPlaying,
          "secondaryAudioShouldBeSilencedHint": session.secondaryAudioShouldBeSilencedHint,
          "outputs": outputs,
          "inputs": inputs,
          "sampleRate": session.sampleRate,
          "ioBufferDuration": session.ioBufferDuration,
          "nowPlayingHasInfo": npInfo != nil,
          "nowPlayingTitle": npTitle ?? "",
          "nowPlayingRate": npRate ?? -1,
          "nowPlayingElapsed": npElapsed ?? -1,
        ]
        result(info)

      case "primeNowPlaying":
        let title = args?["title"] as? String ?? ""
        let artist = args?["artist"] as? String ?? ""
        let duration = args?["duration"] as? Double ?? 0
        let elapsed = args?["elapsed"] as? Double ?? 0
        var info: [String: Any] = [
          MPMediaItemPropertyTitle: title,
          MPMediaItemPropertyArtist: artist,
          MPNowPlayingInfoPropertyPlaybackRate: 1.0,
          MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
        ]
        if duration > 0 {
          info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        result(true)

      case "init":
        result([
          "bands": 5,
          "frequencies": [60, 230, 910, 3600, 14000],
          "minLevel": -15.0,
          "maxLevel": 15.0,
        ] as [String: Any])

      case "attachSession":
        // No-op on iOS - the processing tap is attached per player item in
        // UriAudioSource.m, not via a session ID like Android's EQ APIs.
        result(true)

      case "setEnabled":
        let enabled = args?["enabled"] as? Bool ?? false
        AudioEQProcessor.shared.setEnabled(enabled)
        AbsorbAudioEQProcessor.shared.setEnabled(enabled)
        result(true)

      case "setBand":
        let band = args?["band"] as? Int ?? 0
        let level = args?["level"] as? Int ?? 0
        AudioEQProcessor.shared.setBandLevel(Int32(level), forBand: Int32(band))
        AbsorbAudioEQProcessor.shared.setBandLevel(Int32(level), forBand: Int32(band))
        result(true)

      case "setBassBoost":
        let strength = args?["strength"] as? Int ?? 0
        AudioEQProcessor.shared.setBassBoostStrength(Int32(strength))
        AbsorbAudioEQProcessor.shared.setBassBoostStrength(Int32(strength))
        result(true)

      case "setVirtualizer":
        // No iOS equivalent of Android's Virtualizer effect.
        result(true)

      case "setLoudness":
        let gain = args?["gain"] as? Int ?? 0
        AudioEQProcessor.shared.setLoudnessGain(Int32(gain))
        AbsorbAudioEQProcessor.shared.setLoudnessGain(Int32(gain))
        result(true)

      case "setMono":
        let enabled = args?["enabled"] as? Bool ?? false
        AudioEQProcessor.shared.setMonoEnabled(enabled)
        AbsorbAudioEQProcessor.shared.setMonoEnabled(enabled)
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func isBluetoothAudioConnected() -> Bool {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    return outputs.contains { port in
      port.portType == .bluetoothA2DP ||
      port.portType == .bluetoothHFP ||
      port.portType == .bluetoothLE
    }
  }

}

/// Extracts a time window of an audiobook and writes it as an AAC .m4a clip
/// (bookmark clip export). Uses an AVAssetReader -> AVAssetWriter transcode with
/// a time range, which - unlike AVAssetExportSession - works on a remote
/// (streaming) AVURLAsset: AVFoundation byte-range-requests only the bytes
/// around the window rather than downloading the whole file, mirroring Android's
/// MediaExtractor. Local downloaded files work the same way. The streamed URL
/// carries the access token in the URL and passes any custom headers best-effort.
enum AudioClipExporter {
  static func exportM4a(
    source: String,
    isLocal: Bool,
    headers: [String: String]?,
    startSeconds: Double,
    durationSeconds: Double,
    outPath: String,
    completion: @escaping (Bool, String?) -> Void
  ) {
    let asset: AVURLAsset
    if isLocal {
      asset = AVURLAsset(url: URL(fileURLWithPath: source))
    } else {
      guard let url = URL(string: source) else {
        completion(false, "bad url")
        return
      }
      var options: [String: Any] = [:]
      if let headers = headers, !headers.isEmpty {
        options["AVURLAssetHTTPHeaderFieldsKey"] = headers
      }
      asset = AVURLAsset(url: url, options: options)
    }

    // Load tracks/duration first so a remote asset is ready before we read it.
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
      var keyError: NSError?
      guard asset.statusOfValue(forKey: "tracks", error: &keyError) == .loaded else {
        completion(false, keyError?.localizedDescription ?? "asset tracks not loaded")
        return
      }
      guard let track = asset.tracks(withMediaType: .audio).first else {
        completion(false, "no audio track")
        return
      }
      runTranscode(
        asset: asset, track: track,
        startSeconds: startSeconds, durationSeconds: durationSeconds,
        outPath: outPath, completion: completion)
    }
  }

  private static func runTranscode(
    asset: AVAsset,
    track: AVAssetTrack,
    startSeconds: Double,
    durationSeconds: Double,
    outPath: String,
    completion: @escaping (Bool, String?) -> Void
  ) {
    let outURL = URL(fileURLWithPath: outPath)
    try? FileManager.default.createDirectory(
      at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: outURL)

    func fail(_ message: String) {
      try? FileManager.default.removeItem(at: outURL)
      completion(false, message)
    }

    // Source sample rate / channel count, capped to stereo.
    var srcRate = 44100.0
    var srcChannels = 2
    if let fmt = track.formatDescriptions.first {
      let desc = fmt as! CMFormatDescription
      if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
        if asbd.mSampleRate > 0 { srcRate = asbd.mSampleRate }
        if asbd.mChannelsPerFrame > 0 { srcChannels = Int(asbd.mChannelsPerFrame) }
      }
    }
    let channels = min(max(srcChannels, 1), 2)

    let timescale: CMTimeScale = 44100
    let start = CMTime(seconds: max(0, startSeconds), preferredTimescale: timescale)
    let dur = CMTime(seconds: max(0.5, durationSeconds), preferredTimescale: timescale)

    let reader: AVAssetReader
    let writer: AVAssetWriter
    do {
      reader = try AVAssetReader(asset: asset)
      writer = try AVAssetWriter(outputURL: outURL, fileType: .m4a)
    } catch {
      fail(error.localizedDescription)
      return
    }
    reader.timeRange = CMTimeRange(start: start, duration: dur)

    let pcmSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: srcRate,
      AVNumberOfChannelsKey: channels,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
    readerOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(readerOutput) else { fail("cannot add reader output"); return }
    reader.add(readerOutput)

    let aacSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: srcRate,
      AVNumberOfChannelsKey: channels,
      AVEncoderBitRateKey: 128_000,
    ]
    let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
    writerInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(writerInput) else { fail("cannot add writer input"); return }
    writer.add(writerInput)

    guard reader.startReading() else {
      fail(reader.error?.localizedDescription ?? "reader failed to start")
      return
    }
    guard writer.startWriting() else {
      fail(writer.error?.localizedDescription ?? "writer failed to start")
      return
    }
    writer.startSession(atSourceTime: start)

    var done = false
    let queue = DispatchQueue(label: "com.absorb.clip.export")
    writerInput.requestMediaDataWhenReady(on: queue) {
      while writerInput.isReadyForMoreMediaData {
        guard let buffer = readerOutput.copyNextSampleBuffer() else {
          // No more samples - finish (or surface a read failure).
          writerInput.markAsFinished()
          if reader.status == .failed {
            if !done { done = true; fail(reader.error?.localizedDescription ?? "reader failed") }
            return
          }
          writer.finishWriting {
            if done { return }
            done = true
            if writer.status == .completed {
              completion(true, nil)
            } else {
              try? FileManager.default.removeItem(at: outURL)
              completion(false, writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
            }
          }
          return
        }
        if !writerInput.append(buffer) {
          reader.cancelReading()
          writerInput.markAsFinished()
          if !done { done = true; fail(writer.error?.localizedDescription ?? "append failed") }
          return
        }
      }
    }
  }
}
