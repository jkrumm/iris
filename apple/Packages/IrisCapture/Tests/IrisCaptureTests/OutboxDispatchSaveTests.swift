import Foundation
import Testing

@testable import IrisCapture

/// A store that holds the save which records a create as handed out, so a test can look at the world before that save
/// lands (and "kill" the app there).
private actor DispatchGatedStore: OutboxStore {
  private var record = OutboxRecord()
  private(set) var heldRecord: OutboxRecord?
  private var held: CheckedContinuation<Void, Never>?
  private var arrival: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func load() -> OutboxRecord { record }

  func save(_ record: OutboxRecord) async {
    self.record = record
    guard !isOpen, record.items.contains(where: { $0.create == .uploading }) else { return }
    heldRecord = record
    arrival?.resume()
    arrival = nil
    await withCheckedContinuation { held = $0 }
  }

  func waitUntilHeld() async {
    guard heldRecord == nil else { return }
    await withCheckedContinuation { arrival = $0 }
  }

  func open() {
    isOpen = true
    held?.resume()
    held = nil
  }
}

struct OutboxDispatchSaveTests {
  @Test func aCreateIsSentOnlyAfterTheSaveThatMarksItLanded() async throws {
    let store = DispatchGatedStore()
    let uploader = TestUploader()
    let outbox = try await Outbox(
      store: store, uploader: uploader, clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
    let id = memo(1)
    try await outbox.enqueueItem(voiceItem(id))
    let enqueueing = Task { await outbox.enqueue(segment(id, 0)) }
    await store.waitUntilHeld()
    try await Task.sleep(for: .milliseconds(100))  // long enough for a request that was wrongly started to show

    #expect(await uploader.createAttempts == 0, "nothing is on the wire while the dispatch is unsaved")
    let onDisk = try #require(await store.heldRecord)
    #expect(onDisk.items.first?.createMayHaveLanded == true)

    await store.open()
    await enqueueing.value
    await outbox.settled()
    #expect(await uploader.created.map(\.memoID) == [id], "released, it goes out")
    await outbox.shutdown()
  }

  @Test func aKillBeforeTheDispatchSaveLandedStillLeavesTheFlagForADiscard() async throws {
    let store = DispatchGatedStore()
    let outbox = try await Outbox(
      store: store, uploader: TestUploader(), clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
    let id = memo(1)
    try await outbox.enqueueItem(voiceItem(id))
    let enqueueing = Task { await outbox.enqueue(segment(id, 0)) }
    await store.waitUntilHeld()
    let onDisk = try #require(await store.heldRecord)  // the app is killed with the save in flight

    let relaunched = try await OutboxHarness(record: onDisk)
    await relaunched.outbox.discard(id)
    await relaunched.outbox.settled()
    #expect(await relaunched.uploader.deleted == [id], "the memo the server may have is deleted")

    await store.open()
    await enqueueing.value
    await outbox.shutdown()
    await relaunched.outbox.shutdown()
  }

  @Test func aDiscardDuringTheDispatchSaveStopsTheCreate() async throws {
    let store = DispatchGatedStore()
    let uploader = TestUploader()
    let outbox = try await Outbox(
      store: store, uploader: uploader, clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
    let id = memo(1)
    try await outbox.enqueueItem(voiceItem(id))
    let enqueueing = Task { await outbox.enqueue(segment(id, 0)) }
    await store.waitUntilHeld()
    let discarding = Task { await outbox.discard(id) }
    try await Task.sleep(for: .milliseconds(50))  // the discard has reached the outbox

    await store.open()
    await enqueueing.value
    await discarding.value
    await outbox.settled()

    #expect(await uploader.created.isEmpty, "a create for a discarded take must not follow its DELETE")
    #expect(await uploader.createAttempts == 0)
    await outbox.shutdown()
  }

  @Test func theConcurrencyCapHoldsWhileADispatchIsBeingSaved() async throws {
    let harness = try await OutboxHarness(policy: OutboxPolicy(maxConcurrentUploads: 2, jitter: { 0 }))
    await harness.uploader.hold()
    let id = memo(1)
    try await harness.outbox.enqueueItem(voiceItem(id))
    for index in 0..<6 { await harness.outbox.enqueue(segment(id, index)) }
    await harness.uploader.waitUntilStarted(2)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await harness.uploader.maxInFlight <= 2)
    await harness.uploader.releaseAll()
    await harness.outbox.settled()
    await harness.outbox.shutdown()
  }
}
