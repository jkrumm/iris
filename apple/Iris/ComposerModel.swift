import Foundation
import IrisCore
import Observation
import os

/// What opens the composer: a new memo, or a reply that continues a thread (`POST /v1/memos/text` takes `threadId`).
struct ComposerRequest: Identifiable, Equatable {
  let id = UUID()
  var mode: MemoMode = .auto
  var threadId: String?

  /// A reply into a thread screen: a chat stays a chat, anything else continues through Hermes.
  static func reply(toThread id: String, kind: ThreadKind) -> ComposerRequest {
    ComposerRequest(mode: kind == .chat ? .chat : .hermes, threadId: id)
  }

  /// A reply to `memo`: its thread when it has one, else a fresh chat about it (a memo outside a thread has nothing
  /// to continue).
  static func reply(to memo: Memo) -> ComposerRequest {
    guard let threadId = memo.threadId else { return ComposerRequest(mode: .chat) }
    return ComposerRequest(mode: memo.mode == .unknown ? .chat : memo.mode, threadId: threadId)
  }
}

/// The typed-memo composer: text, a mode, and one send. A send that failed keeps the memo id while the body stays
/// the same, so a retry after a lost answer finds the memo the server already created instead of making a second.
@Observable
final class ComposerModel {
  var text = ""
  var mode: MemoMode
  let threadId: String?
  private(set) var isSending = false
  /// The words of the last failed send; cleared when the user edits or sends again.
  private(set) var failure: String?

  private let client: any APIClient
  private let now: () -> Date
  private let makeID: () -> String
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "composer")
  private var attempt: Attempt?

  private struct Attempt: Equatable {
    var id: String
    var startedAt: Date
    var mode: MemoMode
    var text: String
  }

  init(
    request: ComposerRequest, client: any APIClient, now: @escaping () -> Date = { Date() },
    makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
  ) {
    mode = request.mode
    threadId = request.threadId
    self.client = client
    self.now = now
    self.makeID = makeID
  }

  /// The modes the server accepts for a typed memo.
  static let modes: [MemoMode] = MemoMode.allCases

  var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Unicode code points, as the server counts them.
  var characterCount: Int { trimmedText.unicodeScalars.count }

  var isOverLimit: Bool { characterCount > CreateTextMemoRequest.maxTextCharacters }

  var canSend: Bool { characterCount > 0 && !isOverLimit && !isSending }

  /// Cancel closes the sheet and would drop the answer of a send that is already on the wire.
  var canCancel: Bool { !isSending }

  /// Creates the memo; nil when the send failed (``failure`` says so) or there is nothing to send.
  func send() async -> Memo? {
    guard canSend else { return nil }
    isSending = true
    failure = nil
    defer { isSending = false }
    let body = Attempt(id: "", startedAt: .distantPast, mode: mode, text: trimmedText)
    if attempt.map({ $0.mode != body.mode || $0.text != body.text }) ?? true {
      attempt = Attempt(id: makeID(), startedAt: now(), mode: body.mode, text: body.text)
    }
    guard let attempt else { return nil }
    do {
      return try await client.createTextMemo(
        CreateTextMemoRequest(
          id: attempt.id, mode: attempt.mode, startedAt: attempt.startedAt, text: attempt.text, threadId: threadId))
    } catch is CancellationError {
      return nil
    } catch {
      logger.error("typed memo failed: \(String(describing: error), privacy: .public)")
      failure = String(
        localized: "Could not send the memo. Your text is still here.", comment: "Composer error after a failed send")
      return nil
    }
  }
}
