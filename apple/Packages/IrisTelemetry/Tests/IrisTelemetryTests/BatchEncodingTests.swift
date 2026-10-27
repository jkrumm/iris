import Foundation
import Testing

@testable import IrisTelemetry

struct BatchEncodingTests {
  @Test func goldenBatchJSON() throws {
    let span = SpanRecord(
      traceID: Fixtures.traceID,
      spanID: SpanID(1),
      parentSpanID: SpanID(0xabc),
      name: "segment.upload",
      start: Fixtures.epoch.addingTimeInterval(0.25),
      end: Fixtures.epoch.addingTimeInterval(1.5),
      status: .error,
      attributes: ["attempt": 2, "cached": false, "ratio": 0.5, "route": "audio/m4a"]
    )
    let rootSpan = SpanRecord(
      traceID: Fixtures.traceID,
      spanID: SpanID(2),
      name: "capture",
      start: Fixtures.epoch,
      end: Fixtures.epoch.addingTimeInterval(2)
    )
    let log = LogRecord(
      timestamp: Fixtures.epoch.addingTimeInterval(0.5),
      severity: .warn,
      body: "outbox.retry",
      traceID: Fixtures.traceID,
      attributes: ["memo.id": "x"]
    )
    let batch = TelemetryBatch(resource: Fixtures.resource, spans: [span, rootSpan], logs: [log], dropped: 3)

    let json = try #require(String(data: try batch.jsonData(), encoding: .utf8))

    let trace = "0f8fad5bd9cb469fa16570867728950e"
    let expected =
      #"{"dropped":3,"#
      + #""logs":[{"attributes":{"memo.id":"x"},"body":"outbox.retry","severity":"warn","#
      + #""timestamp":"2023-11-14T22:13:20.500Z","traceId":"\#(trace)"}],"#
      + #""resource":{"appVersion":"1.2.3","deviceName":"Test iPhone","serviceName":"iris-ios"},"#
      + #""spans":[{"attributes":{"attempt":2,"cached":false,"ratio":0.5,"route":"audio/m4a"},"#
      + #""endTime":"2023-11-14T22:13:21.500Z","name":"segment.upload","parentSpanId":"0000000000000abc","#
      + #""spanId":"0000000000000001","startTime":"2023-11-14T22:13:20.250Z","status":"error","#
      + #""traceId":"\#(trace)"},"#
      + #"{"attributes":{},"endTime":"2023-11-14T22:13:22.000Z","name":"capture","#
      + #""spanId":"0000000000000002","startTime":"2023-11-14T22:13:20.000Z","status":"ok","#
      + #""traceId":"\#(trace)"}]}"#
    #expect(json == expected)
  }

  @Test func macOSServiceName() throws {
    let resource = TelemetryResource(serviceName: .macos, deviceName: "Mac", appVersion: "1")
    let json = try #require(String(data: try TelemetryBatch(resource: resource).jsonData(), encoding: .utf8))
    #expect(json.contains(#""serviceName":"iris-macos""#))
  }

  @Test func emptyBatchHasEmptyListsAndZeroDropped() throws {
    let json = try #require(String(data: try TelemetryBatch(resource: Fixtures.resource).jsonData(), encoding: .utf8))
    #expect(json.contains(#""spans":[]"#))
    #expect(json.contains(#""logs":[]"#))
    #expect(json.contains(#""dropped":0"#))
  }

  @Test func drainSplitsIntoSpansAndLogsInBufferOrder() {
    let drain = TelemetryDrain(
      items: [
        StoredEntry(sequence: 1, entry: .span(Fixtures.span(1))),
        StoredEntry(sequence: 2, entry: .log(Fixtures.log(2))),
        StoredEntry(sequence: 3, entry: .span(Fixtures.span(3))),
      ],
      dropped: 4
    )
    let batch = TelemetryBatch(resource: Fixtures.resource, drain: drain)
    #expect(batch.spans.map(\.name) == ["span.1", "span.3"])
    #expect(batch.logs.map(\.body) == ["log.2"])
    #expect(batch.dropped == 4)
  }
}
