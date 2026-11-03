import AVFoundation
import IrisCore
import Observation
import os

/// What the Mac plays for a memo: the recording or the spoken reply.
enum MacClip: Equatable {
  case recording
  case reply
}

/// The one player of the main window: the memo's recording or its spoken reply. The iPhone's `MemoPlayer` configures an
/// `AVAudioSession`, which macOS does not have, so the Mac plays through a bare `AVPlayer`: the authenticated download is the
/// shared ``MediaDownloader`` (the player only ever sees the file), and one clip plays at a time; starting another stops the first.
@MainActor
@Observable
final class MacAudioPlayer {
  /// The clip that is loading or playing, with the memo it belongs to.
  private(set) var current: (memoID: String, clip: MacClip)?
  private(set) var isPlaying = false
  private(set) var isLoading = false
  /// Why the last clip did not play, and the memo it was for; cleared by the next start.
  private(set) var failure: String?
  private(set) var failedMemoID: String?

  private var player: AVPlayer?
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

  /// Plays `request` for the memo, or stops it when that clip is the one that plays. `nil`: nothing to play.
  func toggle(_ memoID: String, _ clip: MacClip, request: MediaRequest?) {
    if isCurrent(memoID, clip) {
      stop()
      return
    }
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
    player = nil
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
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    }
    isLoading = false
    isPlaying = true
    player.play()
  }
}
