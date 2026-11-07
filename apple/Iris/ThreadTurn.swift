import Foundation
import IrisCore
import IrisUI

/// One block of a conversation, in the order it is read: what was said, the answer, an answer still on its way, a turn that failed.
/// The iPhone's thread view and the Mac's detail pane derive the same turns from the same rules.
struct ThreadTurn: Identifiable, Equatable {
  enum Content: Equatable {
    case user(String)
    case assistant(String, mermaid: [Int: MermaidAsset])
    case pending(StepProgress, caption: String)
    case failed(String)
  }

  let id: String
  let date: Date?
  let content: Content

  /// The turns of a loaded thread: per memo (oldest first) what was said, then its reply, its failure or its pending answer.
  static func make(from detail: ThreadDetail?) -> [ThreadTurn] {
    guard let detail else { return [] }
    var users: [String: ThreadMessage] = [:]
    var replies: [String: ThreadMessage] = [:]
    for message in detail.messages {
      if message.role == .user { users[message.memoId] = message } else { replies[message.memoId] = message }
    }
    var turns: [ThreadTurn] = []
    for memo in detail.memos {
      if let user = users[memo.id] {
        turns.append(ThreadTurn(id: "\(memo.id).user", date: user.createdAt, content: .user(user.content)))
      }
      if let reply = replies[memo.id] {
        turns.append(
          ThreadTurn(
            id: "\(memo.id).reply", date: reply.createdAt,
            content: .assistant(reply.content, mermaid: memo.mermaidAssets)))
      } else if let outcome = outcome(of: memo) {
        turns.append(outcome)
      }
    }
    return turns
  }

  /// The turns one memo makes on its own (what the list holds): its transcript, then its reply, failure or pending answer. Used
  /// before the thread has loaded and when it cannot be read; the ids match ``make(from:)``, so the loaded thread replaces them in place.
  static func make(memo: Memo) -> [ThreadTurn] {
    var turns: [ThreadTurn] = []
    if let transcript = memo.transcript, !transcript.isEmpty {
      turns.append(ThreadTurn(id: "\(memo.id).user", date: memo.createdAt, content: .user(transcript)))
    }
    if let reply = memo.replyText, !reply.isEmpty {
      turns.append(
        ThreadTurn(
          id: "\(memo.id).reply", date: memo.updatedAt, content: .assistant(reply, mermaid: memo.mermaidAssets)))
    } else if let outcome = outcome(of: memo) {
      turns.append(outcome)
    }
    return turns
  }

  /// A memo without a reply is either failed or still running; a finished one (a transcript only) has nothing to add.
  private static func outcome(of memo: Memo) -> ThreadTurn? {
    if memo.state == .failed {
      return ThreadTurn(
        id: "\(memo.id).failed", date: memo.updatedAt,
        content: .failed(memo.error ?? String(localized: "This turn failed.", comment: "Failed turn in a thread")))
    }
    guard !memo.state.isResultReady else { return nil }
    return ThreadTurn(
      id: "\(memo.id).pending", date: nil, content: .pending(memo.stepProgress, caption: memo.pendingCaption))
  }
}
