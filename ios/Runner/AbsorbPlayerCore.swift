import AbsorbPlayerCore
import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// Native player core for iOS. Drives downloaded and streaming audiobooks
/// via AVPlayer when Flutter isn't alive, exposes lock-screen / Control
/// Center / CarPlay metadata, handles remote commands, and pushes progress
/// directly to ABS so the server stays in sync during widget-only sessions.
///
/// State source: app group `np_*` keys written by `home_widget_service.dart`.
/// Hand-off: `audio_owner_alive_at` heartbeat - if recent, Flutter is in
/// charge and native bails on every entry point.
final class AbsorbPlayerCore: NSObject, AbsorbPlayerCoreProtocol, @unchecked Sendable {
  static let shared = AbsorbPlayerCore()

  static var logSink: ((String) -> Void)?

  private static let appGroup = "group.com.barnabas.absorb"

  private let queue = DispatchQueue(label: "com.barnabas.absorb.nativecore")

  private var _player: AVPlayer?
  private var _currentItemId: String?
  private var _currentEpisodeId: String?

  // Multi-track state
  private var _trackUrls: [URL] = []
  private var _trackHeaders: [String: String] = [:]
  private var _trackOffsets: [Double] = [0]
  private var _trackIndex: Int = 0

  private var _periodicObserver: Any?
  private var _itemEndObserver: NSObjectProtocol?
  private var _commandsConfigured = false

  // Server sync timer (separate from periodic position observer)
  private var _serverSyncTimer: Timer?
  private static let serverSyncIntervalSec: TimeInterval = 60.0

  private override init() {
    super.init()
    emit("[NativeCore] init - host app process is alive")
  }

  // MARK: - Public API (AbsorbPlayerCoreProtocol)

  func play() {
    queue.async { [weak self] in
      guard let self = self else { return }
      if self.flutterIsAlive() {
        self.emit("[NativeCore] play(): Flutter is alive, bailing")
        return
      }
      self.ensureLoaded()
      guard let p = self._player else {
        self.emit("[NativeCore] play(): no player loaded")
        return
      }
      self.activateAudioSession()
      p.play()
      self.applySpeed(to: p)
      self.emit("[NativeCore] play(): rate=\(p.rate) trackIdx=\(self._trackIndex)")
      self.startServerSyncTimer()
      self.updateNowPlayingInfo(rate: Double(p.rate))
    }
  }

  func pause() {
    queue.async { [weak self] in
      guard let self = self else { return }
      if self.flutterIsAlive() {
        self.emit("[NativeCore] pause(): Flutter is alive, bailing")
        return
      }
      guard let p = self._player else {
        self.emit("[NativeCore] pause(): no player")
        return
      }
      p.pause()
      self.emit("[NativeCore] pause(): pos=\(self.globalPosition())s")
      self.savePosition()
      self.pushProgressToServer()
      self.stopServerSyncTimer()
      self.updateNowPlayingInfo(rate: 0)
    }
  }

  func toggle() {
    queue.async { [weak self] in
      guard let self = self else { return }
      if self.flutterIsAlive() {
        self.emit("[NativeCore] toggle(): Flutter is alive, bailing")
        return
      }
      self.ensureLoaded()
      guard let p = self._player else {
        self.emit("[NativeCore] toggle(): no player loaded")
        return
      }
      if p.rate > 0 {
        p.pause()
        self.emit("[NativeCore] toggle(): paused at \(self.globalPosition())s")
        self.savePosition()
        self.pushProgressToServer()
        self.stopServerSyncTimer()
        self.updateNowPlayingInfo(rate: 0)
      } else {
        self.activateAudioSession()
        p.play()
        self.applySpeed(to: p)
        self.emit("[NativeCore] toggle(): playing rate=\(p.rate) global=\(self.globalPosition())s")
        self.startServerSyncTimer()
        self.updateNowPlayingInfo(rate: Double(p.rate))
      }
    }
  }

  func skipForward(seconds: Int) {
    queue.async { [weak self] in
      guard let self = self else { return }
      if self.flutterIsAlive() {
        self.emit("[NativeCore] skipForward(\(seconds)): Flutter is alive, bailing")
        return
      }
      let now = self.globalPosition()
      let dur = self.totalDuration()
      let target = min(dur > 0 ? dur : .greatestFiniteMagnitude, now + Double(seconds))
      self.emit("[NativeCore] skipForward(\(seconds)s): \(now)s -> \(target)s")
      self.seekToGlobal(target)
    }
  }

  func skipBackward(seconds: Int) {
    queue.async { [weak self] in
      guard let self = self else { return }
      if self.flutterIsAlive() {
        self.emit("[NativeCore] skipBackward(\(seconds)): Flutter is alive, bailing")
        return
      }
      let now = self.globalPosition()
      let target = max(0, now - Double(seconds))
      self.emit("[NativeCore] skipBackward(\(seconds)s): \(now)s -> \(target)s")
      self.seekToGlobal(target)
    }
  }

  func log(_ message: String) {
    emit(message)
  }

  // MARK: - Hand-off

  private func flutterIsAlive() -> Bool {
    let defaults = UserDefaults(suiteName: Self.appGroup)
    guard let aliveAt = defaults?.object(forKey: "audio_owner_alive_at") as? Int else {
      return false
    }
    let nowMs = Int(Date().timeIntervalSince1970 * 1000)
    let ageMs = nowMs - aliveAt
    return ageMs >= 0 && ageMs < 30_000
  }

  // MARK: - State plumbing

  /// Build the URL list, track offsets, headers, and active-track index
  /// from app group state. Loads the AVPlayer to the right starting track.
  private func ensureLoaded() {
    let defaults = UserDefaults(suiteName: Self.appGroup)
    guard let itemId = defaults?.string(forKey: "np_item_id") else {
      emit("[NativeCore] ensureLoaded: no np_item_id in app group")
      return
    }
    let episodeId = defaults?.string(forKey: "np_episode_id")
    if _player != nil && itemId == _currentItemId && episodeId == _currentEpisodeId {
      return
    }

    let isDownloaded = defaults?.bool(forKey: "np_is_downloaded") ?? false
    let urls: [URL]
    let headers: [String: String]
    if isDownloaded,
       let pathsJson = defaults?.string(forKey: "np_audio_paths_json"),
       let pathsData = pathsJson.data(using: .utf8),
       let paths = try? JSONSerialization.jsonObject(with: pathsData) as? [String],
       !paths.isEmpty {
      urls = paths
        .filter { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
      headers = [:]
      emit("[NativeCore] ensureLoaded: \(itemId) downloaded, \(urls.count) tracks")
    } else if let urlsJson = defaults?.string(forKey: "np_stream_urls_json"),
              let urlsData = urlsJson.data(using: .utf8),
              let urlStrings = try? JSONSerialization.jsonObject(with: urlsData) as? [String],
              !urlStrings.isEmpty {
      urls = urlStrings.compactMap { URL(string: $0) }
      var hh: [String: String] = [:]
      if let headersJson = defaults?.string(forKey: "np_stream_headers_json"),
         let headersData = headersJson.data(using: .utf8),
         let h = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
        hh = h
      }
      headers = hh
      emit("[NativeCore] ensureLoaded: \(itemId) streaming, \(urls.count) tracks, \(headers.count) custom headers")
    } else {
      emit("[NativeCore] ensureLoaded: no playable source for \(itemId)")
      return
    }

    if urls.isEmpty {
      emit("[NativeCore] ensureLoaded: source list empty after filtering for \(itemId)")
      return
    }

    // Track offsets (cumulative, length = urls.count + 1). Fall back to
    // [0, +inf] if the stash is missing or shorter than expected so we
    // still play track 0.
    var offsets: [Double] = [0]
    if let offsetsJson = defaults?.string(forKey: "np_track_offsets_json"),
       let offsetsData = offsetsJson.data(using: .utf8),
       let raw = try? JSONSerialization.jsonObject(with: offsetsData) as? [NSNumber],
       raw.count >= urls.count + 1 {
      offsets = raw.map { $0.doubleValue }
    } else {
      // Fallback: assume single track, or unknown durations -> can't seek
      // across tracks correctly but at least track 0 plays.
      offsets = [0]
      for _ in urls { offsets.append(.greatestFiniteMagnitude) }
      emit("[NativeCore] ensureLoaded: track offsets unknown, falling back to single-track logic")
    }

    let savedPos = defaults?.double(forKey: "np_position_s") ?? 0
    let startTrackIndex = trackIndexForGlobal(savedPos, offsets: offsets)
    let localStart = savedPos - offsets[startTrackIndex]

    _trackUrls = urls
    _trackHeaders = headers
    _trackOffsets = offsets
    _trackIndex = startTrackIndex
    _currentItemId = itemId
    _currentEpisodeId = episodeId

    let player = AVPlayer()
    _player = player
    loadCurrentTrack(seekTo: localStart)
    configureRemoteCommandsIfNeeded()
    updateNowPlayingInfo(rate: 0)

    emit("[NativeCore] ensureLoaded done: \(itemId) trackIdx=\(startTrackIndex)/\(urls.count) localStart=\(localStart)s globalStart=\(savedPos)s")
  }

  /// Build an AVPlayerItem for the current track (with auth headers if
  /// streaming) and assign it to the player. Sets up end-of-track observer
  /// so playback rolls onto the next track automatically.
  private func loadCurrentTrack(seekTo localSeconds: Double) {
    guard let p = _player, _trackIndex < _trackUrls.count else { return }
    let url = _trackUrls[_trackIndex]
    var options: [String: Any] = [:]
    if !_trackHeaders.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = _trackHeaders
    }
    let asset = AVURLAsset(url: url, options: options)
    let item = AVPlayerItem(asset: asset)
    p.replaceCurrentItem(with: item)
    if localSeconds > 0 {
      p.seek(to: CMTime(seconds: localSeconds, preferredTimescale: 1000))
    }
    observeItemEnd(item)
    addPeriodicObserver(player: p)
    emit("[NativeCore] loadCurrentTrack: idx=\(_trackIndex) url=\(url) localSeek=\(localSeconds)s")
  }

  private func trackIndexForGlobal(_ globalSeconds: Double, offsets: [Double]) -> Int {
    if globalSeconds <= 0 { return 0 }
    // offsets is [0, dur0, dur0+dur1, ..., total]. Find largest index i
    // where offsets[i] <= globalSeconds. Number of tracks = offsets.count - 1
    // so result must be in [0, offsets.count - 2].
    let trackCount = max(1, offsets.count - 1)
    for i in 0..<trackCount {
      let nextOffset = i + 1 < offsets.count ? offsets[i + 1] : .greatestFiniteMagnitude
      if globalSeconds < nextOffset {
        return i
      }
    }
    return trackCount - 1
  }

  /// Compute global position = trackOffset + position-within-current-track.
  /// Returns 0 if state hasn't loaded.
  private func globalPosition() -> Double {
    guard let p = _player else { return 0 }
    let local = p.currentTime().seconds
    guard local.isFinite else { return _trackOffsets.indices.contains(_trackIndex) ? _trackOffsets[_trackIndex] : 0 }
    let baseOffset = _trackOffsets.indices.contains(_trackIndex) ? _trackOffsets[_trackIndex] : 0
    return baseOffset + local
  }

  private func totalDuration() -> Double {
    let defaults = UserDefaults(suiteName: Self.appGroup)
    let stashed = defaults?.double(forKey: "np_total_s") ?? 0
    if stashed > 0 { return stashed }
    return _trackOffsets.last ?? 0
  }

  private func seekToGlobal(_ globalSeconds: Double) {
    guard !_trackOffsets.isEmpty else { return }
    let targetIndex = trackIndexForGlobal(globalSeconds, offsets: _trackOffsets)
    let localTarget = max(0, globalSeconds - _trackOffsets[targetIndex])

    if targetIndex == _trackIndex {
      // Same track, simple seek.
      _player?.seek(
        to: CMTime(seconds: localTarget, preferredTimescale: 1000),
        toleranceBefore: .zero, toleranceAfter: .zero
      ) { [weak self] _ in
        self?.queue.async {
          self?.savePosition()
          self?.updateNowPlayingInfo(rate: Double(self?._player?.rate ?? 0))
          self?.emit("[NativeCore] seekToGlobal in-track: \(globalSeconds)s")
        }
      }
    } else {
      // Cross-track seek: load the new track, then seek inside it.
      let wasPlaying = (_player?.rate ?? 0) > 0
      _trackIndex = targetIndex
      loadCurrentTrack(seekTo: localTarget)
      if wasPlaying {
        _player?.play()
        applySpeed(to: _player!)
      }
      savePosition()
      updateNowPlayingInfo(rate: Double(_player?.rate ?? 0))
      emit("[NativeCore] seekToGlobal cross-track: \(globalSeconds)s -> idx=\(targetIndex) local=\(localTarget)s")
    }
  }

  private func applySpeed(to player: AVPlayer) {
    let defaults = UserDefaults(suiteName: Self.appGroup)
    let speed = defaults?.double(forKey: "np_speed") ?? 1.0
    player.rate = Float(speed > 0 ? speed : 1.0)
  }

  private func observeItemEnd(_ item: AVPlayerItem) {
    if let prev = _itemEndObserver {
      NotificationCenter.default.removeObserver(prev)
    }
    _itemEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: nil
    ) { [weak self] _ in
      self?.queue.async {
        self?.handleTrackEnd()
      }
    }
  }

  private func handleTrackEnd() {
    let nextIndex = _trackIndex + 1
    if nextIndex < _trackUrls.count {
      emit("[NativeCore] track \(_trackIndex) ended, advancing to \(nextIndex)")
      _trackIndex = nextIndex
      loadCurrentTrack(seekTo: 0)
      let wasPlaying = (_player?.rate ?? 0) > 0
      if wasPlaying {
        _player?.play()
        if let p = _player { applySpeed(to: p) }
      }
      savePosition()
      updateNowPlayingInfo(rate: Double(_player?.rate ?? 0))
    } else {
      emit("[NativeCore] last track ended, stopping")
      savePosition()
      pushProgressToServer()
      stopServerSyncTimer()
      updateNowPlayingInfo(rate: 0)
    }
  }

  private func addPeriodicObserver(player: AVPlayer) {
    if let prev = _periodicObserver {
      player.removeTimeObserver(prev)
    }
    _periodicObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 5, preferredTimescale: 1),
      queue: .main
    ) { [weak self] _ in
      self?.queue.async { self?.savePosition() }
    }
  }

  private func activateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio, options: [])
      try session.setActive(true)
    } catch {
      emit("[NativeCore] AVAudioSession activate failed: \(error.localizedDescription)")
    }
  }

  private func savePosition() {
    let pos = globalPosition()
    if !pos.isFinite { return }
    let defaults = UserDefaults(suiteName: Self.appGroup)
    defaults?.set(pos, forKey: "np_position_s")
    defaults?.set((_player?.rate ?? 0) > 0, forKey: "widget_is_playing")
  }

  // MARK: - Server sync

  private func startServerSyncTimer() {
    DispatchQueue.main.async { [weak self] in
      self?._serverSyncTimer?.invalidate()
      self?._serverSyncTimer = Timer.scheduledTimer(
        withTimeInterval: Self.serverSyncIntervalSec,
        repeats: true
      ) { _ in
        self?.queue.async { self?.pushProgressToServer() }
      }
      self?.emit("[NativeCore] server sync timer started (\(Int(Self.serverSyncIntervalSec))s)")
    }
  }

  private func stopServerSyncTimer() {
    DispatchQueue.main.async { [weak self] in
      self?._serverSyncTimer?.invalidate()
      self?._serverSyncTimer = nil
    }
  }

  /// PATCH /api/me/progress/{itemId} so other clients (and the user's own
  /// app on relaunch) see the right position. Best-effort - no retry on
  /// failure since we'll try again on the next 60s tick.
  private func pushProgressToServer() {
    let defaults = UserDefaults(suiteName: Self.appGroup)
    guard let itemId = _currentItemId,
          let serverUrl = defaults?.string(forKey: "np_server_url"),
          let token = defaults?.string(forKey: "np_api_token"),
          !token.isEmpty
    else {
      emit("[NativeCore] pushProgressToServer: missing itemId/server/token")
      return
    }
    let pos = globalPosition()
    let cleanBase = serverUrl.hasSuffix("/")
      ? String(serverUrl.dropLast())
      : serverUrl
    let progressKey: String
    if let ep = _currentEpisodeId, !ep.isEmpty {
      progressKey = "\(itemId)-\(ep)"
    } else {
      progressKey = itemId
    }
    guard let url = URL(string: "\(cleanBase)/api/me/progress/\(progressKey)") else {
      emit("[NativeCore] pushProgressToServer: bad URL for \(progressKey)")
      return
    }

    var req = URLRequest(url: url)
    req.httpMethod = "PATCH"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let headersJson = defaults?.string(forKey: "np_stream_headers_json"),
       let headersData = headersJson.data(using: .utf8),
       let headers = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
      for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    }
    let body: [String: Any] = ["currentTime": pos]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      if let error = error {
        self?.emit("[NativeCore] server sync error: \(error.localizedDescription)")
      } else {
        self?.emit("[NativeCore] server sync \(progressKey) currentTime=\(pos) status=\(status)")
      }
    }.resume()
  }

  // MARK: - MPNowPlayingInfoCenter

  private func updateNowPlayingInfo(rate: Double) {
    guard _player != nil else { return }
    let defaults = UserDefaults(suiteName: Self.appGroup)
    let title = defaults?.string(forKey: "np_title")
      ?? defaults?.string(forKey: "widget_title")
      ?? ""
    let author = defaults?.string(forKey: "np_author")
      ?? defaults?.string(forKey: "widget_author")
      ?? ""
    let coverPath = defaults?.string(forKey: "np_cover_path")
      ?? defaults?.string(forKey: "widget_cover_path")
    let duration = totalDuration()
    let elapsed = globalPosition()

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: author,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
      MPNowPlayingInfoPropertyPlaybackRate: rate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    if duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = duration
    }
    if let coverPath = coverPath, let img = UIImage(contentsOfFile: coverPath) {
      let artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
      info[MPMediaItemPropertyArtwork] = artwork
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  // MARK: - MPRemoteCommandCenter

  /// Register the remote command handlers up front, without loading a player or
  /// starting playback. They defer to Flutter while it's alive, so this is a
  /// no-op for normal foreground use - but it guarantees a native target stays
  /// registered for the play command. Without it, the handlers were only wired
  /// the first time the native core played, so a play after iOS suspended a
  /// paused Flutter found no responsive Now Playing app and iOS handed control
  /// to Apple Music. Idempotent.
  func armRemoteCommands() {
    queue.async { [weak self] in
      self?.configureRemoteCommandsIfNeeded()
    }
  }

  private func configureRemoteCommandsIfNeeded() {
    if _commandsConfigured { return }
    _commandsConfigured = true
    let cc = MPRemoteCommandCenter.shared()

    // Each handler bails when Flutter is alive so audio_service handlers
    // win on the lock screen. When native is in charge, these drive the
    // AVPlayer directly.
    cc.playCommand.addTarget { [weak self] _ in
      if self?.flutterIsAlive() == true {
        self?.emit("[NativeCore] remote: play - Flutter is alive, deferring")
        return .success
      }
      self?.emit("[NativeCore] remote: play")
      self?.play()
      return .success
    }
    cc.pauseCommand.addTarget { [weak self] _ in
      if self?.flutterIsAlive() == true {
        self?.emit("[NativeCore] remote: pause - Flutter is alive, deferring")
        return .success
      }
      self?.emit("[NativeCore] remote: pause")
      self?.pause()
      return .success
    }
    cc.togglePlayPauseCommand.addTarget { [weak self] _ in
      if self?.flutterIsAlive() == true {
        self?.emit("[NativeCore] remote: toggle - Flutter is alive, deferring")
        return .success
      }
      self?.emit("[NativeCore] remote: toggle")
      self?.toggle()
      return .success
    }

    cc.skipForwardCommand.preferredIntervals = [30]
    cc.skipForwardCommand.addTarget { [weak self] event in
      let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
      if self?.flutterIsAlive() == true {
        self?.emit("[NativeCore] remote: skipForward - Flutter is alive, deferring")
        return .success
      }
      self?.skipForward(seconds: Int(interval))
      return .success
    }
    cc.skipBackwardCommand.preferredIntervals = [10]
    cc.skipBackwardCommand.addTarget { [weak self] event in
      let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
      if self?.flutterIsAlive() == true {
        self?.emit("[NativeCore] remote: skipBackward - Flutter is alive, deferring")
        return .success
      }
      self?.skipBackward(seconds: Int(interval))
      return .success
    }

    cc.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      if self?.flutterIsAlive() == true {
        self?.emit("[NativeCore] remote: scrub - Flutter is alive, deferring")
        return .success
      }
      self?.queue.async { self?.seekToGlobal(event.positionTime) }
      return .success
    }
    emit("[NativeCore] remote command center wired")
  }

  // MARK: - Logging

  private func emit(_ line: String) {
    NSLog("%@", line)
    Self.logSink?(line)
  }
}
