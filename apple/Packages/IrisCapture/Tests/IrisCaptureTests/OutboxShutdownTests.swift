import Foundation
import Testing

@testable import IrisCapture

/// Saves wait at a gate once it is closed, so a flush stays in progress while another caller coalesces onto it.
private actor GatedSaveStore: OutboxStore {
  private var record = OutboxRecord()
  private var isClosed = false
  private var held: [CheckedContinuation<Void, Never>] = []
  private var heldWaiters: [CheckedContinuation<Void, Never>] = []

  func load() -> OutboxRecord { record }

  func close() { isClosed = true }

  func open() {
    isClosed = false
    let continuations = held
    held = []
    for continuation in continuations { continuation.resume() }
  }

  func waitUntilHeld() async {
    guard held.isEmpty else { return }
    await withCheckedContinuation { heldWaiters.append($0) }
  }

  func save(_ record: OutboxRecord) async throws {
    if isClosed {
      await withCheckedContinuation { continuation in
        held.append(continuation)
        let waiters = heldWaiters
        heldWaiters = []
        for waiter in waiters { waiter.resume() }
      }
    }
    self.record = record
  }
}

private actor Flag {
  private(set) var isSet = false
  func set() { isSet = true }
}

private func eventually(seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
  for _ in 0..<Int(seconds * 100) {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}

struct OutboxShutdownTests {
  @Test func shutdownResumesAWaiterOfSettled() async throws {
    let harness = try await OutboxHarness()
    await harness.uploader.hold()
    await harness.outbox.enqueue(segment(memo(1), 0))
    await harness.uploader.waitUntilStarted(1)

    let returned = Flag()
    let waiter = Task {
      await harness.outbox.settled()
      await returned.set()
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await !returned.isSet, "an upload is on the wire, so the outbox is not settled")

    await harness.outbox.shutdown()
    #expect(await eventually { await returned.isSet }, "shutdown released the waiter")

    await harness.uploader.releaseAll()
    await waiter.value
  }

  @Test func shutdownResumesAWaiterOfAPersistThatCoalescedOntoAFlush() async throws {
    let store = GatedSaveStore()
    let outbox = try await Outbox(
      store: store, uploader: TestUploader(), clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
    await store.close()

    let first = Task { await outbox.persist() }
    await store.waitUntilHeld()
    let returned = Flag()
    let second = Task {
      let saved = await outbox.persist()
      await returned.set()
      return saved
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await !returned.isSet, "it waits for the flush in progress")

    await outbox.shutdown()
    #expect(await eventually { await returned.isSet }, "shutdown released the waiter")
    #expect(await second.value == false, "its own state was not saved yet")

    await store.open()
    _ = await first.value
  }
}
