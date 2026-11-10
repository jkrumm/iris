import Foundation
import Observation
import os

/// The bottom bar of every conversation screen: the draft of a typed reply and the voice take. The screen sends the draft
/// itself (``takeDraft()``, then ``restoreDraft(_:)`` when it could not go out); a spoken reply is handled here, and the memo it
/// became is returned from ``endVoice(cancelled:)`` for the screen to merge. Everything the user should be told arrives as a
/// ``Notice`` through ``onNotice``, which the app localizes and shows.
@MainActor
@Observable
public final class ReplyBarModel {
  /// What the user is told about a voice reply. The app owns the words.
  public enum Notice: Equatable, Sendable {
    case couldNotStartRecording
    /// A hold shorter than ``ReplyBarModel/minimumTake``.
    case tooShort
    /// The recorder failed mid-take and the take is lost.
    case recordingFailed
    case voiceFailed
    /// The reply went to the outbox instead of the server.
    case queued
  }

  /// A hold shorter than this is a touch, not a take.
  public static let minimumTake: TimeInterval = 0.8

  public var draft = ""
  /// When the take in progress began; `nil` when idle.
  public private(set) var voiceStartedAt: Date?
  /// Set after init when the owner needs `self` first (the app's screen model); the init parameter covers the plain case.
  @ObservationIgnored public var onNotice: (Notice) -> Void

  @ObservationIgnored private let voice: any VoiceReplyCapture
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private let logger = Logger(subsystem: "com.jkrumm.iris", category: "thread")
  @ObservationIgnored private var beginTask: Task<Bool, Never>?
  /// A take is being stopped and sent: a new hold must wait, the capture is still busy with the last one.
  private var isEndingVoice = false

  public init(
    voice: any VoiceReplyCapture, now: @escaping () -> Date = { Date() },
    onNotice: @escaping (Notice) -> Void = { _ in }
  ) {
    self.voice = voice
    self.now = now
    self.onNotice = onNotice
  }

  // MARK: Draft

  public var canSendDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// The trimmed draft, which is cleared; `nil` when it is blank.
  public func takeDraft() -> String? {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    draft = ""
    return text
  }

  /// Puts a text back that could not be sent. A blank draft becomes the text; a draft the user has typed since is kept, with the
  /// restored text in front of it on its own line, so nothing is lost either way.
  public func restoreDraft(_ text: String) {
    guard canSendDraft else {
      draft = text
      return
    }
    draft = text + "\n" + draft
  }

  // MARK: Voice

  public var isVoiceAvailable: Bool { voice.isAvailable && !isEndingVoice }

  /// Hold began. The state flips at once; the capture starts behind it, and ``endVoice(cancelled:)`` waits for that.
  public func beginVoice(threadID: String) {
    guard voiceStartedAt == nil, !isEndingVoice, voice.isAvailable else { return }
    voiceStartedAt = now()
    let request = VoiceReplyRequest(threadId: threadID, mode: .hermes)
    beginTask = Task {
      do {
        try await voice.begin(request)
        return true
      } catch {
        logger.error("voice reply could not start: \(String(describing: error), privacy: .public)")
        onNotice(.couldNotStartRecording)
        voiceStartedAt = nil
        return false
      }
    }
  }

  /// Hold ended. A hold shorter than ``minimumTake`` counts as a cancel with a hint. The memo the take became, when it
  /// became one.
  @discardableResult
  public func endVoice(cancelled: Bool) async -> Memo? {
    // Claim the take before the first suspension: the gesture's release and a cancel from the screen can both arrive.
    guard let beginTask else { return nil }
    self.beginTask = nil
    let startedAt = voiceStartedAt ?? now()
    isEndingVoice = true
    defer { isEndingVoice = false }
    let started = await beginTask.value
    let tooShort = now().timeIntervalSince(startedAt) < Self.minimumTake
    voiceStartedAt = nil
    guard started else { return nil }
    do {
      let outcome = try await voice.end(cancelled: cancelled || tooShort)
      if tooShort && !cancelled { onNotice(.tooShort) }
      switch outcome {
      case .sent(let memo):
        return memo
      case .queued:
        onNotice(.queued)
        return nil
      case .discarded:
        return nil
      case .recordingFailed:
        onNotice(.recordingFailed)
        return nil
      }
    } catch {
      logger.error("voice reply failed: \(String(describing: error), privacy: .public)")
      onNotice(.voiceFailed)
      return nil
    }
  }
}
