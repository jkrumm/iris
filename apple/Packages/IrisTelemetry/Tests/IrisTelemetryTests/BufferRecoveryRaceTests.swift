import Foundation
import Testing

@testable import IrisTelemetry

/// A store that fails on demand and counts what reached it, so "the store was not touched" is checkable.
private actor FlakyStore: TelemetryStore {
  private let inner = InMemoryTelemetryStore()
  var loadFails = true
  var appendFails = false
  private(set) var appendCalls = 0
  private(set) var removeCalls = 0

  func seed(_ entries: [StoredEntry]) async { await inner.append(entries) }
  func set(loadFails: Bool, appendFails: Bool = false) {
    self.loadFails = loadFails
    self.appendFails = appendFails
  }
  var stored: [StoredEntry] { get async { await inner.stored } }

  func append(_ entries: [StoredEntry]) async throws {
    appendCalls += 1
    if appendFails { throw TestError.down }
    await inner.append(entries)
  }

  func load() async throws -> [StoredEntry] {
    if loadFails { throw TestError.down }
    return await inner.load()
  }

  func removeThrough(sequence: UInt64) async throws {
    removeCalls += 1
    await inner.removeThrough(sequence: sequence)
  }

  func clear() async throws { await inner.clear() }
}

/// The recovery design: numbering waits for the first load; an unread store is never written; the load renumbers this run's
/// records above the stored maximum, persists them, and only then is the buffer recovered.
struct BufferRecoveryRaceTests {
  private func stored(_ numbers: ClosedRange<Int>) -> [StoredEntry] {
    numbers.map { StoredEntry(sequence: UInt64($0), entry: .span(Fixtures.span($0))) }
  }

  @Test func aRecordMadeBeforeAnyRecoveryIsNumberedAfterTheStoredEntries() async {
    let store = FlakyStore()
    await store.set(loadFails: false)
    await store.seed(stored(1...3))
    let buffer = TelemetryBuffer(capacity: 100, store: store)

    await buffer.record(span: Fixtures.span(9))  // nobody called recover()

    let drain = await buffer.drain(max: 10)
    #expect(drain.items.map(\.sequence) == [1, 2, 3, 4])
    #expect(await store.stored.map(\.sequence) == [1, 2, 3, 4])
  }

  @Test func anUnreadStoreIsNeverWrittenTrimmedOrAcknowledgedAgainst() async {
    let store = FlakyStore()
    await store.seed(stored(1...2))
    let buffer = TelemetryBuffer(capacity: 2, store: store)

    for index in 3...8 { await buffer.record(span: Fixtures.span(index)) }  // overflows twice over
    let drain = await buffer.drain(max: 10)
    await buffer.acknowledge(drain)

    #expect(await store.appendCalls == 0)
    #expect(await store.removeCalls == 0)
    #expect(await store.stored.map(\.sequence) == [1, 2], "the last run's entries are untouched")
    #expect(drain.dropped == 4, "the overflow is still counted")
  }

  @Test func aSuccessfulAppendWhileTheLoadFailsDoesNotCreateADuplicateLater() async {
    let store = FlakyStore()  // load fails, append would succeed
    await store.seed(stored(1...2))
    let buffer = TelemetryBuffer(capacity: 100, store: store)
    await buffer.record(span: Fixtures.span(3))
    await buffer.record(span: Fixtures.span(4))
    #expect(await store.stored.map(\.sequence) == [1, 2], "memory only while unread")

    await store.set(loadFails: false)
    await buffer.recover()

    let sequences = await store.stored.map(\.sequence)
    #expect(sequences == [1, 2, 3, 4], "each of this run's records is in the store exactly once")
    let drain = await buffer.drain(max: 10)
    #expect(drain.items.map(\.sequence) == [1, 2, 3, 4])
    #expect(drain.entries.count == 4)
  }

  @Test func theRunsRecordsAreRenumberedAboveTheStoredMaximum() async {
    let store = FlakyStore()
    await store.seed(stored(1...2) + [StoredEntry(sequence: 5000, entry: .span(Fixtures.span(7)))])
    let buffer = TelemetryBuffer(capacity: 100, store: store)
    await buffer.record(span: Fixtures.span(8))  // numbered 1 in memory, below stored entries
    await buffer.record(span: Fixtures.span(9))

    await store.set(loadFails: false)
    await buffer.recover()
    await buffer.record(span: Fixtures.span(10))

    let drain = await buffer.drain(max: 10)
    #expect(drain.items.map(\.sequence) == [1, 2, 5000, 5001, 5002, 5003])
    #expect(Set(drain.items.map(\.sequence)).count == 6)
  }

  @Test func aFailedPersistLeavesTheBufferUnrecoveredAndTheNextRecoverRetriesIt() async {
    let store = FlakyStore()
    await store.seed(stored(1...2))
    let buffer = TelemetryBuffer(capacity: 100, store: store)
    await buffer.record(span: Fixtures.span(3))

    await store.set(loadFails: false, appendFails: true)
    await buffer.recover()  // loads, cannot persist this run's record
    #expect(await store.stored.map(\.sequence) == [1, 2])
    #expect(await buffer.pendingCount == 1, "nothing merged, nothing lost")
    await buffer.acknowledge(TelemetryDrain(items: [], dropped: 0))
    await buffer.record(span: Fixtures.span(4))
    #expect(await store.stored.map(\.sequence) == [1, 2], "still memory only")

    await store.set(loadFails: false, appendFails: false)
    await buffer.recover()
    #expect(await store.stored.map(\.sequence) == [1, 2, 3, 4])
    let drain = await buffer.drain(max: 10)
    #expect(drain.items.map(\.sequence) == [1, 2, 3, 4])
  }

  @Test func recoveryWaitsOutASendInFlightInsteadOfRenumberingUnderIt() async {
    let store = FlakyStore()
    await store.seed(stored(1...2))
    let buffer = TelemetryBuffer(capacity: 100, store: store)
    await buffer.record(span: Fixtures.span(3))
    let inFlight = await buffer.drain(max: 10)  // a send holds the record, numbered 1 in memory

    await store.set(loadFails: false)
    await buffer.recover()
    #expect(await store.appendCalls == 0, "not recovered while a send holds entries of the memory numbering")

    await buffer.requeue(inFlight)
    await buffer.recover()
    #expect(await store.stored.map(\.sequence) == [1, 2, 3])
  }

  @Test func theSequenceNeverDependsOnTheClock() async {
    // The old design numbered an unread run from the wall clock, which breaks when the clock goes back. Numbers now come only
    // from the stored maximum, so the same inputs give the same numbers whatever the date.
    let store = FlakyStore()
    await store.seed(stored(1...1))
    let buffer = TelemetryBuffer(capacity: 100, store: store)
    await buffer.record(span: Fixtures.span(2))
    await store.set(loadFails: false)
    await buffer.recover()
    let drain = await buffer.drain(max: 10)
    #expect(drain.items.map(\.sequence) == [1, 2])
  }
}
