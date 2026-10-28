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

struct OutboxItemTests {
  @Test func aTextItemIsCreatedOnceAndLeavesTheQueue() async throws {
    let harness = try await OutboxHarness()
    #expect(await harness.outbox.enqueueItem(textItem(memo(1), text: "order a router")))
    await harness.outbox.settled()

    #expect(await harness.uploader.created.map(\.memoID) == [memo(1)])
    #expect(await harness.outbox.queue().isEmpty)
    #expect(await harness.store.load().items.isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func theSameItemTwiceIsOneCreate() async throws {
    let harness = try await OutboxHarness()
    #expect(await harness.outbox.enqueueItem(textItem(memo(1))))
    await harness.outbox.settled()
    #expect(await !harness.outbox.enqueueItem(textItem(memo(1))))
    await harness.outbox.settled()
    #expect(await harness.uploader.createAttempts == 1)
    await harness.outbox.shutdown()
  }

  @Test func offlineQueuesTheItemAndTheRetryTimerSendsItWhenTheClockArrives() async throws {
    let harness = try await OutboxHarness()
    await harness.uploader.failNextCreates(1)
    await harness.outbox.enqueueItem(textItem(memo(1)))
    await harness.outbox.settled()

    let queued = await harness.outbox.queue()
    #expect(queued.count == 1)
    if case .failed(let retryAt?, _) = queued.first?.status {
      #expect(retryAt == (await harness.clock.now()).addingTimeInterval(2))
    } else {
      Issue.record("expected a failed item with a retry time, got \(String(describing: queued.first?.status))")
    }

    await harness.clock.advance(by: 2)
    await harness.outbox.settled()
    #expect(await harness.uploader.created.count == 1)
    #expect(await harness.outbox.queue().isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func retryNowSendsAnItemBeforeItsDeadline() async throws {
    let harness = try await OutboxHarness()
    await harness.uploader.failNextCreates(1)
    await harness.outbox.enqueueItem(textItem(memo(1)))
    await harness.outbox.settled()
    #expect(await harness.uploader.created.isEmpty)

    await harness.outbox.retryNow(memo(1))
    await harness.outbox.settled()
    #expect(await harness.uploader.created.count == 1)
    #expect(await harness.outbox.queue().isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func aPermanentRefusalStallsUntilTheUserRetries() async throws {
    let harness = try await OutboxHarness()
    await harness.uploader.failNextCreates(1, permanent: true)
    await harness.outbox.enqueueItem(textItem(memo(1)))
    await harness.outbox.settled()
    #expect(await harness.outbox.queue().first?.status == .failed(retryAt: nil, reason: "refused"))

    await harness.clock.advance(by: 10_000)
    await harness.outbox.settled()
    #expect(await harness.uploader.createAttempts == 1, "a stalled item never retries by itself")

    await harness.outbox.retryNow(memo(1))
    await harness.outbox.settled()
    #expect(await harness.uploader.created.count == 1)
    await harness.outbox.shutdown()
  }

  @Test func aTakeCreatesTheMemoFirstThenUploadsThenCompletes() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    await harness.outbox.enqueueItem(voiceItem(id))
    for index in 0..<2 { await harness.outbox.enqueue(segment(id, index)) }
    await harness.outbox.finishMemo(id, segmentCount: 2)
    await harness.outbox.settled()

    let log = await harness.uploader.log
    #expect(log.first == "create")
    #expect(log.last == "complete")
    #expect(log.filter { $0 == "upload" }.count == 2)
    #expect(await harness.outbox.queue().isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func segmentsRecordedWhileTheCreateFailsGoUpOnceItSucceeds() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    await harness.uploader.failNextCreates(1)
    await harness.outbox.enqueueItem(voiceItem(id))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.settled()
    #expect(await harness.uploader.uploaded.isEmpty, "the memo does not exist on the server yet")

    await harness.clock.advance(by: 2)
    await harness.outbox.settled()
    #expect(await harness.uploader.uploaded == [SegmentKey(memoID: id, index: 0)])
    await harness.outbox.shutdown()
  }

  @Test func theQueueSurvivesARelaunch() async throws {
    let first = try await OutboxHarness()
    await first.uploader.failNextCreates(1)
    await first.outbox.enqueueItem(textItem(memo(1), text: "survives"))
    await first.outbox.settled()
    let record = await first.store.load()
    await first.outbox.shutdown()

    let second = try await OutboxHarness(record: record, clock: first.clock)
    #expect(await second.outbox.queue().map(\.item.title) == ["survives"])
    await second.clock.advance(by: 2)
    await second.outbox.settled()
    #expect(await second.uploader.created.map(\.memoID) == [memo(1)])
    await second.outbox.shutdown()
  }

  @Test func discardRemovesTheItemItsSegmentsAndTheirFiles() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "0.m4a")
    try Data("x".utf8).write(to: file)
    let harness = try await OutboxHarness()
    await harness.uploader.failNextCreates(1)
    await harness.outbox.enqueueItem(voiceItem(memo(1)))
    await harness.outbox.enqueue(
      ClosedSegment(memoID: memo(1), index: 0, fileURL: file, byteCount: 1, duration: 1))
    await harness.outbox.settled()

    await harness.outbox.discard(memo(1))
    #expect(await harness.outbox.queue().isEmpty)
    #expect(await harness.outbox.entries().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    await harness.outbox.shutdown()
  }

  @Test func completedMemosDeleteTheirSegmentFiles() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "0.m4a")
    try Data("x".utf8).write(to: file)
    let harness = try await OutboxHarness()
    await harness.outbox.enqueue(ClosedSegment(memoID: memo(1), index: 0, fileURL: file, byteCount: 1, duration: 1))
    await harness.outbox.finishMemo(memo(1), segmentCount: 1)
    await harness.outbox.settled()
    #expect(!FileManager.default.fileExists(atPath: file.path))
    await harness.outbox.shutdown()
  }

  @Test func changesYieldWhenTheQueueMoves() async throws {
    let harness = try await OutboxHarness()
    let changes = await harness.outbox.changes()
    await harness.uploader.failNextCreates(1)
    await harness.outbox.enqueueItem(textItem(memo(1)))
    await harness.outbox.settled()
    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() != nil)
    await harness.outbox.shutdown()
  }
}

struct JSONFileOutboxStoreTests {
  @Test func aSavedQueueLoadsBackAfterARelaunch() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONFileOutboxStore(fileURL: directory.appending(path: "nested/outbox.json"))
    var machine = OutboxStateMachine()
    machine.enqueueItem(textItem(memo(1), text: "persisted"))
    try await store.save(machine.record)

    let loaded = try await JSONFileOutboxStore(fileURL: directory.appending(path: "nested/outbox.json")).load()
    #expect(loaded.items.map(\.title) == ["persisted"])
  }

  @Test func aMissingFileIsAnEmptyQueue() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let loaded = try await JSONFileOutboxStore(fileURL: directory.appending(path: "none.json")).load()
    #expect(loaded == OutboxRecord())
  }

  @Test func anUnreadableFileIsMovedAsideAndTheQueueStartsEmpty() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "outbox.json")
    try Data("{not json".utf8).write(to: file)

    let loaded = try await JSONFileOutboxStore(fileURL: file).load()
    #expect(loaded == OutboxRecord())
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
  }
}
