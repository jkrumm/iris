import Foundation
import Testing

@testable import IrisTelemetry

struct RelayExporterTests {
  private func makeExporter(
    capacity: Int = 100,
    batchSize: Int = 100,
    transport: RecordingTransport,
    clock: ManualClock = ManualClock(),
    store: any TelemetryStore = InMemoryTelemetryStore()
  ) -> (RelayExporter, TelemetryBuffer) {
    let buffer = TelemetryBuffer(capacity: capacity, store: store)
    let exporter = RelayExporter(
      buffer: buffer,
      transport: transport,
      resource: Fixtures.resource,
      clock: clock,
      batchSize: batchSize
    )
    return (exporter, buffer)
  }

  @Test func flushSendsBatchesCappedAtBatchSizeInOrder() async {
    let transport = RecordingTransport()
    let (exporter, buffer) = makeExporter(batchSize: 2, transport: transport)
    for index in 1...5 { await buffer.record(span: Fixtures.span(index)) }

    await exporter.flush()

    #expect(
      Fixtures.spanNames(await transport.batches) == [["span.1", "span.2"], ["span.3", "span.4"], ["span.5"]])
    #expect(await transport.batches.allSatisfy { $0.resource == Fixtures.resource })
    #expect(await buffer.pendingCount == 0)
  }

  @Test func flushWithNothingBufferedSendsNothing() async {
    let transport = RecordingTransport()
    let (exporter, _) = makeExporter(transport: transport)
    await exporter.flush()
    #expect(await transport.attempts == 0)
  }

  @Test func overflowCountIsReportedInTheNextBatchOnly() async {
    let transport = RecordingTransport()
    let (exporter, buffer) = makeExporter(capacity: 2, transport: transport)
    for index in 1...4 { await buffer.record(span: Fixtures.span(index)) }
    await exporter.flush()
    await buffer.record(span: Fixtures.span(5))
    await exporter.flush()

    let batches = await transport.batches
    #expect(batches.map(\.dropped) == [2, 0])
    #expect(Fixtures.spanNames(batches) == [["span.3", "span.4"], ["span.5"]])
  }

  @Test func failedFlushKeepsDataAndRetriesInOrder() async {
    let transport = RecordingTransport(failures: 1)
    let (exporter, buffer) = makeExporter(batchSize: 2, transport: transport)
    for index in 1...3 { await buffer.record(span: Fixtures.span(index)) }

    await exporter.flush()
    #expect(await transport.batches.isEmpty)
    #expect(await buffer.pendingCount == 3)

    await buffer.record(log: Fixtures.log(4))
    await exporter.flush()
    let batches = await transport.batches
    #expect(Fixtures.spanNames(batches) == [["span.1", "span.2"], ["span.3"]])
    #expect(batches.last?.logs.map(\.body) == ["log.4"])
  }

  @Test func failedFlushKeepsTheDroppedCount() async {
    let transport = RecordingTransport(failures: 1)
    let (exporter, buffer) = makeExporter(capacity: 1, transport: transport)
    await buffer.record(span: Fixtures.span(1))
    await buffer.record(span: Fixtures.span(2))

    await exporter.flush()
    await exporter.flush()

    #expect(await transport.batches.map(\.dropped) == [1])
  }

  @Test func flushOnBackgroundSendsImmediately() async {
    let transport = RecordingTransport()
    let (exporter, buffer) = makeExporter(transport: transport)
    await buffer.record(span: Fixtures.span(1))
    await exporter.flushOnBackground()
    #expect(await transport.batches.count == 1)
  }

  @Test func flushOnLaunchSendsWhatACrashLeftBehind() async throws {
    let fileURL = Fixtures.temporaryFileURL()
    defer { Fixtures.remove(fileURL) }
    let crashed = TelemetryBuffer(capacity: 10, store: FileTelemetryStore(fileURL: fileURL))
    await crashed.record(span: Fixtures.span(1))
    await crashed.record(log: Fixtures.log(2))

    let transport = RecordingTransport()
    let store = FileTelemetryStore(fileURL: fileURL)
    let (exporter, _) = makeExporter(transport: transport, store: store)
    await exporter.flushOnLaunch()

    let batch = try #require(await transport.batches.first)
    #expect(batch.spans.map(\.name) == ["span.1"])
    #expect(batch.logs.map(\.body) == ["log.2"])
    #expect(try await store.load().isEmpty)
  }

  @Test func loopFlushesEveryIntervalOnTheInjectedClock() async {
    let clock = ManualClock()
    let transport = RecordingTransport()
    let (exporter, buffer) = makeExporter(transport: transport, clock: clock)
    let loop = Task { await exporter.run() }
    await clock.untilSleeping()
    await buffer.record(span: Fixtures.span(1))

    await clock.advance(by: .seconds(9))
    #expect(await transport.attempts == 0)

    await clock.advance(by: .seconds(1))
    await clock.untilSleeping()
    #expect(Fixtures.spanNames(await transport.batches) == [["span.1"]])

    await buffer.record(span: Fixtures.span(2))
    await clock.advance(by: .seconds(10))
    await clock.untilSleeping()
    #expect(Fixtures.spanNames(await transport.batches) == [["span.1"], ["span.2"]])
    #expect(await clock.requestedSleeps == [.seconds(10), .seconds(10), .seconds(10)])

    loop.cancel()
    await loop.value
  }

  @Test func loopBacksOffAfterFailuresKeepsDataAndResetsOnSuccess() async {
    let clock = ManualClock()
    let transport = RecordingTransport(failures: 2)
    let (exporter, buffer) = makeExporter(transport: transport, clock: clock)
    let loop = Task { await exporter.run() }
    await clock.untilSleeping()
    await buffer.record(span: Fixtures.span(1))

    await clock.advance(by: .seconds(10))
    await clock.untilSleeping()
    #expect(await transport.attempts == 1)
    #expect(await buffer.pendingCount == 1)

    await clock.advance(by: .seconds(20))
    await clock.untilSleeping()
    #expect(await transport.attempts == 2)
    #expect(await buffer.pendingCount == 1)

    await clock.advance(by: .seconds(40))
    await clock.untilSleeping()
    #expect(Fixtures.spanNames(await transport.batches) == [["span.1"]])
    #expect(await buffer.pendingCount == 0)
    #expect(await clock.requestedSleeps == [.seconds(10), .seconds(20), .seconds(40), .seconds(10)])

    loop.cancel()
    await loop.value
  }

  @Test func backoffIsCapped() async {
    let clock = ManualClock()
    let transport = RecordingTransport(failures: 100)
    let buffer = TelemetryBuffer(capacity: 10)
    let exporter = RelayExporter(
      buffer: buffer,
      transport: transport,
      resource: Fixtures.resource,
      clock: clock,
      interval: .seconds(10),
      maxBackoff: .seconds(60)
    )
    await buffer.record(span: Fixtures.span(1))
    let loop = Task { await exporter.run() }
    await clock.untilSleeping()
    for delay in [10, 20, 40, 60] {
      await clock.advance(by: .seconds(delay))
      await clock.untilSleeping()
    }
    #expect(await clock.requestedSleeps == [10, 20, 40, 60, 60].map { Duration.seconds($0) })

    loop.cancel()
    await loop.value
  }

  @Test func cancellingTheLoopStopsItWhileSleeping() async {
    let clock = ManualClock()
    let (exporter, _) = makeExporter(transport: RecordingTransport(), clock: clock)
    let loop = Task { await exporter.run() }
    await clock.untilSleeping()
    loop.cancel()
    await loop.value
  }
}
