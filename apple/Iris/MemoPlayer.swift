import AVFoundation
import Observation
import os

/// One AVPlayer behind the detail screen: the recording or the spoken reply. It publishes what the player bar draws
/// (`position`, `duration`, `isPlaying`) and takes what it sends (toggle, seek, skip back). The position follows a
/// periodic time observer that lives from ``load(_:)`` until ``teardown()`` (the view calls it when it goes away).
@Observable
final class MemoPlayer {
  /// What the skip-back icon rewinds.
  static let skipBackSeconds: Double = 10
  /// How often the observer reports while playing; it also fires on play, pause and every time jump.
  private static let observerInterval = CMTime(seconds: 0.25, preferredTimescale: 600)

  private(set) var position: Double = 0
  private(set) var duration: Double
  private(set) var isPlaying = false
  private(set) var isLoaded = false
  private(set) var isLoading = false

  private var player: AVPlayer?
  private var timeObserver: Any?
  /// Bumped by every load and teardown; a download that finds it changed belongs to a request that is gone.
  private var generation = 0
  private let downloader: MediaDownloader
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "player")

  /// `duration` is the length the memo says; the item replaces it once AVFoundation knows the real one.
  init(duration: Double = 0, downloader: MediaDownloader = .shared) {
    self.duration = duration
    self.downloader = downloader
  }

  isolated deinit {
    teardown()
  }

  /// Fetches `request` (a file URL is used as is, anything else is downloaded with its headers) and points the player
  /// at the file. Nil clears the player. A newer load or a teardown while this one downloads wins.
  func load(_ request: MediaRequest?) async {
    teardown()
    guard let request else { return }
    let current = generation
    isLoading = true
    defer { if current == generation { isLoading = false } }
    do {
      let file = try await downloader.localURL(for: request)
      guard current == generation else { return }
      attach(AVPlayer(url: file))
    } catch is CancellationError {
      return
    } catch {
      logger.error("media load failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Pauses and drops the player and its time observer. Safe to call twice.
  func teardown() {
    generation += 1
    pause()
    if let timeObserver {
      player?.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    player = nil
    isLoaded = false
    isLoading = false
    position = 0
  }

  /// Whether the periodic time observer is installed.
  var isObserving: Bool { timeObserver != nil }

  private func attach(_ player: AVPlayer) {
    self.player = player
    // The observer runs on the main queue, so the closure is already on the main actor.
    timeObserver = player.addPeriodicTimeObserver(forInterval: Self.observerInterval, queue: .main) {
      [weak self] time in
      MainActor.assumeIsolated { self?.observe(time) }
    }
    isLoaded = true
  }

  /// One tick: the position, the real duration once known, and the end of the clip or a failed item.
  private func observe(_ time: CMTime) {
    guard let item = player?.currentItem else { return }
    let length = item.duration.seconds
    if length.isFinite, length > 0 { duration = length }
    let seconds = time.seconds
    if seconds.isFinite { position = min(max(seconds, 0), duration > 0 ? duration : .infinity) }
    if item.status == .failed {
      logger.error("playback failed: \(String(describing: item.error), privacy: .public)")
      pause()
    } else if isPlaying, duration > 0, position >= duration - 0.05 {
      pause()
    }
  }

  func toggle() {
    isPlaying ? pause() : play()
  }

  func play() {
    guard let player, !isPlaying else { return }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      logger.error("audio session failed: \(String(describing: error), privacy: .public)")
    }
    if duration > 0, position >= duration { seek(to: 0) }
    player.play()
    isPlaying = true
  }

  func pause() {
    guard isPlaying else { return }
    player?.pause()
    isPlaying = false
  }

  /// Seeks to `seconds`, clamped to the clip. The position moves at once; the player follows.
  func seek(to seconds: Double) {
    let upper = duration > 0 ? duration : max(seconds, 0)
    position = min(max(seconds, 0), upper)
    player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func skipBack() {
    seek(to: position - Self.skipBackSeconds)
  }
}
