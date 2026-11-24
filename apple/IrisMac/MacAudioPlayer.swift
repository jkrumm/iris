import AVFoundation
import IrisCore
import IrisUI
import Observation
import os

/// What the Mac plays for a memo: the recording or the spoken reply.
enum MacClip: Equatable {
  case recording
  /// The spoken reply in one of its two forms: switching form while one plays starts the other.
  case reply(SpeechVariant)
}

extension ReplyPlayChoice {
  init(_ variant: SpeechVariant) {
    switch variant {
    case .summary: self = .summary
    case .full: self = .full
    }
  }
}

/// The one player of the main window: the memo's recording or its spoken reply. The iPhone's `MemoPlayer` configures an
/// `AVAudioSession`, which macOS does not have, so the Mac plays through a bare `AVPlayer`: the authenticated download is the
/// shared ``MediaDownloader`` (the player only ever sees the file), and one clip plays at a time; starting another stops the first.
/// The position follows a periodic time observer that lives while a clip is held: the inline reply players of the conversation draw
/// it, pause, resume and seek through it.
@MainActor
@Observable
final class MacAudioPlayer {
  /// The clip that is loading or playing, with the memo it belongs to.
  private(set) var current: (memoID: String, clip: MacClip)?
  private(set) var isPlaying = false
  private(set) var isLoading = false
  /// Where the held clip is and how long it is (the item's own length once known), in seconds; zero while nothing is held.
  private(set) var position: Double = 0
  private(set) var duration: Double = 0
  /// Why the last clip did not play, and the memo it was for; cleared by the next start.
  private(set) var failure: String?
  private(set) var failedMemoID: String?

  private var player: AVPlayer?
  private var timeObserver: Any?
  private var endObserver: (any NSObjectProtocol)?
  /// Bumped by every start and stop; a download that finds it changed belongs to a request that is gone.
  private var generation = 0
  private let downloader: MediaDownloader
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "player")

  init(downloader: MediaDownloader = .shared) {
    self.downloader = downloader
  }

  func isCurrent(_ memoID: String, _ clip: MacClip) -> Bool {
    current?.memoID == memoID && current?.clip == clip
  }

  /// The memo's spoken reply (either form) is loading or playing.
  func isReplyCurrent(_ memoID: String) -> Bool {
    guard let current, current.memoID == memoID else { return false }
    if case .reply = current.clip { return true }
    return false
  }

  /// The memo's spoken reply as an inline player draws it: nothing of it held is idle.
  func replyPlayback(for memoID: String) -> ReplyPlayback {
    guard let current, current.memoID == memoID, case .reply(let variant) = current.clip else { return .idle }
    return ReplyPlayback(
      isActive: true, isPlaying: isPlaying, isLoading: isLoading, position: position, duration: duration,
      choice: ReplyPlayChoice(variant))
  }

  /// The form of the memo's reply the player holds, if it holds one.
  func replyVariant(of memoID: String) -> SpeechVariant? {
    guard let current, current.memoID == memoID, case .reply(let variant) = current.clip else { return nil }
    return variant
  }

  /// Plays `request` for the memo, or stops it when that clip is the one that plays. `nil`: nothing to play.
  func toggle(_ memoID: String, _ clip: MacClip, request: MediaRequest?) {
    if isCurrent(memoID, clip) {
      stop()
      return
    }
    start(memoID, clip, request: request)
  }

  /// The inline player's button: pauses the clip that plays, resumes the one that is paused, ignores a tap while it loads, and
  /// starts `request` from the top when the memo's clip is not the one held.
  func togglePlayback(_ memoID: String, _ clip: MacClip, request: MediaRequest?) {
    guard isCurrent(memoID, clip) else {
      start(memoID, clip, request: request)
      return
    }
    guard !isLoading, let player else { return }
    if isPlaying {
      player.pause()
      isPlaying = false
    } else {
      player.play()
      isPlaying = true
    }
  }

  /// Moves the held clip to `seconds`; the position follows at once.
  func seek(to seconds: Double) {
    guard let player else { return }
    let upper = duration > 0 ? duration : max(seconds, 0)
    position = min(max(seconds, 0), upper)
    player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  /// Starts `request` from the top for the memo, replacing whatever was held.
  func start(_ memoID: String, _ clip: MacClip, request: MediaRequest?) {
    stop()
    guard let request else { return }
    generation += 1
    let started = generation
    current = (memoID, clip)
    isLoading = true
    failure = nil
    failedMemoID = nil
    Task {
      do {
        let url = try await downloader.localURL(for: request)
        guard started == generation else { return }
        play(url)
      } catch is CancellationError {
        return
      } catch {
        guard started == generation else { return }
        logger.error("clip not loaded: \(String(describing: error), privacy: .public)")
        failure = String(localized: "Could not load the audio", comment: "Detail: playback failed")
        failedMemoID = memoID
        stop()
      }
    }
  }

  func stop() {
    generation += 1
    player?.pause()
    if let timeObserver { player?.removeTimeObserver(timeObserver) }
    timeObserver = nil
    player = nil
    position = 0
    duration = 0
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    current = nil
    isPlaying = false
    isLoading = false
  }

  private func play(_ url: URL) {
    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    self.player = player
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated { self?.observe(time) }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    }
    isLoading = false
    isPlaying = true
    player.play()
  }

  /// One tick: the position, and the item's own length once AVFoundation knows it.
  private func observe(_ time: CMTime) {
    guard let item = player?.currentItem else { return }
    let length = item.duration.seconds
    if length.isFinite, length > 0 { duration = length }
    let seconds = time.seconds
    if seconds.isFinite { position = min(max(seconds, 0), duration > 0 ? duration : .infinity) }
  }
}
