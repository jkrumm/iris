import Foundation
import IrisCore
import IrisUI
import Testing

@testable import Iris

@MainActor
@Suite("ThreadTurn")
struct ThreadTurnTests {
  private func memo(
    state: MemoState = .notified, transcript: String? = "a question", reply: String? = nil, error: String? = nil,
    mode: MemoMode = .hermes
  ) -> Memo {
    let created = MemoFactory.now.addingTimeInterval(-60)
    return Memo(
      id: "m", mode: mode, device: "mac", startedAt: created, state: state, error: error, transcript: transcript,
      replyText: reply, threadId: "m", isTyped: true, createdAt: created, updatedAt: created.addingTimeInterval(5))
  }

  @Test("a finished memo is its question and its answer")
  func answered() {
    let turns = ThreadTurn.make(memo: memo(reply: "the answer"))
    #expect(turns.map(\.id) == ["m.user", "m.reply"])
    #expect(turns.first?.content == .user("a question"))
    if case .assistant(let text, let mermaid) = turns.last?.content {
      #expect(text == "the answer" && mermaid.isEmpty)
    } else {
      Issue.record("the second turn is not an answer")
    }
  }

  @Test("a memo still in the pipeline is its question and a pending answer")
  func pending() {
    let turns = ThreadTurn.make(memo: memo(state: .transcribed))
    #expect(turns.map(\.id) == ["m.user", "m.pending"])
    if case .pending(let progress, let caption) = turns.last?.content {
      #expect(progress.completed == 1 && !caption.isEmpty)
    } else {
      Issue.record("the second turn is not pending")
    }
  }

  @Test("a failed memo ends in its error")
  func failed() {
    let turns = ThreadTurn.make(memo: memo(state: .failed, error: "Hermes was not reachable"))
    #expect(turns.last?.id == "m.failed")
    #expect(turns.last?.content == .failed("Hermes was not reachable"))
  }

  @Test("a memo with no transcript yet has only its pending answer; a transcript-only memo has only its question")
  func partial() {
    #expect(ThreadTurn.make(memo: memo(state: .received, transcript: nil)).map(\.id) == ["m.pending"])
    #expect(ThreadTurn.make(memo: memo(transcript: "words", mode: .transcribe)).map(\.id) == ["m.user"])
  }

  @Test("the memo's own turns carry the ids of the loaded thread's, so the thread replaces them in place")
  func idsMatchTheThread() {
    let finished = memo(reply: "the answer")
    let detail = ThreadDetail(
      thread: MemoThread(
        id: "m", kind: "hermes", title: "t", createdAt: finished.createdAt, updatedAt: finished.updatedAt,
        lastMemoId: "m"),
      memos: [finished],
      messages: [
        ThreadMessage(memoId: "m", role: .user, content: "a question", createdAt: finished.createdAt),
        ThreadMessage(memoId: "m", role: .assistant, content: "the answer", createdAt: finished.updatedAt),
      ])
    #expect(ThreadTurn.make(from: detail).map(\.id) == ThreadTurn.make(memo: finished).map(\.id))
    #expect(ThreadTurn.make(from: nil).isEmpty)
  }
}
