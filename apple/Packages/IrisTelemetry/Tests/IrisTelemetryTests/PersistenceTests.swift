import Foundation
import Testing

@testable import IrisTelemetry

struct PersistenceTests {
  @Test func everyRecordIsStoredAndAcknowledgeRemovesDeliveredEntries() async {
    let store = InMemoryTelemetryStore()
    let buffer = TelemetryBuffer(capacity: 10, store: store)
    for index in 1...3 { await buffer.record(span: Fixtures.span(index)) }
    #expect(await store.stored.count == 3)

    let drain = await buffer.drain(max: 2)
    #expect(await store.stored.count == 3, "drained but unacknowledged entries stay stored")

    await buffer.acknowledge(drain)
    #expect(await store.stored.map(\.entry) == [.span(Fixtures.span(3))])
  }

  @Test func requeuedEntriesStayStored() async {
    let store = InMemoryTelemetryStore()
    let buffer = TelemetryBuffer(capacity: 10, store: store)
    await buffer.record(span: Fixtures.span(1))
    let drain = await buffer.drain(max: 10)
    await buffer.requeue(drain)
    #expect(await store.stored.count == 1)
  }

  @Test func newBufferRecoversWhatTheStoreHolds() async {
    let store = InMemoryTelemetryStore()
    let crashed = TelemetryBuffer(capacity: 10, store: store)
    await crashed.record(span: Fixtures.span(1))
    await crashed.record(log: Fixtures.log(2))

    let relaunched = TelemetryBuffer(capacity: 10, store: store)
    await relaunched.recover()
    await relaunched.record(span: Fixtures.span(3))

    let drain = await relaunched.drain(max: 10)
    #expect(drain.entries == [.span(Fixtures.span(1)), .log(Fixtures.log(2)), .span(Fixtures.span(3))])
  }

  @Test func recoverRunsOnlyOnce() async {
    let store = InMemoryTelemetryStore()
    await TelemetryBuffer(capacity: 10, store: store).record(span: Fixtures.span(1))

    let buffer = TelemetryBuffer(capacity: 10, store: store)
    await buffer.recover()
    await buffer.recover()
    #expect(await buffer.pendingCount == 1)
  }

  @Test func recoveryBeyondCapacityKeepsNewestAndCountsTheRest() async {
    let store = InMemoryTelemetryStore()
    let first = TelemetryBuffer(capacity: 10, store: store)
    for index in 1...5 { await first.record(span: Fixtures.span(index)) }

    let small = TelemetryBuffer(capacity: 2, store: store)
    await small.recover()
    let drain = await small.drain(max: 10)
    #expect(drain.entries == [4, 5].map { .span(Fixtures.span($0)) })
    #expect(drain.dropped == 3)
  }

  @Test func storeStaysBoundedWhileOffline() async {
    let store = InMemoryTelemetryStore()
    let buffer = TelemetryBuffer(capacity: 4, store: store)
    for index in 1...100 { await buffer.record(span: Fixtures.span(index)) }
    #expect(await store.stored.count <= 8)
    #expect(await store.stored.map(\.entry).suffix(4) == (97...100).map { .span(Fixtures.span($0)) })
  }

  @Test func fileStoreSurvivesACrashAndKeepsAttributeTypes() async throws {
    let fileURL = Fixtures.temporaryFileURL()
    defer { Fixtures.remove(fileURL) }
    let rich = SpanRecord(
      traceID: Fixtures.traceID,
      spanID: SpanID(9),
      parentSpanID: SpanID(8),
      name: "rich",
      start: Fixtures.epoch.addingTimeInterval(0.125),
      end: Fixtures.epoch.addingTimeInterval(3.5),
      status: .error,
      attributes: ["s": "text", "i": 7, "d": 0.5, "b": true]
    )
    let crashed = TelemetryBuffer(capacity: 10, store: FileTelemetryStore(fileURL: fileURL))
    await crashed.record(span: rich)
    await crashed.record(log: Fixtures.log(2))

    let relaunched = TelemetryBuffer(capacity: 10, store: FileTelemetryStore(fileURL: fileURL))
    await relaunched.recover()

    let drain = await relaunched.drain(max: 10)
    #expect(drain.entries == [.span(rich), .log(Fixtures.log(2))])
  }

  @Test func fileStoreDropsAcknowledgedEntriesFromDisk() async throws {
    let fileURL = Fixtures.temporaryFileURL()
    defer { Fixtures.remove(fileURL) }
    let store = FileTelemetryStore(fileURL: fileURL)
    let buffer = TelemetryBuffer(capacity: 10, store: store)
    for index in 1...3 { await buffer.record(span: Fixtures.span(index)) }

    await buffer.acknowledge(await buffer.drain(max: 2))
    #expect(try await store.load().map(\.entry) == [.span(Fixtures.span(3))])

    await buffer.acknowledge(await buffer.drain(max: 2))
    #expect(try await store.load().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  }

  @Test func fileStoreSkipsATornTrailingLine() async throws {
    let fileURL = Fixtures.temporaryFileURL()
    defer { Fixtures.remove(fileURL) }
    let store = FileTelemetryStore(fileURL: fileURL)
    let buffer = TelemetryBuffer(capacity: 10, store: store)
    await buffer.record(span: Fixtures.span(1))

    let handle = try FileHandle(forWritingTo: fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"sequence":2,"entry":{"kind":"sp"#.utf8))
    try handle.close()

    #expect(try await store.load().map(\.entry) == [.span(Fixtures.span(1))])
  }

  @Test func fileStoreClearRemovesTheFile() async throws {
    let fileURL = Fixtures.temporaryFileURL()
    defer { Fixtures.remove(fileURL) }
    let store = FileTelemetryStore(fileURL: fileURL)
    try await store.append([StoredEntry(sequence: 1, entry: .log(Fixtures.log(1)))])
    try await store.clear()
    #expect(try await store.load().isEmpty)
    try await store.clear()
  }

  /// Regression: `removeThrough` reads the file, filters and rewrites it. When the store was a struct, nothing
  /// serialized that read-modify-write against `append`, so an entry appended between the read and the atomic write
  /// was overwritten and lost from disk. As an actor the whole operation is one unit. Appended sequences sit above
  /// every removal threshold, so all of them must survive however the calls interleave.
  @Test func concurrentAppendAndRemoveNeverLoseAnAppendedEntry() async throws {
    let fileURL = Fixtures.temporaryFileURL()
    defer { Fixtures.remove(fileURL) }
    let store = FileTelemetryStore(fileURL: fileURL)
    let iterations = 200
    let appendBase = UInt64(10_000)
    try await store.append((1...iterations).map { StoredEntry(sequence: UInt64($0), entry: .log(Fixtures.log($0))) })

    await withTaskGroup(of: Void.self) { group in
      for index in 1...iterations {
        group.addTask {
          let entry = StoredEntry(sequence: appendBase + UInt64(index), entry: .log(Fixtures.log(index)))
          try? await store.append([entry])
        }
        group.addTask {
          try? await store.removeThrough(sequence: UInt64(index))
        }
      }
    }
    try await store.removeThrough(sequence: UInt64(iterations))

    let sequences = try await store.load().map(\.sequence)
    #expect(sequences == (1...iterations).map { appendBase + UInt64($0) })
  }
}
