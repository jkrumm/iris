import AVFoundation
import Observation
import os

/// One AVPlayer behind the detail screen: the recording or the spoken reply. It publishes what the player bar draws
/// (`position`, `duration`, `isPlaying`) and takes what it sends (toggle, seek, skip back). The view runs
/// ``track()`` while it is on screen; nothing here outlives that task.
@Observable
final class MemoPlayer {
  /// What the skip-back icon rewinds.
  static let skipBackSeconds: Double = 10

  private(set) var position: Double = 0
  private(set) var duration: Double
  private(set) var isPlaying = false
  private(set) var isLoaded = false

  private var player: AVPlayer?
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "player")

  /// `duration` is the length the memo says; the item replaces it once AVFoundation knows the real one.
  init(duration: Double = 0) {
    self.duration = duration
  }

  /// Points the player at `request` (the headers ride along as the asset's HTTP header fields). Nil clears it.
  func load(_ request: MediaRequest?) {
    pause()
    position = 0
    guard let request else {
      player = nil
      isLoaded = false
      return
    }
    let options = request.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": request.headers]
    player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: request.url, options: options)))
    isLoaded = true
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

  /// Follows the player while it plays: the position, the real duration, and the end of the clip. Runs until the
  /// task is cancelled or playback stops.
  func track() async {
    while isPlaying, !Task.isCancelled {
      if let item = player?.currentItem {
        let length = item.duration.seconds
        if length.isFinite, length > 0 { duration = length }
        let current = player?.currentTime().seconds ?? position
        position = min(current.isFinite ? current : position, duration > 0 ? duration : .infinity)
        if item.status == .failed {
          logger.error("playback failed: \(String(describing: item.error), privacy: .public)")
          pause()
        } else if duration > 0, position >= duration - 0.05 {
          pause()
        }
      }
      guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
    }
  }
}
