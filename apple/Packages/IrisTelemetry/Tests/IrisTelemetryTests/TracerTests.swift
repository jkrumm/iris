import Foundation
import Testing

@testable import IrisTelemetry

struct TracerTests {
  private func makeTracer() -> (Tracer, TelemetryBuffer, ManualClock) {
    let clock = ManualClock()
    let buffer = TelemetryBuffer(capacity: 10)
    return (Tracer(buffer: buffer, clock: clock, ids: SequentialIDs()), buffer, clock)
  }

  @Test func startAndEndRecordASpanWithClockTimesAndGeneratedIDs() async {
    let (tracer, buffer, clock) = makeTracer()
    let span = await tracer.startSpan("capture", traceID: Fixtures.traceID, attributes: ["memo.id": "abc"])
    await clock.advance(by: .milliseconds(1500))
    await tracer.end(span, attributes: ["segments": 3])

    let drain = await buffer.drain(max: 10)
    #expect(
      drain.entries == [
        .span(
          SpanRecord(
            traceID: Fixtures.traceID,
            spanID: SpanID(1),
            name: "capture",
            start: Fixtures.epoch,
            end: Fixtures.epoch.addingTimeInterval(1.5),
            status: .ok,
            attributes: ["memo.id": "abc", "segments": 3]
          ))
      ])
  }

  @Test func withSpanNestsChildrenUnderTheirParent() async throws {
    let (tracer, buffer, _) = makeTracer()
    let trace = Fixtures.traceID
    let value = await tracer.withSpan("capture", traceID: trace) { parent in
      await tracer.withSpan("segment.upload", traceID: trace, parent: parent.spanID) { _ in 42 }
    }
    #expect(value == 42)

    let spans = await buffer.drain(max: 10).entries.compactMap { entry -> SpanRecord? in
      guard case .span(let span) = entry else { return nil }
      return span
    }
    #expect(spans.map(\.name) == ["segment.upload", "capture"])
    #expect(spans.map(\.spanID) == [SpanID(2), SpanID(1)])
    #expect(spans.first?.parentSpanID == SpanID(1))
    #expect(spans.last?.parentSpanID == nil)
  }

  @Test func withSpanMarksErrorsAndRethrows() async throws {
    let (tracer, buffer, _) = makeTracer()
    await #expect(throws: TestError.boom) {
      try await tracer.withSpan("play", traceID: Fixtures.traceID) { _ -> Int in throw TestError.boom }
    }

    let entry = try #require(await buffer.drain(max: 1).entries.first)
    guard case .span(let span) = entry else {
      Issue.record("expected a span")
      return
    }
    #expect(span.status == .error)
    #expect(span.attributes["error.type"] == "TestError")
  }

  @Test func logStampsTheClockAndTrace() async {
    let (tracer, buffer, clock) = makeTracer()
    await clock.advance(by: .seconds(2))
    await tracer.log("outbox.retry", severity: .warn, traceID: Fixtures.traceID, attributes: ["attempt": 2])

    let drain = await buffer.drain(max: 1)
    #expect(
      drain.entries == [
        .log(
          LogRecord(
            timestamp: Fixtures.epoch.addingTimeInterval(2),
            severity: .warn,
            body: "outbox.retry",
            traceID: Fixtures.traceID,
            attributes: ["attempt": 2]
          ))
      ])
  }
}
