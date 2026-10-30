import Foundation
import IrisCore
import Observation
import os

/// The spoken-replies setting and what it does: when it is on and the app is in the foreground, a memo this device created
/// is read out the moment it finishes (`memo.done`), through the shared ``SpeechPlayer``. A memo is spoken once per launch,
/// and one that another device recorded never is: the Mac's memos do not talk on the phone.
@Observable
final class SpokenReplies {
  var isOn: Bool {
    didSet { if isOn != oldValue { store.save(isOn) } }
  }

  /// The app is in the foreground (the scene is active). Nothing speaks on its own while it is not: a reply that finishes in
  /// the background is a notification, and [Play] speaks it on demand.
  var isForeground = true

  private let store: any SpokenRepliesStore
  private let speech: SpeechPlayer
  private let client: any APIClient
  private let media: () -> any MemoMediaSource
  private let createdHere: (String) async -> Bool
  /// Memos that were read out, and those being fetched or downloaded right now (a second `memo.done` waits for the first).
  private var spoken: Set<String> = []
  private var inFlight: Set<String> = []
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "spoken-replies")

  /// - Parameters:
  ///   - media: The media routes for the connection saved right now.
  ///   - createdHere: Whether this device created the memo (`CreatedMemoLog`).
  init(
    store: any SpokenRepliesStore, speech: SpeechPlayer, client: any APIClient,
    media: @escaping () -> any MemoMediaSource, createdHere: @escaping (String) async -> Bool
  ) {
    self.store = store
    self.speech = speech
    self.client = client
    self.media = media
    self.createdHere = createdHere
    isOn = store.load()
  }

  /// `memo.done` for `id`: speaks the reply when everything allows it.
  func memoDone(id: String) async {
    guard isOn, isForeground, !spoken.contains(id), inFlight.insert(id).inserted else { return }
    defer { inFlight.remove(id) }
    guard await createdHere(id) else { return }
    do {
      let memo = try await client.memo(id: id).memo
      // Re-checked after the fetch and again after the download (`shouldPlay`): the setting or the app state may have changed
      // while either was on the wire.
      guard isOn, isForeground, memo.state == .notified, memo.hasReply, !memo.isDeleted, !memo.archived else { return }
      // Marked only once it plays. A reply the player could not take (another one was loading) stays unmarked, but nothing
      // retries it: the server sends `memo.done` once, and the reply is still there for [Play].
      if await speech.play(memo, source: media(), shouldPlay: { isOn && isForeground }) {
        spoken.insert(id)
      } else {
        logger.notice("spoken reply not started for \(id, privacy: .public): busy, no speech, or no longer wanted")
      }
    } catch is CancellationError {
      return
    } catch {
      logger.error("spoken reply not played: \(String(describing: error), privacy: .public)")
    }
  }
}
