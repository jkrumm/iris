import Foundation
import Testing

@testable import IrisCore

enum ConversationFixtures {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  static func memo(
    _ id: String = "m", state: MemoState = .notified, transcript: String? = "a question", reply: String? = nil,
    error: String? = nil, mode: MemoMode = .hermes, threadId: String? = nil, deletedAt: Date? = nil
  ) -> Memo {
    let created = now.addingTimeInterval(-60)
    return Memo(
      id: id, mode: mode, device: "mac", startedAt: created, state: state, error: error, transcript: transcript,
      replyText: reply, threadId: threadId, isTyped: true, deletedAt: deletedAt, createdAt: created,
      updatedAt: created.addingTimeInterval(5))
  }

  static func detail(_ memos: [Memo]) -> ThreadDetail {
    var messages: [ThreadMessage] = []
    for memo in memos {
      messages.append(
        ThreadMessage(memoId: memo.id, role: .user, content: memo.transcript ?? "", createdAt: memo.createdAt))
      if let reply = memo.replyText {
        messages.append(ThreadMessage(memoId: memo.id, role: .assistant, content: reply, createdAt: memo.updatedAt))
      }
    }
    return ThreadDetail(
      thread: MemoThread(
        id: "t", kind: "hermes", title: "Title", createdAt: memos[0].createdAt, updatedAt: memos.last!.updatedAt,
        lastMemoId: memos.last?.id),
      memos: memos, messages: messages)
  }
}

@Suite("ConversationTimeline")
struct ConversationTimelineTests {
  private func memo(
    _ id: String = "m", state: MemoState = .notified, transcript: String? = "a question", reply: String? = nil,
    error: String? = nil, mode: MemoMode = .hermes, threadId: String? = nil, deletedAt: Date? = nil
  ) -> Memo {
    ConversationFixtures.memo(
      id, state: state, transcript: transcript, reply: reply, error: error, mode: mode, threadId: threadId,
      deletedAt: deletedAt)
  }

  @Test("a finished memo is its question and its answer")
  func answered() {
    let entries = ConversationTimeline.entries(of: memo(reply: "the answer"))
    #expect(entries.map(\.id) == ["m.user", "m.reply"])
    #expect(entries.first?.kind == .user("a question"))
    #expect(entries.last?.kind == .reply("the answer"))
    #expect(entries.allSatisfy { $0.memo.id == "m" })
  }

  @Test("a memo still in the pipeline is its question and a pending answer")
  func pending() {
    let entries = ConversationTimeline.entries(of: memo(state: .transcribed))
    #expect(entries.map(\.id) == ["m.user", "m.pending"])
    #expect(entries.last?.kind == .pending)
    #expect(entries.last?.date == nil)
  }

  @Test("a failed memo ends in its error")
  func failed() {
    let entries = ConversationTimeline.entries(of: memo(state: .failed, error: "Hermes was not reachable"))
    #expect(entries.last?.id == "m.failed")
    #expect(entries.last?.kind == .failed("Hermes was not reachable"))
    #expect(ConversationTimeline.entries(of: memo(state: .failed)).last?.kind == .failed(nil))
  }

  @Test("a memo with no transcript yet has only its pending answer; a transcript-only memo has only its question")
  func partial() {
    #expect(ConversationTimeline.entries(of: memo(state: .received, transcript: nil)).map(\.id) == ["m.pending"])
    #expect(ConversationTimeline.entries(of: memo(transcript: "words", mode: .transcribe)).map(\.id) == ["m.user"])
    #expect(ConversationTimeline.entries(of: memo(transcript: "", reply: "")).isEmpty)
  }

  @Test("the memo's own entries carry the ids of the loaded thread's, so the thread replaces them in place")
  func idsMatchTheThread() {
    let finished = memo(reply: "the answer")
    let detail = ConversationFixtures.detail([finished])
    #expect(ConversationTimeline.entries(of: detail).map(\.id) == ConversationTimeline.entries(of: finished).map(\.id))
  }

  @Test("a thread is per memo, oldest first: the question, then the answer, failure or pending answer")
  func threadOrder() {
    let detail = ConversationFixtures.detail([
      memo("a", reply: "first"), memo("b", state: .failed, error: "boom"), memo("c", state: .routed),
    ])
    let entries = ConversationTimeline.entries(of: detail)
    #expect(entries.map(\.id) == ["a.user", "a.reply", "b.user", "b.failed", "c.user", "c.pending"])
    #expect(entries[0].date == detail.memos[0].createdAt)
    #expect(entries[1].date == detail.memos[0].updatedAt)
    #expect(entries[3].date == detail.memos[1].updatedAt)
  }

  @Test("a hermes memo is a conversation as soon as it exists; transcripts and deleted memos are documents")
  func isConversation() {
    #expect(memo(state: .received, transcript: nil).isConversation, "before act, with no thread id")
    #expect(memo(threadId: "m").isConversation)
    #expect(memo(state: .failed, error: "x").isConversation)
    #expect(!memo(mode: .transcribe).isConversation)
    #expect(!memo(deletedAt: ConversationFixtures.now).isConversation)
  }

  @Test("a sent memo joins the thread once, with its transcript as the user message")
  func appendingSent() throws {
    let detail = ConversationFixtures.detail([memo("a", reply: "x")])
    let sent = memo("b", state: .receiving, transcript: "next")

    let merged = try #require(detail.appending(sent: sent))
    #expect(merged.memos.map(\.id) == ["a", "b"])
    #expect(merged.messages.last == ThreadMessage(memoId: "b", role: .user, content: "next", createdAt: sent.createdAt))
    #expect(merged.appending(sent: sent) == nil)
    #expect(ConversationTimeline.entries(of: merged).map(\.id) == ["a.user", "a.reply", "b.user", "b.pending"])
  }
}
