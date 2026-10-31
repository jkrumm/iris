import Foundation
import Synchronization
import Testing

@testable import IrisCapture

/// The server the test "connection" points at; the outbox reads it through its `serverKey` provider.
final class TestServer: Sendable {
  private let key: Mutex<String?>

  init(_ key: String? = nil) { self.key = Mutex(key) }

  var current: String? { key.withLock { $0 } }
  func switchTo(_ key: String?) { self.key.withLock { $0 = key } }
}

/// Switches the connection from inside the first `create` and throws `WrongServerError`: the connection moved between the
/// dispatch and the request.
private actor SwitchingUploader: SegmentUploader {
  let base: TestUploader
  let server: TestServer
  private var switched = false

  init(base: TestUploader, server: TestServer) {
    self.base = base
    self.server = server
  }

  func create(_ item: OutboxItem) async throws {
    if !switched {
      switched = true
      server.switchTo("B")
      throw WrongServerError()
    }
    try await base.create(item)
  }

  func upload(_ segment: ClosedSegment) async throws { try await base.upload(segment) }
  func complete(memoID: MemoID, segmentCount: Int) async throws {
    try await base.complete(memoID: memoID, segmentCount: segmentCount)
  }
  func delete(memoID: MemoID) async throws { try await base.delete(memoID: memoID) }
}

/// Work stays bound to the server it was queued for: after a switch it waits in the queue, and goes out when that server is
/// configured again. Never to another server.
struct ServerBindingTests {
  private func harness(_ server: TestServer) async throws -> OutboxHarness {
    try await OutboxHarness(serverKey: { server.current })
  }

  /// Moves the clock past every backoff and lets the outbox act on it.
  private func tick(_ harness: OutboxHarness) async {
    await harness.clock.advance(by: 600)
    await harness.outbox.settled()
  }

  @Test func anItemIsBoundToTheServerConfiguredWhenItIsQueued() async throws {
    let server = TestServer("A")
    let harness = try await harness(server)
    await harness.uploader.failNextCreates(1)
    try await harness.outbox.enqueueItem(textItem(memo(1)))
    await harness.outbox.settled()

    server.switchTo("B")
    #expect(await harness.outbox.items().map(\.serverKey) == ["A"])
    #expect(await harness.store.load().items.map(\.serverKey) == ["A"], "the binding is saved with the queue")
    await harness.outbox.shutdown()
  }

  @Test func aTextItemQueuedForAIsNotSentToBAndGoesOutWhenAIsBack() async throws {
    let server = TestServer("A")
    let harness = try await harness(server)
    await harness.uploader.failNextCreates(1)
    try await harness.outbox.enqueueItem(textItem(memo(1)))
    await harness.outbox.settled()
    #expect(await harness.uploader.createAttempts == 1)

    server.switchTo("B")
    await tick(harness)
    await harness.outbox.retryBackedOff()
    await harness.outbox.settled()

    #expect(await harness.uploader.createAttempts == 1, "nothing of A's goes to B")
    #expect(await harness.outbox.queue().map(\.id) == [memo(1)], "and it stays in the queue, visible")

    server.switchTo("A")
    await harness.outbox.retryBackedOff()
    await harness.outbox.settled()

    #expect(await harness.uploader.created.map(\.memoID) == [memo(1)])
    #expect(await harness.outbox.queue().isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func theSegmentsAndTheCompleteOfATakeForAStayWithA() async throws {
    let server = TestServer("A")
    let harness = try await harness(server)
    let id = memo(1)
    await harness.uploader.failNext(1, for: SegmentKey(memoID: id, index: 0))
    try await harness.outbox.enqueueItem(voiceItem(id))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.finishMemo(id, segmentCount: 1)
    await harness.outbox.settled()
    #expect(await harness.uploader.created.map(\.memoID) == [id])

    server.switchTo("B")
    await tick(harness)
    await harness.outbox.retryBackedOff()
    await harness.outbox.settled()

    #expect(await harness.uploader.attempts[SegmentKey(memoID: id, index: 0)] == 1, "no segment goes to B")
    #expect(await harness.uploader.completed.isEmpty, "no complete goes to B")

    server.switchTo("A")
    await harness.outbox.retryBackedOff()
    await harness.outbox.settled()

    #expect(await harness.uploader.uploaded == [SegmentKey(memoID: id, index: 0)])
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 1)])
    await harness.outbox.shutdown()
  }

  @Test func aDeleteOfAMemoOnAIsNotSentToB() async throws {
    let server = TestServer("A")
    let harness = try await harness(server)
    let id = memo(1)
    try await harness.outbox.enqueueItem(voiceItem(id))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.settled()
    await harness.uploader.failNextDeletes(1)

    await harness.outbox.discard(id)
    await harness.outbox.settled()
    #expect(await harness.uploader.deleteAttempts == 1)
    #expect(await harness.store.load().deletions.map(\.serverKey) == ["A"])

    server.switchTo("B")
    await tick(harness)
    await harness.outbox.retryBackedOff()
    await harness.outbox.settled()
    #expect(await harness.uploader.deleteAttempts == 1, "B is never asked to delete A's memo")
    #expect(await harness.outbox.queue().map(\.isDeletion) == [true], "the pending delete stays visible")

    server.switchTo("A")
    await harness.outbox.retryBackedOff()
    await harness.outbox.settled()
    #expect(await harness.uploader.deleted == [id])
    #expect(await harness.outbox.queue().isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func theBindingSurvivesARelaunch() async throws {
    let server = TestServer("A")
    let first = try await harness(server)
    await first.uploader.failNextCreates(1)
    try await first.outbox.enqueueItem(textItem(memo(1)))
    await first.outbox.settled()
    let saved = await first.store.load()
    await first.outbox.shutdown()

    server.switchTo("B")
    let relaunched = try await OutboxHarness(record: saved, serverKey: { server.current })
    await relaunched.outbox.retryBackedOff()
    await relaunched.outbox.settled()
    #expect(await relaunched.uploader.createAttempts == 0, "after a relaunch on B, A's item still waits")

    server.switchTo("A")
    await relaunched.outbox.retryBackedOff()
    await relaunched.outbox.settled()
    #expect(await relaunched.uploader.created.map(\.memoID) == [memo(1)])
    await relaunched.outbox.shutdown()
  }

  @Test func anItemBoundToNoServerGoesToWhicheverIsConfigured() async throws {
    let server = TestServer(nil)
    let harness = try await harness(server)
    await harness.uploader.failNextCreates(1)
    try await harness.outbox.enqueueItem(textItem(memo(1)))
    await harness.outbox.settled()
    #expect(await harness.outbox.items().map(\.serverKey) == [nil])

    server.switchTo("B")
    await tick(harness)
    await harness.outbox.retryBackedOff()
    await harness.outbox.settled()
    #expect(await harness.uploader.created.map(\.memoID) == [memo(1)])
    await harness.outbox.shutdown()
  }

  @Test func aRecordWrittenBeforeTheBindingReadsAsUnbound() throws {
    let json = """
      {"memoID":"00000000-0000-0000-0000-000000000001","kind":{"voice":{}},"mode":"auto","startedAt":0,"queuedAt":0,\
      "title":"t","create":{"pending":{}},"attempts":0}
      """
    let item = try JSONDecoder().decode(OutboxItem.self, from: Data(json.utf8))
    #expect(item.serverKey == nil)
    let deletion = try JSONDecoder().decode(
      OutboxDeletion.self,
      from: Data(
        #"{"memoID":"00000000-0000-0000-0000-000000000001","state":{"pending":{}},"attempts":0}"#.utf8))
    #expect(deletion.serverKey == nil)
  }

  @Test func aTransferThatMeetsAnotherServerGoesBackAsItWasWithoutBackoffOrAttempt() async throws {
    let server = TestServer("A")
    let base = TestUploader()
    let clock = ManualClock()
    let outbox = try await Outbox(
      store: InMemoryOutboxStore(), uploader: SwitchingUploader(base: base, server: server), clock: clock,
      policy: OutboxPolicy(jitter: { 0 }), serverKey: { server.current })

    try await outbox.enqueueItem(textItem(memo(1)))
    await outbox.settled()

    let item = try #require(await outbox.items().first)
    #expect(item.create == .pending && item.attempts == 0, "not a failure: no attempt, no backoff")
    #expect(await outbox.queue().first?.status == .waiting)
    #expect(await base.createAttempts == 0)

    server.switchTo("A")
    await outbox.retryBackedOff()
    await outbox.settled()
    #expect(await base.created.map(\.memoID) == [memo(1)])
    await outbox.shutdown()
  }

  @Test func theStateMachineHandsOutNothingBoundToAnotherServer() {
    var machine = OutboxStateMachine()
    var bound = textItem(memo(1))
    bound.serverKey = "A"
    machine.enqueueItem(bound)
    machine.enqueueItem(textItem(memo(2)))

    #expect(machine.dispatch(now: Date(), inFlight: 0, serverKey: "B").map(\.memoIDForTest) == [memo(2)])
    #expect(machine.dispatch(now: Date(), inFlight: 0, serverKey: nil).isEmpty, "no connection holds bound work too")
    #expect(machine.dispatch(now: Date(), inFlight: 0, serverKey: "A").map(\.memoIDForTest) == [memo(1)])
  }
}

extension OutboxWork {
  fileprivate var memoIDForTest: MemoID {
    switch self {
    case .create(let item): item.memoID
    case .upload(let segment): segment.memoID
    case .complete(let id, _), .delete(let id): id
    }
  }
}
