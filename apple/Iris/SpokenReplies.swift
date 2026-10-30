import Foundation
import IrisCore
import Observation
import os

/// The spoken-replies setting and what it does: when it is on and the app is in the foreground, a memo this device created
/// is read out the moment it finishes (`memo.done`), through the shared ``SpeechPlayer``. A memo is spoken once per launch,
/// and one that another device recorded never is: the Mac's memos do not talk on the phone.
///
/// It never interrupts: while a reply plays or loads, the open detail's recording plays, or a take records (any take, a
/// thread's hold-to-talk included), the memo is skipped for good. No queue, no later auto-play; the reply stays available
/// as the memo's notification and [Play].
/// What the microphone is doing, for ``SpokenReplies``: whether a take is open now, and how many have opened so far (a take
/// that opened and closed while a reply downloaded left `isOpen` false again, but `started` moved).
nonisolated struct TakeActivity: Equatable, Sendable {
  var isOpen = false
  var started = 0
}

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
  private let takes: () -> TakeActivity
  /// Memos that were read out or skipped because something was busy, and those being fetched or downloaded right now (a second `memo.done` waits for the first).
  private var spoken: Set<String> = []
  private var inFlight: Set<String> = []
  /// The take activity when each memo's latest update arrived (``memoUpdated(id:)``), consumed by its `memo.done`.
  private var noted: [String: TakeActivity] = [:]
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "spoken-replies")

  /// - Parameters:
  ///   - media: The media routes for the connection saved right now.
  ///   - createdHere: Whether this device created the memo (`CreatedMemoLog`).
  ///   - takes: The take activity: any take counts (starting, recording, paused or stopping), whichever screen owns it.
  init(
    store: any SpokenRepliesStore, speech: SpeechPlayer, client: any APIClient,
    media: @escaping () -> any MemoMediaSource, createdHere: @escaping (String) async -> Bool,
    takes: @escaping () -> TakeActivity
  ) {
    self.store = store
    self.speech = speech
    self.client = client
    self.media = media
    self.createdHere = createdHere
    self.takes = takes
    isOn = store.load()
  }

  /// What the microphone is doing right now. A caller that learns of `memo.done` on one task and calls ``memoDone(id:takes:)``
  /// on another passes this sample from the first: a take that opened in between still counts.
  var takeSample: TakeActivity { takes() }

  /// `memo.updated` for `id` reached the app: remembers what the microphone was doing. `memo.done` always follows the
  /// update of the same state, but waits behind its list refresh, so a take that opens and closes in that gap is only
  /// visible in this sample.
  func memoUpdated(id: String) {
    if noted.count > 100 { noted.removeAll() }
    noted[id] = takes()
  }

  /// `memo.done` for `id`: speaks the reply when everything allows it. `takes` is the sample from when the event arrived
  /// (``takeSample``); without one the sample is taken here.
  func memoDone(id: String, takes sampled: TakeActivity? = nil) async {
    guard isOn, isForeground, !spoken.contains(id), inFlight.insert(id).inserted else { return }
    defer { inFlight.remove(id) }
    let earlier = noted.removeValue(forKey: id)
    let sample = earlier ?? sampled ?? takes()
    let takesBefore = sample.started
    // A take that was open when the event arrived counts even if it has closed again since.
    guard !sample.isOpen, !(sampled?.isOpen ?? false), !isBusy(takesStartedAfter: takesBefore) else { return skip(id) }
    guard await createdHere(id) else { return }
    do {
      let memo = try await client.memo(id: id).memo
      // Re-checked after the fetch and again after the download (`shouldPlay`): the setting, the app state or what is busy
      // may have changed while either was on the wire.
      guard isOn, isForeground, memo.isSpeakable, !memo.archived else { return }
      guard !isBusy(takesStartedAfter: takesBefore) else { return skip(id) }
      // Marked once it plays, or once something busy made it wait. A reply that failed for any other reason (no speech, a
      // failed download) stays unmarked, but nothing retries it: the server sends `memo.done` once, and the reply is still
      // there for [Play].
      var wasBusy = false
      let started = await speech.play(
        memo, source: media(),
        shouldPlay: {
          wasBusy = isBusy(takesStartedAfter: takesBefore)
          return isOn && isForeground && !wasBusy
        })
      if started {
        spoken.insert(id)
      } else if wasBusy {
        skip(id)
      } else if !spoken.contains(id) {
        logger.notice("spoken reply not started for \(id, privacy: .public): no speech, or no longer wanted")
      }
    } catch is CancellationError {
      return
    } catch {
      logger.error("spoken reply not played: \(String(describing: error), privacy: .public)")
    }
  }

  /// The one busy rule: a reply or the detail's recording plays, a take is open, or a take opened since `takesStartedAfter`
  /// (it may be over again by now, and the reply must not start late).
  private func isBusy(takesStartedAfter: Int) -> Bool {
    let activity = takes()
    return activity.isOpen || activity.started != takesStartedAfter || speech.isBusy
  }

  /// Marks `id` skipped for good: there is no queue and no later auto-play.
  private func skip(_ id: String) {
    spoken.insert(id)
    logger.notice("spoken reply skipped for \(id, privacy: .public): busy")
  }
}
