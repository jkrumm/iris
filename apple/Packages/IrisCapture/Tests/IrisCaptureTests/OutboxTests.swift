import Foundation
import Testing

@testable import IrisCapture

struct OutboxTests {
  private func key(_ memoID: MemoID, _ index: Int) -> SegmentKey {
    SegmentKey(memoID: memoID, index: index)
  }

  private func states(_ outbox: Outbox) async -> [OutboxState] {
    await outbox.entries().map(\.state)
  }

  @Test func happyPathUploadsEverySegmentThenCompletes() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    for index in 0..<3 { await harness.outbox.enqueue(segment(id, index)) }
    await harness.outbox.finishMemo(id, segmentCount: 3)
    await harness.outbox.settled()

    #expect(await harness.uploader.uploaded.count == 3)
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 3)])
    // Everything for the memo is forgotten once the server has it.
    #expect(await harness.outbox.entries().isEmpty)
    #expect(await harness.outbox.memos().isEmpty)
    #expect(await harness.store.load().entries.isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func segmentsUploadDuringTheTakeBeforeTheMemoIsFinished() async throws {
    let harness = try await OutboxHarness()
    await harness.outbox.enqueue(segment(memo(1), 0))
    await harness.outbox.settled()

    #expect(await harness.uploader.uploaded == [key(memo(1), 0)])
    #expect(await harness.uploader.completed.isEmpty)
    #expect(await states(harness.outbox) == [.uploaded])
    await harness.outbox.shutdown()
  }

  @Test func enqueueIsIdempotent() async throws {
    let harness = try await OutboxHarness()
    let first = segment(memo(1), 0)
    await harness.outbox.enqueue(first)
    await harness.outbox.enqueue(first)
    await harness.outbox.settled()
    await harness.outbox.enqueue(first)  // after it was uploaded
    await harness.outbox.settled()

    #expect(await harness.uploader.attempts[key(memo(1), 0)] == 1)
    #expect(await harness.outbox.entries().count == 1)
    await harness.outbox.shutdown()
  }

  @Test func retriesWithExponentialBackoffOnAManualClock() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    let start = await harness.clock.now()
    await harness.uploader.failNext(2, for: key(id, 0))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.settled()

    // First failure: retry after 2 s.
    #expect(await states(harness.outbox) == [.failed(retryAt: start.addingTimeInterval(2))])
    await harness.clock.advance(by: 1)
    await harness.outbox.settled()
    #expect(await harness.uploader.attempts[key(id, 0)] == 1)

    // The retry timer fires by itself once the clock reaches the deadline.
    await harness.clock.advance(by: 1)
    await harness.uploader.waitUntilAttempts(2, for: key(id, 0))
    await harness.outbox.settled()
    // Second failure: 4 s after the second attempt (t = start + 2).
    #expect(await states(harness.outbox) == [.failed(retryAt: start.addingTimeInterval(2 + 4))])

    await harness.clock.advance(by: 4)
    await harness.outbox.settled()
    #expect(await harness.uploader.attempts[key(id, 0)] == 3)
    #expect(await states(harness.outbox) == [.uploaded])
    #expect(await harness.outbox.entries().first?.attempts == 2)
    await harness.outbox.shutdown()
  }

  @Test func completeIsGatedOnEverySegmentBeingUploaded() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    await harness.uploader.failNext(1, for: key(id, 1))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.enqueue(segment(id, 1))
    await harness.outbox.finishMemo(id, segmentCount: 2)
    await harness.outbox.settled()

    #expect(await harness.uploader.completed.isEmpty)
    #expect(
      await states(harness.outbox) == [.uploaded, .failed(retryAt: await harness.clock.now().addingTimeInterval(2))])

    await harness.clock.advance(by: 2)
    await harness.outbox.settled()
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 2)])
    #expect(await harness.uploader.log == ["upload", "upload", "complete"])
    await harness.outbox.shutdown()
  }

  @Test func completeWaitsForSegmentsThatArriveAfterTheMemoIsFinished() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.finishMemo(id, segmentCount: 2)
    await harness.outbox.settled()
    #expect(await harness.uploader.completed.isEmpty)

    await harness.outbox.enqueue(segment(id, 1))
    await harness.outbox.settled()
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 2)])
    await harness.outbox.shutdown()
  }

  @Test func aFailedCompleteIsRetriedWithBackoff() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    await harness.uploader.failNextCompletes(1)
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.finishMemo(id, segmentCount: 1)
    await harness.outbox.settled()
    #expect(await harness.uploader.completed.isEmpty)
    #expect(await harness.outbox.memos().count == 1)

    await harness.clock.advance(by: 2)
    await harness.outbox.settled()
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 1)])
    #expect(await harness.outbox.memos().isEmpty)
    await harness.outbox.shutdown()
  }

  @Test(arguments: [1, 2, 3])
  func neverRunsMoreThanTheConcurrencyCap(cap: Int) async throws {
    let harness = try await OutboxHarness(policy: OutboxPolicy(maxConcurrentUploads: cap, jitter: { 0 }))
    let id = memo(1)
    await harness.uploader.hold()
    for index in 0..<5 { await harness.outbox.enqueue(segment(id, index)) }
    await harness.uploader.waitUntilStarted(cap)

    // The state machine marks work in flight synchronously, so this is exact.
    let uploading = await states(harness.outbox).filter { $0 == .uploading }.count
    #expect(uploading == cap)

    await harness.uploader.releaseAll()
    await harness.outbox.settled()
    // Held uploads released later never ran more than `cap` at once either.
    while await harness.uploader.uploaded.count < 5 {
      await harness.uploader.releaseAll()
      await harness.outbox.settled()
    }
    #expect(await harness.uploader.maxInFlight <= cap)
    #expect(await harness.uploader.uploaded.count == 5)
    await harness.outbox.shutdown()
  }

  @Test func relaunchRecoversUploadingEntriesAndFinishesTheMemo() async throws {
    let first = try await OutboxHarness()
    let id = memo(1)
    await first.uploader.hold()
    for index in 0..<3 { await first.outbox.enqueue(segment(id, index)) }
    await first.outbox.finishMemo(id, segmentCount: 3)
    await first.uploader.waitUntilStarted(2)
    await first.outbox.flush()

    // "Crash": take what is on disk while two uploads are in flight, then start over from it.
    let onDisk = await first.store.load()
    #expect(onDisk.entries.map(\.state).filter { $0 == .uploading }.count == 2)
    await first.outbox.shutdown()
    await first.uploader.releaseAll()

    let second = try await OutboxHarness(record: onDisk)
    #expect(await states(second.outbox) == [.pending, .pending, .pending])
    await second.outbox.resume()
    await second.outbox.settled()
    #expect(await second.uploader.uploaded.count == 3)
    #expect(await second.uploader.completed == [.init(memoID: id, segmentCount: 3)])
    await second.outbox.shutdown()
  }

  @Test func relaunchKeepsRetryStateAndHonoursTheDeadline() async throws {
    let first = try await OutboxHarness()
    let id = memo(1)
    let start = await first.clock.now()
    await first.uploader.failNext(1, for: key(id, 0))
    await first.outbox.enqueue(segment(id, 0))
    await first.outbox.settled()
    let onDisk = await first.store.load()
    await first.outbox.shutdown()
    #expect(onDisk.entries.first?.state == .failed(retryAt: start.addingTimeInterval(2)))

    let second = try await OutboxHarness(record: onDisk, clock: ManualClock(start: start.addingTimeInterval(1)))
    await second.outbox.settled()
    #expect(await second.uploader.attempts.isEmpty)  // still backing off after the relaunch

    await second.clock.advance(by: 1)
    await second.outbox.settled()
    #expect(await second.uploader.uploaded == [key(id, 0)])
    await second.outbox.shutdown()
  }

  @Test func relaunchedOutboxIgnoresReEnqueuedSegments() async throws {
    let first = try await OutboxHarness()
    await first.outbox.enqueue(segment(memo(1), 0))
    await first.outbox.settled()
    let onDisk = await first.store.load()
    await first.outbox.shutdown()

    let second = try await OutboxHarness(record: onDisk)
    await second.outbox.enqueue(segment(memo(1), 0))
    await second.outbox.settled()
    #expect(await second.uploader.attempts.isEmpty)
    await second.outbox.shutdown()
  }

  @Test func jsonFileStoreRoundTripsAndStartsEmpty() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONFileOutboxStore(fileURL: directory.appending(path: "nested/outbox.json"))
    #expect(try await store.load() == OutboxRecord())

    var machine = OutboxStateMachine()
    machine.enqueue(segment(memo(1), 0))
    machine.finishMemo(memo(1), segmentCount: 1)
    try await store.save(machine.record)
    #expect(try await store.load() == machine.record)
  }

  @Test func repeatedFinishMemoAfterCompletionDoesNotResurrectTheMemo() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.finishMemo(id, segmentCount: 1)
    await harness.outbox.settled()
    #expect(await harness.uploader.completed.count == 1)

    await harness.outbox.finishMemo(id, segmentCount: 1)
    await harness.outbox.enqueue(segment(id, 0))  // late duplicate from the recorder
    await harness.outbox.settled()

    #expect(await harness.outbox.memos().isEmpty)
    #expect(await harness.outbox.entries().isEmpty)
    #expect(await harness.uploader.completed.count == 1)
    #expect(await harness.uploader.attempts[key(id, 0)] == 1)
    await harness.outbox.shutdown()
  }

  @Test func repeatedFinishMemoAfterARelaunchIsStillANoOp() async throws {
    let first = try await OutboxHarness()
    let id = memo(1)
    await first.outbox.enqueue(segment(id, 0))
    await first.outbox.finishMemo(id, segmentCount: 1)
    await first.outbox.settled()
    let onDisk = await first.store.load()
    await first.outbox.shutdown()
    #expect(onDisk.completedMemos == [id])

    let second = try await OutboxHarness(record: onDisk)
    await second.outbox.finishMemo(id, segmentCount: 1)
    await second.outbox.enqueue(segment(id, 0))
    await second.outbox.settled()
    #expect(await second.outbox.memos().isEmpty)
    #expect(await second.outbox.entries().isEmpty)
    #expect(await second.uploader.attempts.isEmpty)
    #expect(await second.uploader.completed.isEmpty)
    await second.outbox.shutdown()
  }
}
