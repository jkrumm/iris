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
    #expect(try await harness.outbox.enqueueItem(textItem(memo(1), text: "order a router")))
    await harness.outbox.settled()

    #expect(await harness.uploader.created.map(\.memoID) == [memo(1)])
    #expect(await harness.outbox.queue().isEmpty)
    #expect(await harness.store.load().items.isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func theSameItemTwiceIsOneCreate() async throws {
    let harness = try await OutboxHarness()
    #expect(try await harness.outbox.enqueueItem(textItem(memo(1))))
    await harness.outbox.settled()
    #expect(try await !harness.outbox.enqueueItem(textItem(memo(1))))
    await harness.outbox.settled()
    #expect(await harness.uploader.createAttempts == 1)
    await harness.outbox.shutdown()
  }

  @Test func offlineQueuesTheItemAndTheRetryTimerSendsItWhenTheClockArrives() async throws {
    let harness = try await OutboxHarness()
    await harness.uploader.failNextCreates(1)
    try await harness.outbox.enqueueItem(textItem(memo(1)))
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
    try await harness.outbox.enqueueItem(textItem(memo(1)))
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
    try await harness.outbox.enqueueItem(textItem(memo(1)))
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
    try await harness.outbox.enqueueItem(voiceItem(id))
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
    try await harness.outbox.enqueueItem(voiceItem(id))
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
    try await first.outbox.enqueueItem(textItem(memo(1), text: "survives"))
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
    try await harness.outbox.enqueueItem(voiceItem(memo(1)))
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
    try await harness.outbox.enqueueItem(textItem(memo(1)))
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

  @Test func anUndecodableFileIsRefusedAndLeftExactlyAsItWas() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "outbox.json")
    let original = Data(#"{"entries":[],"memos":[],"items":[{"kind":"a case from the future"}],"nextSequence":0}"#.utf8)
    try original.write(to: file)

    await #expect(throws: OutboxStoreError.undecodable) { try await JSONFileOutboxStore(fileURL: file).load() }
    #expect(try Data(contentsOf: file) == original, "the queue on disk is not touched, moved or replaced")
    let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(siblings == ["outbox.json"], "no quarantine copy overwrites anything")
  }
}

/// A store that cannot write (a full disk, an I/O error) until `heal()`.
private actor UnwritableStore: OutboxStore {
  struct DiskFull: Error {}

  private var isHealthy = false
  private(set) var record = OutboxRecord()

  func heal() { isHealthy = true }
  func load() -> OutboxRecord { record }

  func save(_ record: OutboxRecord) throws {
    guard isHealthy else { throw DiskFull() }
    self.record = record
  }
}

struct OutboxPersistenceTests {
  @Test func anItemThatCouldNotBeWrittenIsNotAccepted() async throws {
    let store = UnwritableStore()
    let uploader = TestUploader()
    let outbox = try await Outbox(store: store, uploader: uploader, clock: ManualClock())

    await #expect(throws: OutboxError.notSaved) { try await outbox.enqueueItem(textItem(memo(1))) }
    #expect(await outbox.queue().isEmpty, "nothing is queued that a kill would lose")
    #expect(await uploader.createAttempts == 0, "and nothing was sent either: the caller still has the text")

    await store.heal()
    #expect(try await outbox.enqueueItem(textItem(memo(1))), "the same id can be handed over again once the disk works")
    await outbox.settled()
    #expect(await uploader.created.map(\.memoID) == [memo(1)])
    await outbox.shutdown()
  }
}

/// A store whose saves can be made to fail, or to wait for the test before they fail.
actor ScriptedSaveStore: OutboxStore {
  struct DiskFull: Error {}

  private var record = OutboxRecord()
  private var failing = false
  private var holdNextSave = false
  private var saveStarted: [CheckedContinuation<Void, Never>] = []
  private var heldSave: CheckedContinuation<Void, Never>?

  func fail(_ value: Bool) { failing = value }
  func holdNext() { holdNextSave = true }

  func waitUntilSaveHeld() async {
    if heldSave != nil { return }
    await withCheckedContinuation { saveStarted.append($0) }
  }

  func releaseHeldSave() {
    heldSave?.resume()
    heldSave = nil
  }

  func load() -> OutboxRecord { record }

  func save(_ record: OutboxRecord) async throws {
    if holdNextSave {
      holdNextSave = false
      await withCheckedContinuation { continuation in
        heldSave = continuation
        for waiter in saveStarted { waiter.resume() }
        saveStarted = []
      }
    }
    if failing { throw DiskFull() }
    self.record = record
  }
}

struct OutboxDurabilityTests {
  @Test func anItemWhoseSaveIsStillRunningIsNotSentToTheServer() async throws {
    let store = ScriptedSaveStore()
    let uploader = TestUploader()
    let outbox = try await Outbox(
      store: store, uploader: uploader, clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
    await store.fail(true)
    await store.holdNext()

    let enqueuing = Task { try await outbox.enqueueItem(textItem(memo(1))) }
    await store.waitUntilSaveHeld()
    // Anything else touching the outbox while the save is out (it may itself wait for that save).
    let resuming = Task { await outbox.resume() }
    var created = 0
    for _ in 0..<40 where created == 0 {
      try await Task.sleep(for: .milliseconds(5))
      created = await uploader.createAttempts
    }
    #expect(created == 0, "the server must not see an item the queue may still refuse")

    await store.releaseHeldSave()
    await resuming.value
    await #expect(throws: OutboxError.notSaved) { try await enqueuing.value }
    #expect(await uploader.createAttempts == 0)
    #expect(await outbox.items().isEmpty)
  }

  @Test func segmentFilesStayUntilTheCompletedStateIsSaved() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "0.m4a")
    try Data("audio".utf8).write(to: file)
    let id = memo(1)
    let store = ScriptedSaveStore()
    let uploader = TestUploader()
    let outbox = try await Outbox(
      store: store, uploader: uploader, clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
    // The segment is saved and goes up; the disk fails while it is in flight, so the completed state cannot be saved.
    await uploader.hold()
    await outbox.enqueue(ClosedSegment(memoID: id, index: 0, fileURL: file, byteCount: 5, duration: 1))
    await outbox.finishMemo(id, segmentCount: 1)
    await uploader.waitUntilStarted(1)
    await store.fail(true)
    await uploader.releaseAll()
    await outbox.settled()
    #expect(await uploader.completed.count == 1)
    #expect(FileManager.default.fileExists(atPath: file.path), "the record on disk still lists this segment")

    await store.fail(false)
    await outbox.flush()
    #expect(!FileManager.default.fileExists(atPath: file.path), "deleted once the completed state is on disk")
    let saved = await store.load()
    #expect(saved.memos.isEmpty && saved.entries.isEmpty)
  }

  @Test func aDiscardKeepsTheFilesUntilItIsSaved() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "0.m4a")
    try Data("audio".utf8).write(to: file)
    let id = memo(1)
    let store = ScriptedSaveStore()
    let outbox = try await Outbox(
      store: store, uploader: TestUploader(), clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
    await outbox.enqueue(ClosedSegment(memoID: id, index: 0, fileURL: file, byteCount: 5, duration: 1))
    await store.fail(true)

    await outbox.discard(id)
    #expect(FileManager.default.fileExists(atPath: file.path))
    await store.fail(false)
    await outbox.flush()
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }
}

/// A store whose saves follow a script, one entry per save: land at once, fail, or wait for the test and then land or fail.
actor SequencedSaveStore: OutboxStore {
  enum Step { case land, fail, holdThenLand, holdThenFail }
  struct DiskFull: Error {}

  private var plan: [Step]
  private var record = OutboxRecord()
  private(set) var saves = 0
  private var held: CheckedContinuation<Void, Never>?
  private var heldWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var heldCount = 0

  init(_ plan: [Step]) { self.plan = plan }

  func waitUntilHeld(_ count: Int) async {
    if heldCount >= count { return }
    await withCheckedContinuation { heldWaiters.append((count, $0)) }
  }

  func release() {
    held?.resume()
    held = nil
  }

  func load() -> OutboxRecord { record }

  func save(_ record: OutboxRecord) async throws {
    saves += 1
    let step = plan.isEmpty ? .land : plan.removeFirst()
    if step == .holdThenLand || step == .holdThenFail {
      await withCheckedContinuation { continuation in
        held = continuation
        heldCount += 1
        for waiter in heldWaiters where waiter.count <= heldCount { waiter.continuation.resume() }
        heldWaiters.removeAll { $0.count <= heldCount }
      }
    }
    if step == .fail || step == .holdThenFail { throw DiskFull() }
    self.record = record
  }
}

struct OutboxConcurrentSaveTests {
  @Test func anItemWrittenByAnEarlierSnapshotIsNotRefusedBecauseALaterOneFailed() async throws {
    // Save 1 belongs to another caller and is out when the item is queued; save 2 carries the item and lands; save 3, for a
    // change that came in meanwhile, fails.
    let store = SequencedSaveStore([.holdThenLand, .holdThenLand, .fail])
    let outbox = try await Outbox(
      store: store, uploader: TestUploader(), clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
    let other = memo(2)
    let flushing = Task { await outbox.enqueue(segment(other, 0)) }
    await store.waitUntilHeld(1)

    let item = voiceItem(memo(1))
    let queuing = Task { try await outbox.enqueueItem(item) }
    while await outbox.items().isEmpty { try await Task.sleep(for: .milliseconds(1)) }
    await store.release()  // save 1 lands; save 2 starts with the item in it
    await store.waitUntilHeld(2)

    let late = Task { await outbox.enqueue(segment(other, 1)) }  // a change after save 2's snapshot
    while await outbox.entries().count < 2 { try await Task.sleep(for: .milliseconds(1)) }
    await store.release()  // save 2 lands, save 3 fails

    let accepted = try await queuing.value
    await flushing.value
    await late.value
    #expect(accepted, "the item is on disk: it is queued, not refused")
    #expect(await store.load().items.map(\.memoID) == [item.memoID])
    #expect(await outbox.items().map(\.memoID) == [item.memoID])
  }

  @Test func aRefusedItemIsNotOnDiskAfterwards() async throws {
    let store = SequencedSaveStore([.fail])
    let outbox = try await Outbox(
      store: store, uploader: TestUploader(), clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
    await #expect(throws: OutboxError.notSaved) { try await outbox.enqueueItem(voiceItem(memo(1))) }
    #expect(await store.load().items.isEmpty)
    #expect(await outbox.items().isEmpty)
  }
}

struct OutboxSegmentSaveTests {
  private func poll(_ condition: () async -> Bool) async throws -> Bool {
    for _ in 0..<300 {
      if await condition() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  @Test func aSegmentIsNotUploadedUntilASaveThatCarriesItHasLanded() async throws {
    let store = ScriptedSaveStore()
    let uploader = TestUploader()
    let clock = ManualClock()
    let outbox = try await Outbox(store: store, uploader: uploader, clock: clock, policy: OutboxPolicy(jitter: { 0 }))
    await store.fail(true)

    await outbox.enqueue(segment(memo(1), 0))
    await outbox.finishMemo(memo(1), segmentCount: 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(
      await uploader.started == 0, "a crash now would lose a segment the server already has: nothing goes out yet")
    #expect(await outbox.saveFailure() != nil, "and the failure is visible")

    await store.fail(false)
    await clock.advance(by: 3)  // the save is retried on its own timer
    #expect(try await poll { await uploader.completed.count == 1 }, "once a save landed the segment goes out")
    #expect(await outbox.saveFailure() == nil)
    #expect(await outbox.queue().isEmpty)
  }

  @Test func theSaveIsRetriedWithBackoffUntilItLands() async throws {
    let store = ScriptedSaveStore()
    let clock = ManualClock()
    let outbox = try await Outbox(
      store: store, uploader: TestUploader(), clock: clock, policy: OutboxPolicy(jitter: { 0 }))
    await store.fail(true)
    await outbox.enqueue(segment(memo(1), 0))

    await clock.advance(by: 2)  // first retry: fails again
    try await Task.sleep(for: .milliseconds(50))
    #expect(await outbox.saveFailure() != nil)
    await store.fail(false)
    await clock.advance(by: 4)  // second retry: lands
    #expect(try await poll { await outbox.saveFailure() == nil })
    let saved = await store.load()
    #expect(saved.entries.map(\.key.memoID) == [memo(1)])
  }
}
