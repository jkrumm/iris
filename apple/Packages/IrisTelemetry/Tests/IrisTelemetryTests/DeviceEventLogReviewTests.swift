import Foundation
import Synchronization
import Testing

@testable import IrisTelemetry

/// Holds `send` until the test lets it go, to observe what a second flush does meanwhile.
private actor GatedTransport: TelemetryTransport {
  private(set) var started = 0
  private(set) var delivered = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var open = false

  func send(_ batch: TelemetryBatch) async {
    started += 1
    if !open { await withCheckedContinuation { waiters.append($0) } }
    delivered += 1
  }

  func release() {
    open = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

private actor Flag {
  private(set) var isSet = false
  func set() { isSet = true }
}

struct DeviceEventLogReviewTests {
  @Test func eventsRecordedAfterALaunchNeverReuseTheSequenceOfWhatTheLastRunLeft() async {
    let store = InMemoryTelemetryStore()
    let lastRun = TelemetryBuffer(capacity: 100, store: store)
    await lastRun.record(log: Fixtures.log(1))
    await lastRun.record(log: Fixtures.log(2))

    // The new process records before anything has asked for the stored queue.
    let buffer = TelemetryBuffer(capacity: 100, store: store)
    let log = DeviceEventLog(buffer: buffer, clock: ManualClock())
    log.event("app.launch")
    await log.settle()

    let drain = await buffer.drain(max: 10)
    #expect(
      drain.items.map(\.sequence) == [1, 2, 3], "the old records come first and the new one is numbered after them")
    #expect(drain.entries.count == 3)
    await buffer.acknowledge(TelemetryDrain(items: Array(drain.items.prefix(2)), dropped: 0))
    #expect(await store.stored.map(\.sequence) == [3], "acknowledging the old records leaves the new one")
  }

  @Test func aDurableEventIsOnDiskWhenTheCallReturns() async {
    let file = Fixtures.temporaryFileURL()
    defer { Fixtures.remove(file) }
    let buffer = TelemetryBuffer(capacity: 100, store: FileTelemetryStore(fileURL: file))
    let log = DeviceEventLog(buffer: buffer, clock: ManualClock())

    log.durableEvent("capture.tap.install", ["rate": 48000])

    // Nothing was settled or flushed: this is what a process that aborts right after the call leaves.
    let onDisk = try? await FileTelemetryStore(fileURL: file).load()
    #expect(onDisk?.count == 1)
    if case .log(let record)? = onDisk?.first?.entry {
      #expect(record.body == "capture.tap.install")
    } else {
      Issue.record("the preflight record is not on disk")
    }
  }

  @Test func aTornLastLineIsCutOffBeforeTheNextRecordIsAppended() async throws {
    let file = Fixtures.temporaryFileURL()
    defer { Fixtures.remove(file) }
    let store = FileTelemetryStore(fileURL: file)
    try await store.append([StoredEntry(sequence: 1, entry: .log(Fixtures.log(1)))])
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"sequence":2,"entry":{"kind":"lo"#.utf8))
    try handle.close()

    try await store.append([StoredEntry(sequence: 3, entry: .log(Fixtures.log(3)))])

    let loaded = try await store.load()
    #expect(loaded.map(\.sequence) == [1, 3], "the new record was not glued to the torn fragment")
  }

  @Test func aSecondFlushWaitsForTheOneInFlightSoABackgroundAssertionOutlivesTheSend() async throws {
    let transport = GatedTransport()
    let buffer = TelemetryBuffer(capacity: 100)
    let exporter = RelayExporter(
      buffer: buffer, transport: transport, resource: Fixtures.resource, clock: ManualClock())
    await buffer.record(log: Fixtures.log(1))

    let first = Task { await exporter.flush() }
    while await transport.started == 0 { try await Task.sleep(for: .milliseconds(5)) }
    let joined = Flag()
    let second = Task {
      await exporter.flush()
      await joined.set()
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await !joined.isSet, "the second flush returned while the first send was still in flight")

    await transport.release()
    await first.value
    await second.value
    #expect(await joined.isSet)
    #expect(await transport.delivered == 1)
  }
}
