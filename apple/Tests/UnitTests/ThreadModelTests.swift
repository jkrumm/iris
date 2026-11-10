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

  /// A memo of the thread `t`, or (`inThread: false`) one before `act`, which has no thread id yet.
  private func memo(
    _ id: String, age: TimeInterval, state: MemoState = .notified, reply: String? = nil, blocks: [ReplyBlock] = [],
    error: String? = nil, inThread: Bool = true
  ) -> Memo {
    let created = MemoFactory.now.addingTimeInterval(-age)
    return Memo(
      id: id, mode: .hermes, device: "iphone", startedAt: created, state: state, error: error,
      transcript: "question \(id)", replyText: reply, replyBlocks: blocks, threadId: inThread ? threadID : nil,
      isTyped: true, createdAt: created, updatedAt: created.addingTimeInterval(5))
  }

  private func detail(_ memos: [Memo]) -> ThreadDetail {
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
        id: threadID, kind: "hermes", title: "Title", createdAt: memos[0].createdAt, updatedAt: memos.last!.updatedAt,
        lastMemoId: memos.last?.id),
      memos: memos, messages: messages)
  }

  /// What the typed path was asked to send, and how it answers.
  final class Sends {
    var sent: [String] = []
    var result: TypedReplyResult = .queued

    func send(_ text: String, _ threadID: String) async -> TypedReplyResult {
      sent.append("\(threadID):\(text)")
      return result
    }
  }

  private func model(
    anchor: Memo, sends: Sends = Sends(), voice: any VoiceReplyCapture = UnavailableVoiceReplyCapture(),
    now: @escaping () -> Date = { MemoFactory.now },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) -> ThreadModel {
    ThreadModel(
      memo: anchor, client: client, voice: voice, sendText: { await sends.send($0, $1) }, now: now, sleep: sleep)
  }

  /// A thread whose first memo `a` the screen is opened on.
  private func openedOn(_ memos: [Memo], sends: Sends = Sends()) async -> ThreadModel {
    await client.seed(detail(memos))
    return model(anchor: memos[0], sends: sends)
  }

  // MARK: Turns

  @Test("the anchor's own turns are on screen before the thread loads, and the loaded thread takes over in place")
  func answeredTurns() async {
    let first = memo("a", age: 100, reply: "**Hi**")
    let thread = await openedOn([first])
    #expect(thread.title == first.rowHeadline)
    #expect(thread.turns.map(\.id) == ["a.user", "a.reply"])
    #expect(thread.turns[1].content == .assistant("**Hi**", mermaid: [:]))

    await thread.load()
    #expect(thread.title == "Title")
    #expect(thread.turns.map(\.id) == ["a.user", "a.reply"])
    #expect(thread.turns.allSatisfy { $0.memoID == "a" })
  }

  @Test(
    "a memo with a thread id loads its thread; one without refreshes the memo first and loads the thread once it has one"
  )
  func loadsTheThread() async {
    let first = memo("a", age: 100, reply: "x")
    let thread = await openedOn([first])
    await thread.load()
    #expect(await client.calls.contains(.thread(id: threadID)))
    #expect(await !client.calls.contains(.memo(id: "a")))

    let preAct = memo("p", age: 10, state: .transcribed, inThread: false)
    await client.seed(MemoDetail(memo: preAct, steps: []))
    let waiting = model(anchor: preAct)
    await waiting.load()
    #expect(await client.calls.contains(.memo(id: "p")))
    #expect(waiting.threadID == nil && waiting.detail == nil)
    #expect(waiting.turns.map(\.id) == ["p.user", "p.pending"])

    await client.seed(MemoDetail(memo: memo("p", age: 10, state: .notified, reply: "done"), steps: []))
    await client.seed(detail([memo("p", age: 10, state: .notified, reply: "done")]))
    await waiting.load()
    #expect(waiting.threadID == threadID && waiting.detail != nil)
    #expect(waiting.turns.map(\.id) == ["p.user", "p.reply"])
  }

  @Test("a memo still in the pipeline is a question with a pending answer that carries its progress")
  func pendingTurn() async {
    let thread = await openedOn([memo("a", age: 100, reply: "done"), memo("b", age: 10, state: .routed)])
    await thread.load()

    #expect(thread.turns.map(\.id) == ["a.user", "a.reply", "b.user", "b.pending"])
    guard case .pending(let progress, let caption) = thread.turns[3].content else {
      Issue.record("expected a pending turn")
      return
    }
    #expect(progress == StepProgress(completed: 1, total: 3))
    #expect(!caption.isEmpty)
  }

  @Test("when the reply lands the pending turn becomes the answer")
  func reveal() async {
    let thread = await openedOn([memo("a", age: 10, state: .routed)])
    await thread.load()
    #expect(thread.turns.map(\.id) == ["a.user", "a.pending"])

    await client.seed(detail([memo("a", age: 10, state: .acted, reply: "the answer")]))
    await thread.load()
    #expect(thread.turns.map(\.id) == ["a.user", "a.reply"])
    #expect(thread.turns[1].content == .assistant("the answer", mermaid: [:]))
  }

  @Test("a failed memo is a failed turn with the server's words")
  func failedTurn() async {
    let thread = await openedOn([memo("a", age: 10, state: .failed, error: "act failed: 503")])
    await thread.load()
    #expect(thread.turns.last?.content == .failed("act failed: 503"))
  }

  @Test("an answer carries the memo's Mermaid PNGs by fence index, as the memo's own assets")
  func mermaidAssets() async {
    let block = ReplyBlock(
      index: 1, width: 320, height: 140, svg: SchemeAssets(light: "s-l", dark: "s-d"),
      png: SchemeAssets(light: "p-l", dark: "p-d"))
    let thread = await openedOn([memo("a", age: 10, reply: "x", blocks: [block])])
    await thread.load()

    let expected = MermaidAsset(
      light: ReplyAssetRef(memoID: "a", assetID: "p-l"), dark: ReplyAssetRef(memoID: "a", assetID: "p-d"),
      width: 320, height: 140)
    #expect(thread.turns.last?.content == .assistant("x", mermaid: [1: expected]))
  }

  // MARK: Live

  private func delta(_ seq: Int, _ text: String, attempt: Int = 1, id: String = "a") -> ServerEvent {
    .memoDelta(MemoDelta(id: id, attempt: attempt, seq: seq, text: text))
  }

  private func activity(_ tool: String, attempt: Int = 1, id: String = "a") -> ServerEvent {
    .memoActivity(MemoActivity(id: id, attempt: attempt, tool: tool))
  }

  private func working(_ thread: ThreadModel) -> [String]? {
    guard case .working(let lines)? = thread.turns.last?.content else { return nil }
    return lines.map(\.label)
  }

  @Test("the tools and the streamed reply of a running memo show live, and the final reply replaces them in place")
  func liveTurn() async {
    let running = memo("a", age: 10, state: .transcribed)
    let thread = await openedOn([running])
    await client.seed(MemoDetail(memo: running, steps: []))
    await thread.load()
    guard case .pending = thread.turns.last?.content else {
      Issue.record("expected the dashes")
      return
    }

    await thread.apply(activity("terminal"))
    #expect(working(thread) == [ToolActivityText.label(for: "terminal")])
    #expect(thread.turns.last?.id == "a.pending")
    await thread.apply(activity("web"))
    #expect(working(thread)?.count == 2)

    await thread.apply(delta(1, "Hello"))
    #expect(thread.turns.last?.id == "a.reply")
    #expect(
      thread.turns.last?.content == .streaming(markdown: "Hello", activity: ToolActivityText.label(for: "web")))
    await thread.apply(delta(2, " world"))
    #expect(
      thread.turns.last?.content == .streaming(markdown: "Hello world", activity: ToolActivityText.label(for: "web")))
    await thread.apply(delta(2, " world"))
    guard case .streaming(let text, _)? = thread.turns.last?.content else {
      Issue.record("expected a streaming turn")
      return
    }
    #expect(text == "Hello world")

    // A new attempt starts over: the tool list again.
    await thread.apply(activity("terminal", attempt: 2))
    #expect(working(thread) == [ToolActivityText.label(for: "terminal")])

    // The reply lands: the same id, now the answer.
    await thread.apply(delta(1, "Hello", attempt: 2))
    let done = memo("a", age: 10, state: .acted, reply: "Hello world")
    await client.seed(detail([done]))
    await client.seed(MemoDetail(memo: done, steps: []))
    await thread.load()
    #expect(thread.turns.map(\.id) == ["a.user", "a.reply"])
    #expect(thread.turns.last?.content == .assistant("Hello world", mermaid: [:]))
  }

  @Test("events of a memo outside the conversation are ignored")
  func foreignEvents() async {
    let running = memo("a", age: 10, state: .transcribed)
    let thread = await openedOn([running])
    await thread.load()
    await thread.apply(activity("terminal", id: "other"))
    await thread.apply(delta(1, "x", id: "other"))
    guard case .pending = thread.turns.last?.content else {
      Issue.record("expected the dashes")
      return
    }
  }

  @Test("a screen that opens mid-turn shows the memo's partial reply, and the deltas that follow append")
  func openedMidTurn() async {
    let running = memo("a", age: 10, state: .transcribed)
    let thread = await openedOn([running])
    await client.seed(
      MemoDetail(memo: running, steps: [], partialReply: PartialReply(attempt: 3, seq: 4, text: "So far")))
    await thread.load()
    #expect(thread.turns.last?.content == .streaming(markdown: "So far", activity: nil))

    await thread.apply(delta(4, "old", attempt: 3))
    await thread.apply(delta(5, " more", attempt: 3))
    #expect(thread.turns.last?.content == .streaming(markdown: "So far more", activity: nil))
  }

  @Test("a delta that skips ahead stays hidden until the partial reply is fetched again")
  func gapHidesUntilSeeded() async {
    let running = memo("a", age: 10, state: .transcribed)
    let thread = await openedOn([running])
    await client.seed(MemoDetail(memo: running, steps: []))
    await thread.load()
    await thread.apply(delta(5, "tail"))
    guard case .pending = thread.turns.last?.content else {
      Issue.record("a gap must not show text")
      return
    }
    await client.seed(
      MemoDetail(memo: running, steps: [], partialReply: PartialReply(attempt: 1, seq: 6, text: "whole base")))
    await thread.apply(.ready)
    #expect(thread.turns.last?.content == .streaming(markdown: "whole base", activity: nil))
  }

  @Test("ready forgets the live turns and fetches the partial reply again")
  func readyResets() async {
    let running = memo("a", age: 10, state: .transcribed)
    let thread = await openedOn([running])
    await client.seed(MemoDetail(memo: running, steps: []))
    await thread.load()
    await thread.apply(activity("terminal"))
    #expect(working(thread) != nil)

    await thread.apply(.ready)
    guard case .pending = thread.turns.last?.content else {
      Issue.record("expected the dashes after a reconnect")
      return
    }
    await client.seed(
      MemoDetail(memo: running, steps: [], partialReply: PartialReply(attempt: 1, seq: 2, text: "Again")))
    await thread.apply(.ready)
    #expect(thread.turns.last?.content == .streaming(markdown: "Again", activity: nil))
    let fetches = await client.calls.count { $0 == .memo(id: "a") }
    #expect(fetches >= 3)
  }

  // MARK: Loading

  @Test("a failed thread load keeps the anchor's turns; only an empty screen is flagged")
  func failedLoad() async {
    let first = memo("a", age: 10, reply: "x")
    let thread = await openedOn([first])
    await client.enqueueFailure(.unexpectedStatus(500), for: .thread)
    await thread.load()
    #expect(!thread.loadFailed && thread.detail == nil && thread.turns.count == 2)

    var silent = memo("s", age: 10, state: .notified)
    silent.transcript = nil
    let empty = model(anchor: silent)
    await client.enqueueFailure(.unexpectedStatus(500), for: .thread)
    await empty.load()
    #expect(empty.loadFailed && empty.turns.isEmpty)
    await client.seed(detail([silent]))
    await empty.load()
    #expect(!empty.loadFailed && empty.detail != nil)
  }

  @Test("a memo sent from this screen shows at once as a question with its pending answer, once")
  func didSend() async {
    let thread = await openedOn([memo("a", age: 100, reply: "x")])
    await thread.load()
    let sent = memo("b", age: 1, state: .transcribed)
    thread.didSend(sent)
    thread.didSend(sent)
    #expect(thread.turns.map(\.id) == ["a.user", "a.reply", "b.user", "b.pending"])
    #expect(thread.memoIDs == ["a", "b"])
  }

  @Test("a fetch that was in flight when a memo was sent does not drop that memo when it lands")
  func staleLoad() async {
    let thread = await openedOn([memo("a", age: 100, reply: "x")])
    await thread.load()

    let gate = await client.hold(.thread)
    let loading = Task { await thread.load() }
    #expect(await waitUntilHeld(gate))
    thread.didSend(memo("b", age: 1, state: .transcribed))
    await gate.release()
    await loading.value

    #expect(thread.memoIDs == ["a", "b"])
  }

  // MARK: Typed reply

  @Test(
    "who can type: a conversation with a thread, or a first memo still on its way; not a deleted or an ended one without a thread"
  )
  func canType() {
    #expect(model(anchor: memo("a", age: 10)).canType)
    #expect(model(anchor: memo("b", age: 10, state: .received, inThread: false)).canType)
    #expect(!model(anchor: memo("c", age: 10, state: .failed, error: "x", inThread: false)).canType)
    var gone = memo("d", age: 10)
    gone.deletedAt = MemoFactory.now
    #expect(!model(anchor: gone).canType)
  }

  @Test("a typed reply goes into the thread and appears in place with its pending answer; History is told")
  func typedSendInPlace() async {
    let sends = Sends()
    let thread = await openedOn([memo("a", age: 100, reply: "x")], sends: sends)
    await thread.load()
    var told: [String] = []
    thread.onSent = { told.append($0.id) }
    sends.result = .sent(memo("b", age: 1, state: .transcribed))

    thread.replyBar.draft = "  and then?  "
    await thread.sendDraft()

    #expect(sends.sent == ["t:and then?"])
    #expect(thread.replyBar.draft.isEmpty)
    #expect(thread.turns.map(\.id) == ["a.user", "a.reply", "b.user", "b.pending"])
    #expect(told == ["b"])
  }

  @Test("a queued reply says so; a reply that could not go out comes back into the field with a toast")
  func queuedAndFailed() async {
    let sends = Sends()
    let thread = await openedOn([memo("a", age: 100, reply: "x")], sends: sends)
    await thread.load()

    sends.result = .queued
    thread.replyBar.draft = "one"
    await thread.sendDraft()
    #expect(thread.failure != nil && thread.replyBar.draft.isEmpty)
    thread.dismissFailure()

    sends.result = .failed
    thread.replyBar.draft = "two"
    await thread.sendDraft()
    #expect(thread.replyBar.draft == "two" && thread.failure != nil)
  }

  @Test("a blank draft sends nothing")
  func blankDraft() async {
    let sends = Sends()
    let thread = await openedOn([memo("a", age: 100, reply: "x")], sends: sends)
    thread.replyBar.draft = "   "
    await thread.sendDraft()
    #expect(sends.sent.isEmpty)
  }

  // MARK: Held reply

  private func preAct(_ state: MemoState = .transcribed, error: String? = nil) async -> Memo {
    let anchor = memo("p", age: 10, state: state, error: error, inThread: false)
    await client.seed(MemoDetail(memo: anchor, steps: []))
    return anchor
  }

  @Test("before act a reply is held on the device, shown as a turn that waits, and sent once the memo has a thread")
  func heldThenSent() async {
    let sends = Sends()
    let anchor = await preAct()
    let thread = model(anchor: anchor, sends: sends)
    await thread.load()

    thread.replyBar.draft = "hello"
    await thread.sendDraft()
    #expect(sends.sent.isEmpty && thread.replyBar.draft.isEmpty)
    #expect(thread.turns.suffix(2).map(\.id) == ["held.user", "held.pending"])
    #expect(thread.turns.suffix(2).allSatisfy { $0.memoID == nil })
    #expect(thread.turns.suffix(2).first?.content == .user("hello"))

    // A second reply while one is held joins it.
    thread.replyBar.draft = "again"
    await thread.sendDraft()
    #expect(thread.turns.filter { $0.id == "held.user" }.map(\.content) == [.user("hello\nagain")])

    let acted = memo("p", age: 10, state: .notified, reply: "done")
    await client.seed(MemoDetail(memo: acted, steps: []))
    await client.seed(detail([acted]))
    sends.result = .sent(memo("q", age: 1, state: .transcribed))
    await thread.load()

    #expect(sends.sent == ["t:hello\nagain"])
    #expect(thread.turns.map(\.id) == ["p.user", "p.reply", "q.user", "q.pending"])
    #expect(thread.failure == nil)
  }

  @Test("a first memo that ends without a thread gives the held reply back with a toast")
  func heldRestored() async {
    let sends = Sends()
    let anchor = await preAct()
    let thread = model(anchor: anchor, sends: sends)
    thread.replyBar.draft = "hello"
    await thread.sendDraft()
    #expect(thread.turns.contains { $0.id == "held.user" })

    await client.seed(
      MemoDetail(memo: memo("p", age: 10, state: .failed, error: "act failed", inThread: false), steps: []))
    await thread.load()

    #expect(sends.sent.isEmpty)
    #expect(thread.replyBar.draft == "hello")
    #expect(!thread.turns.contains { $0.id.hasPrefix("held.") })
    #expect(thread.failure != nil)
    #expect(!thread.canType)
  }

  // MARK: Voice

  /// The real voice capture over the fake stack: a take is a fake recorder, the outbox and the fake API.
  private func fakeVoice(seconds: Double = 3) -> OutboxVoiceReplyCapture {
    OutboxRig(client: client).voice(seconds: seconds)
  }

  @Test("voice waits for a thread id: the control is off and a hold does nothing before act")
  func voiceNeedsAThread() async {
    let anchor = await preAct()
    let thread = model(anchor: anchor, voice: fakeVoice())
    #expect(!thread.canRecordVoice)
    thread.beginVoice()
    #expect(thread.replyBar.voiceStartedAt == nil)

    let withThread = model(anchor: memo("a", age: 10, reply: "x"), voice: fakeVoice())
    #expect(withThread.canRecordVoice)
  }

  @Test("without capture the control is unavailable")
  func voiceUnavailable() {
    let thread = model(anchor: memo("a", age: 10, reply: "x"))
    #expect(!thread.canRecordVoice)
  }

  @Test("a voice reply from the first turn is bound to the thread; the take becomes a memo that joins it and History")
  func voiceReply() async throws {
    let first = memo("a", age: 100, reply: "x")
    await client.seed(detail([first]))
    let voice = fakeVoice()
    let clock = Clock(MemoFactory.now)
    let thread = model(anchor: first, voice: voice, now: { clock.now })
    var told: [String] = []
    thread.onSent = { told.append($0.id) }
    await thread.load()

    thread.beginVoice()
    #expect(thread.replyBar.voiceStartedAt == MemoFactory.now)
    clock.now = MemoFactory.now.addingTimeInterval(3)
    await thread.endVoice(cancelled: false)

    #expect(voice.requests == [VoiceReplyRequest(threadId: threadID, mode: .hermes)])
    let sent = try #require(thread.detail?.memos.last)
    #expect(sent.id != "a" && sent.threadId == threadID && sent.mode == .hermes)
    #expect(told == [sent.id])
    #expect(thread.replyBar.voiceStartedAt == nil)
    #expect(thread.turns.last?.memoID == sent.id)
  }

  // MARK: Toast

  @Test("every notice of the reply bar becomes a toast in its own words")
  func noticesBecomeToasts() {
    let thread = model(anchor: memo("a", age: 10, reply: "x"))
    let notices: [ReplyBarModel.Notice] = [.couldNotStartRecording, .tooShort, .recordingFailed, .voiceFailed, .queued]
    var messages: [String] = []
    for notice in notices {
      thread.replyBar.onNotice(notice)
      messages.append(thread.failure?.message ?? "")
    }
    #expect(messages.allSatisfy { !$0.isEmpty })
    #expect(Set(messages).count == notices.count)
  }

  @Test("a newer toast is not hidden by the timer of the toast it replaced, even with the same words")
  func newerToastKeepsItsOwnTimer() async {
    let timers = ToastTimers()
    let thread = model(anchor: memo("a", age: 10, reply: "x"), sleep: { try await timers.sleep($0) })

    thread.replyBar.onNotice(.tooShort)
    let first = thread.failure
    thread.replyBar.onNotice(.tooShort)
    let second = thread.failure
    #expect(first != nil && second != nil && first?.message == second?.message && first?.id != second?.id)
    await timers.waitForSleeps(2)

    timers.fire(0)
    await timers.settle()
    #expect(thread.failure == second, "the first toast's timer was cancelled with the toast")

    timers.fire(1)
    #expect(await timers.until { thread.failure == nil })
  }

  @Test("dismissing a toast cancels its timer, so it cannot hide the next one")
  func dismissCancelsTheTimer() async {
    let timers = ToastTimers()
    let thread = model(anchor: memo("a", age: 10, reply: "x"), sleep: { try await timers.sleep($0) })

    thread.replyBar.onNotice(.tooShort)
    await timers.waitForSleeps(1)
    thread.dismissFailure()
    #expect(thread.failure == nil)

    thread.replyBar.onNotice(.tooShort)
    let next = thread.failure
    await timers.waitForSleeps(2)
    timers.fire(0)
    await timers.settle()
    #expect(thread.failure == next)

    timers.fire(1)
    #expect(await timers.until { thread.failure == nil })
  }
}

/// A clock the test moves by hand.
private final class Clock {
  var now: Date
  init(_ now: Date) { self.now = now }
}
