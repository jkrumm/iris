import Foundation
import Synchronization
import Testing

@testable import IrisTelemetry

/// Holds every send until the test lets it go, so two flushes can be made to overlap.
private actor GatedTransport: TelemetryTransport {
  private(set) var batches: [TelemetryBatch] = []
  private(set) var attempts = 0
  private var gates: [CheckedContinuation<Void, Never>] = []
  private var open = false

  func send(_ batch: TelemetryBatch) async {
    attempts += 1
    if !open { await withCheckedContinuation { gates.append($0) } }
    batches.append(batch)
  }

  func release() {
    open = true
    let waiting = gates
    gates = []
    for gate in waiting { gate.resume() }
  }

  func untilAttempted(_ count: Int) async {
    while attempts < count { await Task.yield() }
  }
}

/// Never answers, but ends when cancelled (like `URLSession`).
private struct HangingTransport: TelemetryTransport {
  func send(_ batch: TelemetryBatch) async throws {
    try await Task.sleep(for: .seconds(3600))
  }
}

/// A store behind a file-protection class: every call fails until the phone is unlocked.
private actor LockedStore: TelemetryStore {
  private let inner = InMemoryTelemetryStore()
  private var locked = true

  func unlock() { locked = false }
  var stored: [StoredEntry] { get async { await inner.stored } }
  func seed(_ entries: [StoredEntry]) async { await inner.append(entries) }

  func append(_ entries: [StoredEntry]) async throws {
    guard !locked else { throw TestError.down }
    await inner.append(entries)
  }

  func load() async throws -> [StoredEntry] {
    guard !locked else { throw TestError.down }
    return await inner.load()
  }

  func removeThrough(sequence: UInt64) async throws {
    guard !locked else { throw TestError.down }
    await inner.removeThrough(sequence: sequence)
  }

  func clear() async throws {
    guard !locked else { throw TestError.down }
    await inner.clear()
  }
}

struct FlushConcurrencyTests {
  private func names(_ batches: [TelemetryBatch]) -> [String] {
    batches.flatMap(\.spans).map(\.name)
  }

  @Test func twoFlushesInFlightSendEachBatchOnce() async {
    let transport = GatedTransport()
    let buffer = TelemetryBuffer(capacity: 100)
    let exporter = RelayExporter(
      buffer: buffer, transport: transport, resource: Fixtures.resource, clock: ManualClock(), batchSize: 2)
    for index in 1...4 { await buffer.record(span: Fixtures.span(index)) }

    async let first: Void = exporter.flush()
    await transport.untilAttempted(1)
    async let second: Void = exporter.flush()
    async let third: Void = exporter.flush()
    await Task.yield()
    await transport.release()
    _ = await (first, second, third)

    #expect(names(await transport.batches).sorted() == ["span.1", "span.2", "span.3", "span.4"])
    #expect(await transport.attempts == 2, "two batches of two, sent once each")
    #expect(await buffer.pendingCount == 0)
  }

  @Test func aFlushThatJoinedStillCarriesWhatWasRecordedBeforeItWasCalled() async {
    let transport = GatedTransport()
    let buffer = TelemetryBuffer(capacity: 100)
    let exporter = RelayExporter(
      buffer: buffer, transport: transport, resource: Fixtures.resource, clock: ManualClock())
    await buffer.record(span: Fixtures.span(1))

    async let first: Void = exporter.flush()
    await transport.untilAttempted(1)
    await buffer.record(span: Fixtures.span(2))
    async let second: Void = exporter.flush()
    await transport.release()
    _ = await (first, second)

    #expect(names(await transport.batches).sorted() == ["span.1", "span.2"])
    #expect(await buffer.pendingCount == 0)
  }

  @Test func aFlushRacingTheLaunchRecoveryNeitherDoubleSendsNorDropsABatch() async {
    let store = InMemoryTelemetryStore()
    let before = TelemetryBuffer(capacity: 100, store: store)
    for index in 1...3 { await before.record(span: Fixtures.span(index)) }

    let buffer = TelemetryBuffer(capacity: 100, store: store)
    let transport = RecordingTransport()
    let exporter = RelayExporter(
      buffer: buffer, transport: transport, resource: Fixtures.resource, clock: ManualClock())
    async let launch: Void = exporter.flushOnLaunch()
    async let periodic: Void = exporter.flush()
    async let late: Void = buffer.record(span: Fixtures.span(4))
    _ = await (launch, periodic, late)
    await exporter.flush()

    #expect(names(await transport.batches).sorted() == ["span.1", "span.2", "span.3", "span.4"])
    #expect(await store.stored.isEmpty)
  }

  @Test func concurrentRecoveriesShareOneLoadAndAllWaitForIt() async {
    let store = InMemoryTelemetryStore()
    let before = TelemetryBuffer(capacity: 100, store: store)
    for index in 1...3 { await before.record(span: Fixtures.span(index)) }

    let buffer = TelemetryBuffer(capacity: 100, store: store)
    async let one: Void = buffer.recover()
    async let two: Void = buffer.recover()
    async let record: Void = buffer.record(span: Fixtures.span(4))
    _ = await (one, two, record)

    let drain = await buffer.drain(max: 10)
    #expect(drain.items.map(\.sequence) == [1, 2, 3, 4], "the new record is numbered after the stored ones")
  }

  @Test func recordsBeforeTheFirstUnlockAreKeptAndTheStoredQueueIsStillRecovered() async {
    let store = LockedStore()
    await store.seed([
      StoredEntry(sequence: 1, entry: .span(Fixtures.span(1))),
      StoredEntry(sequence: 2, entry: .span(Fixtures.span(2))),
    ])
    let buffer = TelemetryBuffer(capacity: 100, store: store)

    await buffer.recover()  // refused: the phone has not been unlocked
    await buffer.record(span: Fixtures.span(3))
    await buffer.acknowledge(TelemetryDrain(items: [], dropped: 0))
    #expect(await buffer.pendingCount == 1, "held in memory, nothing crashed, nothing lost")

    await store.unlock()
    await buffer.recover()
    let drain = await buffer.drain(max: 10)
    #expect(drain.entries == [.span(Fixtures.span(1)), .span(Fixtures.span(2)), .span(Fixtures.span(3))])
    #expect(Set(drain.items.map(\.sequence)).count == 3, "no reused sequence")
    #expect(
      await store.stored.map(\.sequence).contains(1), "the older stored entries are still on disk until acknowledged")

    await buffer.acknowledge(drain)
    #expect(await store.stored.isEmpty)
  }

  @Test func aDeliveryWhileTheStoreIsLockedDoesNotRemoveTheOlderStoredEntries() async {
    let store = LockedStore()
    await store.seed([StoredEntry(sequence: 1, entry: .span(Fixtures.span(1)))])
    let buffer = TelemetryBuffer(capacity: 100, store: store)
    await buffer.recover()
    await buffer.record(span: Fixtures.span(2))
    let transport = RecordingTransport()
    let exporter = RelayExporter(
      buffer: buffer, transport: transport, resource: Fixtures.resource, clock: ManualClock())
    await exporter.flush()
    #expect(names(await transport.batches) == ["span.2"])

    await store.unlock()
    await exporter.flush()  // retries the recovery, sends what the last run left
    #expect(names(await transport.batches) == ["span.2", "span.1"])
    #expect(await store.stored.isEmpty)
  }

  @Test func aSendThatNeverAnswersEndsAtItsBoundAndKeepsTheBatch() async {
    let buffer = TelemetryBuffer(capacity: 100)
    let exporter = RelayExporter(
      buffer: buffer, transport: HangingTransport(), resource: Fixtures.resource, clock: ManualClock(),
      sendTimeout: .milliseconds(50))
    await buffer.record(span: Fixtures.span(1))

    await exporter.flush()

    #expect(await buffer.pendingCount == 1, "requeued for the next attempt")
  }

  @Test func aPortUidIsNeverARecordAttribute() async {
    let buffer = TelemetryBuffer(capacity: 10)
    let log = DeviceEventLog(buffer: buffer)
    log.event(
      "audio.route_change",
      ["port.uid": "BuiltInMicrophoneDevice", "route.current.uid": "x", "input_uid": "y", "reason": "new_device"])
    await log.settle()
    let record = await buffer.drain(max: 1).entries.compactMap { entry -> LogRecord? in
      if case .log(let log) = entry { return log }
      return nil
    }.first
    #expect(record?.attributes["reason"] == "new_device")
    #expect(record?.attributes.keys.contains { $0.hasSuffix("uid") } == false)
  }
}
