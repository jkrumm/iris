import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("HeldReplyQueue")
struct HeldReplyQueueTests {
  let client = FakeAPIClient(now: { MemoFactory.now })
  let timers = ToastTimers()
  let sends = Sends()
  let sent = SentMemos()

  /// What the typed path was asked to send, and how it answers.
  final class Sends {
    var sent: [String] = []
    var result: TypedReplyResult = .queued

    func send(_ text: String, _ threadID: String) async -> TypedReplyResult {
      sent.append("\(threadID):\(text)")
      return result
    }
  }

  final class SentMemos {
    var ids: [String] = []
  }

  private func queue() -> HeldReplyQueue {
    let queue = HeldReplyQueue(
      client: client, sendText: { [sends] in await sends.send($0, $1) },
      sleep: { [timers] in try await timers.sleep($0) })
    queue.onSent = { [sent] in sent.ids.append($0.id) }
    return queue
  }

  /// The first memo before `act`: no thread yet.
  private func preAct() async -> Memo {
    let anchor = MemoFactory.memo("p", state: .transcribed, typed: true)
    await client.seed(MemoDetail(memo: anchor, steps: []))
    return anchor
  }

  private func memoPolls() async -> Int {
    await client.calls.filter { $0 == .memo(id: "p") }.count
  }

  /// Waits until the follower has asked the server for the memo `count` times.
  private func waitForPolls(_ count: Int) async {
    for _ in 0..<5_000 {
      if await memoPolls() >= count { break }
      await Task.yield()
    }
    await timers.settle()
  }

  @Test("a handed-over reply is sent once, as soon as the memo has a thread, and told to History")
  func sentWhenTheThreadAppears() async {
    let queue = queue()
    let anchor = await preAct()
    sends.result = .sent(MemoFactory.memo("q", state: .transcribed, typed: true, threadId: "t"))

    queue.hand("hello", anchor: anchor)
    await timers.waitForSleeps(1)
    timers.fire(0)
    await waitForPolls(1)
    #expect(sends.sent.isEmpty, "the memo has no thread yet, so the follower keeps polling")

    await client.seed(MemoDetail(memo: MemoFactory.memo("p", state: .notified, typed: true, threadId: "t"), steps: []))
    await timers.waitForSleeps(2)
    timers.fire(1)
    #expect(await timers.until { !sends.sent.isEmpty })
    await timers.settle()

    #expect(sends.sent == ["t:hello"])
    #expect(sent.ids == ["q"])
    #expect(queue.reclaim(anchorID: "p") == nil)
  }

  @Test("the poll backs off from two seconds, doubling to thirty")
  func backoff() async {
    let queue = queue()
    queue.hand("hello", anchor: await preAct())
    for index in 0..<7 {
      await timers.waitForSleeps(index + 1)
      timers.fire(index)
    }
    await timers.waitForSleeps(8)
    let seconds: [Int64] = [2, 4, 8, 16, 30, 30, 30]
    #expect(Array(timers.durations.prefix(7)) == seconds.map { Duration.seconds($0) })
    _ = queue.reclaim(anchorID: "p")
  }

  @Test("reclaim returns the reply as held and stops the follower")
  func reclaimStopsTheFollower() async {
    let queue = queue()
    queue.hand("hello", anchor: await preAct())
    await timers.waitForSleeps(1)

    #expect(queue.reclaim(anchorID: "p") == .held("hello"))
    #expect(queue.reclaim(anchorID: "p") == nil)

    await client.seed(MemoDetail(memo: MemoFactory.memo("p", state: .notified, typed: true, threadId: "t"), steps: []))
    timers.fire(0)
    await timers.settle()
    #expect(await memoPolls() == 0)
    #expect(sends.sent.isEmpty)
  }

  @Test("a first memo that fails before act turns the reply into a draft, restored with a toast")
  func failedAnchorBecomesDraft() async {
    let queue = queue()
    let anchor = await preAct()
    queue.hand("hello", anchor: anchor)
    await timers.waitForSleeps(1)

    await client.seed(MemoDetail(memo: MemoFactory.memo("p", state: .failed, error: "boom", typed: true), steps: []))
    timers.fire(0)
    await waitForPolls(1)

    #expect(sends.sent.isEmpty)
    let thread = ThreadModel(
      memo: anchor, client: client, voice: UnavailableVoiceReplyCapture(),
      sendText: { [sends] in await sends.send($0, $1) }, now: { MemoFactory.now }, heldReplies: queue)
    #expect(thread.replyBar.draft == "hello")
    #expect(thread.failure != nil)
    #expect(!thread.turns.contains { $0.id.hasPrefix("held.") })
    #expect(queue.reclaim(anchorID: "p") == nil)
  }

  @Test("a send that fails leaves the reply as a draft")
  func failedSendBecomesDraft() async {
    let queue = queue()
    sends.result = .failed
    await client.seed(MemoDetail(memo: MemoFactory.memo("p", state: .notified, typed: true, threadId: "t"), steps: []))
    queue.hand("hello", anchor: MemoFactory.memo("p", state: .transcribed, typed: true))
    await timers.waitForSleeps(1)
    timers.fire(0)
    #expect(await timers.until { !sends.sent.isEmpty })
    await timers.settle()

    #expect(sent.ids.isEmpty)
    #expect(queue.reclaim(anchorID: "p") == .draft("hello"))
  }

  @Test("a screen that closes with a held reply hands it over, and the next screen of the memo gets it back held")
  func modelHandsOverAndReclaims() async {
    let queue = queue()
    let anchor = await preAct()
    let first = ThreadModel(
      memo: anchor, client: client, voice: UnavailableVoiceReplyCapture(),
      sendText: { [sends] in await sends.send($0, $1) }, now: { MemoFactory.now }, heldReplies: queue)
    first.replyBar.draft = "hello"
    await first.sendDraft()
    #expect(first.turns.contains { $0.id == "held.user" })

    first.handOver()
    #expect(!first.turns.contains { $0.id.hasPrefix("held.") })
    await timers.waitForSleeps(1)

    let second = ThreadModel(
      memo: anchor, client: client, voice: UnavailableVoiceReplyCapture(),
      sendText: { [sends] in await sends.send($0, $1) }, now: { MemoFactory.now }, heldReplies: queue)
    #expect(second.turns.suffix(2).map(\.id) == ["held.user", "held.pending"])
    #expect(second.failure == nil)
  }
}
