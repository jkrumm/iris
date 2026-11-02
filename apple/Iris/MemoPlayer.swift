import AVFoundation
import Observation
import os

/// The audio session as playback needs it: claimed when a clip starts, handed back when playback is over. Behind a port so the
/// player's hold on the session can be tested; the system session is the only production adapter.
protocol PlaybackAudioSession {
  func activate() throws
  /// Gives the session up and tells other apps they may resume (music that was playing before the clip).
  func deactivate() throws
}

struct SystemPlaybackSession: PlaybackAudioSession {
  func activate() throws {
    try AVAudioSession.sharedInstance().setCategory(.playback)
    try AVAudioSession.sharedInstance().setActive(true)
  }

  func deactivate() throws {
    let session = AVAudioSession.sharedInstance()
    // A take reconfigures the shared session to record (`.playAndRecord`): then it is the take's, whoever asks.
    guard session.category == .playback else { return }
    try session.setActive(false, options: .notifyOthersOnDeactivation)
  }
}

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
  private let session: any PlaybackAudioSession
  /// This player claimed the audio session and has not handed it back.
  private var holdsSession = false
  /// Whether a take holds the microphone or is about to (``TakeController``'s flag, bound by the composition root for the
  /// shared speech player). The player never gives the session up while it is true: the take's session is not the player's to
  /// release. A player nobody bound (a detail's recording) is covered by ``SystemPlaybackSession``, which leaves a session
  /// that is no longer `.playback` alone.
  var captureActive: () -> Bool = { false }
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "player")

  /// `duration` is the length the memo says; the item replaces it once AVFoundation knows the real one.
  init(
    duration: Double = 0, downloader: MediaDownloader = .shared,
    session: any PlaybackAudioSession = SystemPlaybackSession()
  ) {
    self.duration = duration
    self.downloader = downloader
    self.session = session
  }

  isolated deinit {
    teardown()
  }

  /// Fetches `request` (a file URL is used as is, anything else is downloaded with its headers) and points the player
  /// at the file. Nil clears the player. A newer load or a teardown while this one downloads wins.
  func load(_ request: MediaRequest?) async {
    guard let request else { return teardown() }
    // A clip replacing another keeps the session through the download: the next one is about to play.
    reset()
    let current = generation
    isLoading = true
    defer { if current == generation { isLoading = false } }
    do {
      let file = try await downloader.localURL(for: request)
      guard current == generation else { return }
      attach(AVPlayer(url: file))
    } catch is CancellationError {
      if current == generation { releaseSession() }
    } catch {
      logger.error("media load failed: \(String(describing: error), privacy: .public)")
      if current == generation { releaseSession() }
    }
  }

  /// Pauses, drops the player and its time observer, and gives the audio session back. Safe to call twice.
  func teardown() {
    reset()
    releaseSession()
  }

  private func reset() {
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
      releaseSession()
    } else if isPlaying, duration > 0, position >= duration - 0.05 {
      pause()
      releaseSession()
    }
  }

  func toggle() {
    isPlaying ? pause() : play()
  }

  func play() {
    guard let player, !isPlaying else { return }
    do {
      try session.activate()
      holdsSession = true
    } catch {
      logger.error("audio session failed: \(String(describing: error), privacy: .public)")
    }
    if duration > 0, position >= duration { seek(to: 0) }
    player.play()
    isPlaying = true
  }

  /// Hands the session back with `.notifyOthersOnDeactivation` once playback is over (the clip ended, or the player is torn
  /// down), unless a take holds the microphone: its session is not ours to release.
  private func releaseSession() {
    guard holdsSession else { return }
    guard !captureActive() else {
      holdsSession = false
      return
    }
    do {
      try session.deactivate()
      holdsSession = false
    } catch {
      // Another player of the app may still be audible, or the system refused: the claim is kept, so the next release retries.
      logger.notice("audio session not released: \(String(describing: error), privacy: .public)")
    }
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
