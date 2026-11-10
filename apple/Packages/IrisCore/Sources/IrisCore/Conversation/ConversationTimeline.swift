import Foundation

extension Memo {
  /// A Hermes memo is a conversation as soon as it exists, before `act` too; a transcript-only memo and a deleted one are
  /// documents. Both platforms open the chat layout on this one rule.
  public var isConversation: Bool { !isDeleted && mode == .hermes }
}

/// One block of a conversation, in the order it is read: what was said, the answer, an answer still on its way, a turn that failed.
/// The ids are stable between a single memo's entries and the loaded thread's, so the thread replaces them in place.
public struct ConversationEntry: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case user(String)
    /// The answer, markdown.
    case reply(String)
    case pending
    /// The memo's error, when it has one.
    case failed(String?)
  }

  /// `<memoId>.user`, `.reply`, `.pending` or `.failed`.
  public let id: String
  /// The memo this entry belongs to.
  public let memo: Memo
  public let date: Date?
  public let kind: Kind

  public init(id: String, memo: Memo, date: Date?, kind: Kind) {
    self.id = id
    self.memo = memo
    self.date = date
    self.kind = kind
  }
}

/// Derives the entries of a conversation. The iPhone's chat and the Mac's detail pane read the same rules.
public enum ConversationTimeline {
  /// The entries of a loaded thread: per memo (oldest first) what was said, then its reply, its failure or its pending answer.
  public static func entries(of thread: ThreadDetail) -> [ConversationEntry] {
    var users: [String: ThreadMessage] = [:]
    var replies: [String: ThreadMessage] = [:]
    for message in thread.messages {
      if message.role == .user { users[message.memoId] = message } else { replies[message.memoId] = message }
    }
    var entries: [ConversationEntry] = []
    for memo in thread.memos {
      if let user = users[memo.id] {
        entries.append(
          ConversationEntry(id: "\(memo.id).user", memo: memo, date: user.createdAt, kind: .user(user.content)))
      }
      if let reply = replies[memo.id] {
        entries.append(
          ConversationEntry(id: "\(memo.id).reply", memo: memo, date: reply.createdAt, kind: .reply(reply.content)))
      } else if let outcome = outcome(of: memo) {
        entries.append(outcome)
      }
    }
    return entries
  }

  /// The entries one memo makes on its own (what a list holds): its transcript, then its reply, failure or pending answer.
  /// Used before the thread has loaded and when it cannot be read; the ids match ``entries(of:)-(ThreadDetail)``.
  public static func entries(of memo: Memo) -> [ConversationEntry] {
    var entries: [ConversationEntry] = []
    if let transcript = memo.transcript, !transcript.isEmpty {
      entries.append(
        ConversationEntry(id: "\(memo.id).user", memo: memo, date: memo.createdAt, kind: .user(transcript)))
    }
    if let reply = memo.replyText, !reply.isEmpty {
      entries.append(
        ConversationEntry(id: "\(memo.id).reply", memo: memo, date: memo.updatedAt, kind: .reply(reply)))
    } else if let outcome = outcome(of: memo) {
      entries.append(outcome)
    }
    return entries
  }

  /// A memo without a reply is either failed or still running; a finished one (a transcript only) has nothing to add.
  private static func outcome(of memo: Memo) -> ConversationEntry? {
    if memo.state == .failed {
      return ConversationEntry(id: "\(memo.id).failed", memo: memo, date: memo.updatedAt, kind: .failed(memo.error))
    }
    guard !memo.state.isResultReady else { return nil }
    return ConversationEntry(id: "\(memo.id).pending", memo: memo, date: nil, kind: .pending)
  }
}

extension ThreadDetail {
  /// The thread with a memo this device just created in it: the memo and, when it has one, its transcript as the user message,
  /// so it shows at once before the next fetch brings the server's version. `nil` when the memo is already in the thread.
  public func appending(sent memo: Memo) -> ThreadDetail? {
    guard !memos.contains(where: { $0.id == memo.id }) else { return nil }
    var next = self
    next.memos.append(memo)
    if let transcript = memo.transcript {
      next.messages.append(
        ThreadMessage(memoId: memo.id, role: .user, content: transcript, createdAt: memo.createdAt))
    }
    return next
  }
}
