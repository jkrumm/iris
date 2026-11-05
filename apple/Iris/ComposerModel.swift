import Foundation
import IrisCapture
import IrisCore
import Observation

/// What opens the composer: a new memo, or a reply that continues a thread (`POST /v1/memos/text` takes `threadId`).
struct ComposerRequest: Identifiable, Equatable {
  let id = UUID()
  var threadId: String?

  /// A reply into a thread screen: it continues through Hermes.
  static func reply(toThread id: String) -> ComposerRequest {
    ComposerRequest(threadId: id)
  }

  /// A reply to `memo`: its thread when it has one, else a fresh Hermes memo (a memo outside a thread has nothing to
  /// continue).
  static func reply(to memo: Memo) -> ComposerRequest {
    ComposerRequest(threadId: memo.threadId)
  }
}

/// The typed-memo composer: text and two send targets (Hermes, Transcribe). The send hands the text to the outbox, which creates the memo by id
/// (idempotent on the server) and keeps trying until it has: the sheet closes either way, with the memo, or with
/// "queued" when the server could not be reached.
@Observable
final class ComposerModel {
  var text = ""
  let threadId: String?
  private(set) var isSending = false
  /// Why the last send was refused (the outbox could not be opened, or the server said no for good); the text stays. Cleared
  /// by the next send.
  private(set) var failure: String?

  private let outbox: OutboxService
  private let now: () -> Date
  private let makeID: () -> MemoID

  init(
    request: ComposerRequest, outbox: OutboxService, now: @escaping () -> Date = { Date() },
    makeID: @escaping () -> MemoID = { MemoID() }
  ) {
    threadId = request.threadId
    self.outbox = outbox
    self.now = now
    self.makeID = makeID
  }

  /// A reply into a thread continues through Hermes only (the server refuses `threadId` with Transcribe).
  var offersTranscribe: Bool { threadId == nil }

  var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Unicode code points, as the server counts them.
  var characterCount: Int { trimmedText.unicodeScalars.count }

  var isOverLimit: Bool { characterCount > CreateTextMemoRequest.maxTextCharacters }

  var canSend: Bool { characterCount > 0 && !isOverLimit && !isSending }

  /// Cancel closes the sheet and would drop the answer of a send that is already on the wire.
  var canCancel: Bool { !isSending }

  /// Hands the text over as a memo of `mode`; nil when there is nothing to send, `mode` is Transcribe in a thread reply, the
  /// outbox refused it or the server did for good (``failure`` says so).
  func send(mode: MemoMode = .hermes) async -> SendOutcome? {
    guard canSend, mode == .hermes || offersTranscribe else { return nil }
    isSending = true
    failure = nil
    defer { isSending = false }
    let submission = TextSubmission(
      id: makeID(), mode: mode, text: trimmedText, threadId: threadId, startedAt: now())
    let outcome = await outbox.submitText(submission)
    switch outcome {
    case .refused:
      failure = String(
        localized: "Could not queue the memo. Your text is still here.",
        comment: "Composer error when the outbox is closed")
      return nil
    case .stalled(let reason):
      // The server will say no again: the sheet stays open with the text, and the reason tells what to change.
      failure = String(
        localized: "The server refused it: \(reason). Your text is still here.",
        comment: "Composer error when the server refused the memo for good")
      return nil
    case .sent, .queued:
      return outcome
    }
  }
}
