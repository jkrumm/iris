import Foundation
import IrisCapture
import IrisCore
import IrisUI
import Testing

@testable import Iris

@MainActor
@Suite("ThreadModel")
struct ThreadModelTests {
  let client = FakeAPIClient(now: { MemoFactory.now })
  let threadID = "t"

  private func memo(
    _ id: String, age: TimeInterval, state: MemoState = .notified, mode: MemoMode = .chat, reply: String? = nil,
    blocks: [ReplyBlock] = [], error: String? = nil
  ) -> Memo {
    let created = MemoFactory.now.addingTimeInterval(-age)
    return Memo(
      id: id, mode: mode, device: "iphone", startedAt: created, state: state, error: error,
      transcript: "question \(id)", route: "hermes", replyText: reply, replyBlocks: blocks, threadId: threadID,
      isTyped: true, createdAt: created, updatedAt: created.addingTimeInterval(5))
  }

  private func detail(_ memos: [Memo], kind: ThreadKind = .chat) -> ThreadDetail {
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
        id: threadID, kind: kind, title: "Title", createdAt: memos[0].createdAt, updatedAt: memos.last!.updatedAt,
        lastMemoId: memos.last?.id),
      memos: memos, messages: messages)
  }

  private func model(
    voice: any VoiceReplyCapture = UnavailableVoiceReplyCapture(), now: @escaping () -> Date = { MemoFactory.now }
  ) -> ThreadModel {
    ThreadModel(route: ThreadRoute(id: threadID, title: "Row title"), client: client, voice: voice, now: now)
  }

  // MARK: Turns

  @Test("an answered memo is a question and an answer; the title falls back to the row's until the thread loads")
  func answeredTurns() async {
    await client.seed(detail([memo("a", age: 100, reply: "**Hi**")]))
    let thread = model()
    #expect(thread.title == "Row title" && thread.turns.isEmpty)

    await thread.load()
    #expect(thread.title == "Title")
    #expect(thread.turns.map(\.id) == ["a.user", "a.reply"])
    #expect(thread.turns[0].content == .user("question a"))
    #expect(thread.turns[1].content == .assistant("**Hi**", mermaid: [:]))
  }

  @Test("a memo still in the pipeline is a question with a pending answer that carries its progress")
  func pendingTurn() async {
    await client.seed(detail([memo("a", age: 100, reply: "done"), memo("b", age: 10, state: .routed, mode: .hermes)]))
    let thread = model()
    await thread.load()

    #expect(thread.turns.map(\.id) == ["a.user", "a.reply", "b.user", "b.pending"])
    guard case .pending(let progress, let caption) = thread.turns[3].content else {
      Issue.record("expected a pending turn")
      return
    }
    #expect(progress == StepProgress(completed: 2, total: 5))
    #expect(!caption.isEmpty)
  }

  @Test("when the reply lands the pending turn becomes the answer, and the thread's last turn stays the same memo")
  func reveal() async {
    await client.seed(detail([memo("a", age: 10, state: .routed)]))
    let thread = model()
    await thread.load()
    #expect(thread.turns.map(\.id) == ["a.user", "a.pending"])

    await client.seed(detail([memo("a", age: 10, state: .acted, reply: "the answer")]))
    await thread.load()
    #expect(thread.turns.map(\.id) == ["a.user", "a.reply"])
    #expect(thread.turns[1].content == .assistant("the answer", mermaid: [:]))
  }

  @Test("a failed memo is a failed turn with the server's words")
  func failedTurn() async {
    await client.seed(detail([memo("a", age: 10, state: .failed, error: "act failed: 503")]))
    let thread = model()
    await thread.load()
    #expect(thread.turns.last?.content == .failed("act failed: 503"))
  }

  @Test("an answer carries the memo's Mermaid PNGs by fence index, as the memo's own assets")
  func mermaidAssets() async {
    let block = ReplyBlock(
      index: 1, width: 320, height: 140, svg: SchemeAssets(light: "s-l", dark: "s-d"),
      png: SchemeAssets(light: "p-l", dark: "p-d"))
    await client.seed(detail([memo("a", age: 10, reply: "x", blocks: [block])]))
    let thread = model()
    await thread.load()

    let expected = MermaidAsset(
      light: ReplyAssetRef(memoID: "a", assetID: "p-l"), dark: ReplyAssetRef(memoID: "a", assetID: "p-d"),
      width: 320, height: 140)
    #expect(thread.turns.last?.content == .assistant("x", mermaid: [1: expected]))
  }

  // MARK: Loading

  @Test("a failed load keeps the thread on screen and only flags an empty screen")
  func failedLoad() async {
    await client.seed(detail([memo("a", age: 10, reply: "x")]))
    let thread = model()
    await client.enqueueFailure(.unexpectedStatus(500), for: .thread)
    await thread.load()
    #expect(thread.loadFailed && thread.detail == nil)

    await thread.load()
    #expect(!thread.loadFailed && thread.detail != nil)
    await client.enqueueFailure(.unexpectedStatus(500), for: .thread)
    await thread.load()
    #expect(!thread.loadFailed && thread.turns.count == 2)
  }

  @Test("a memo sent from this screen shows at once as a question with its pending answer, once")
  func didSend() async {
    await client.seed(detail([memo("a", age: 100, reply: "x")]))
    let thread = model()
    await thread.load()
    let sent = memo("b", age: 1, state: .transcribed)
    thread.didSend(sent)
    thread.didSend(sent)
    #expect(thread.turns.map(\.id) == ["a.user", "a.reply", "b.user", "b.pending"])
    #expect(thread.memoIDs == ["a", "b"])
  }

  @Test("replies are created in the thread's mode: a chat stays a chat, anything else goes through Hermes")
  func replyMode() async {
    await client.seed(detail([memo("a", age: 1)], kind: .hermes))
    let hermes = model()
    await hermes.load()
    #expect(hermes.replyMode == .hermes)
    let chat = ComposerRequest.reply(toThread: "t", kind: .chat)
    #expect(chat.mode == .chat && chat.threadId == "t")
  }

  // MARK: Voice

  private func fakeVoice() -> FakeVoiceReplyCapture {
    FakeVoiceReplyCapture(
      capture: FakeCapture(directory: FileManager.default.temporaryDirectory.appending(path: "iris-thread-tests")),
      client: client, now: { MemoFactory.now })
  }

  @Test("a voice reply is a capture request bound to the thread, and the take becomes a memo that continues it")
  func voiceReply() async throws {
    await client.seed(detail([memo("a", age: 100, reply: "x")]))
    let voice = fakeVoice()
    let clock = Clock(MemoFactory.now)
    let thread = model(voice: voice, now: { clock.now })
    await thread.load()

    thread.beginVoice()
    #expect(thread.voiceStartedAt == MemoFactory.now)
    clock.now = MemoFactory.now.addingTimeInterval(3)
    let sent = try #require(await thread.endVoice(cancelled: false))

    #expect(voice.requests == [VoiceReplyRequest(threadId: threadID, mode: .chat)])
    #expect(sent.threadId == threadID && sent.mode == .chat)
    #expect(thread.voiceStartedAt == nil)
    #expect(thread.memoIDs.last == sent.id)
  }

  @Test("a cancelled take sends nothing")
  func cancelledVoice() async {
    await client.seed(detail([memo("a", age: 100, reply: "x")]))
    let voice = fakeVoice()
    let clock = Clock(MemoFactory.now)
    let thread = model(voice: voice, now: { clock.now })
    await thread.load()

    thread.beginVoice()
    clock.now = MemoFactory.now.addingTimeInterval(3)
    #expect(await thread.endVoice(cancelled: true) == nil)
    let created = await client.calls.contains { if case .createMemo = $0 { true } else { false } }
    #expect(!created)
    #expect(thread.voiceStartedAt == nil && thread.failure == nil)
  }

  @Test("a touch shorter than the minimum take is a cancel with a hint")
  func tooShortVoice() async {
    await client.seed(detail([memo("a", age: 100, reply: "x")]))
    let thread = model(voice: fakeVoice())
    await thread.load()

    thread.beginVoice()
    #expect(await thread.endVoice(cancelled: false) == nil)
    #expect(thread.failure != nil)
  }

  @Test("without capture the control is unavailable and a hold does nothing")
  func voiceUnavailable() async {
    let thread = model()
    #expect(!thread.canRecordVoice)
    thread.beginVoice()
    #expect(thread.voiceStartedAt == nil)
    #expect(await thread.endVoice(cancelled: false) == nil)
  }
}

/// A clock the test moves by hand.
private final class Clock {
  var now: Date
  init(_ now: Date) { self.now = now }
}
