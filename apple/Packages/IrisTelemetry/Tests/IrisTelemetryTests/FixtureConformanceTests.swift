import Foundation
import Testing

@testable import IrisTelemetry

/// The repo's `contracts/fixtures` directory, located from this file's path (no bundled resources).
private enum Contracts {
  struct LocationError: Error { let file: String }

  static func fixturesDirectory(from file: String = #filePath) throws -> URL {
    var directory = URL(filePath: file).deletingLastPathComponent()
    while directory.path != "/" {
      let contracts = directory.appending(path: "contracts")
      if FileManager.default.fileExists(atPath: contracts.appending(path: "manifest.json").path) {
        return contracts.appending(path: "fixtures")
      }
      directory.deleteLastPathComponent()
    }
    throw LocationError(file: file)
  }

  static func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixturesDirectory().appending(path: "\(name).json"))
  }

  /// Every fixture whose name is `schema` or `schema.<variant>`.
  static func fixtureNames(schema: String) -> [String] {
    guard let directory = try? fixturesDirectory(),
      let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    return files.filter { $0 == "\(schema).json" || ($0.hasPrefix("\(schema).") && $0.hasSuffix(".json")) }
      .map { String($0.dropLast(".json".count)) }
      .sorted()
  }
}

/// Both sides of `POST /v1/telemetry` against the hand-written contract fixtures: the Swift model must read what the
/// server schema allows and write back exactly what the fixture says.
struct FixtureConformanceTests {
  @Test func fixturesExist() {
    #expect(
      Contracts.fixtureNames(schema: "telemetry.request") == ["telemetry.request", "telemetry.request.logs-only"])
    #expect(Contracts.fixtureNames(schema: "telemetry.response") == ["telemetry.response"])
  }

  @Test(arguments: Contracts.fixtureNames(schema: "telemetry.request"))
  func requestFixtureRoundTrips(_ name: String) throws {
    let original = try Contracts.fixture(name)
    let batch = try TelemetryCoding.makeDecoder().decode(TelemetryBatch.self, from: original)
    let reencoded = try batch.jsonData()

    let expected = try JSONSerialization.jsonObject(with: original) as? NSDictionary
    let actual = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
    #expect(actual != nil && actual == expected)
  }

  @Test func iOSFixtureDecodesToTheModel() throws {
    let batch = try TelemetryCoding.makeDecoder().decode(
      TelemetryBatch.self, from: Contracts.fixture("telemetry.request"))

    #expect(batch.resource == TelemetryResource(serviceName: .ios, deviceName: "Johannes' iPhone", appVersion: "1.0.0"))
    #expect(batch.dropped == 3)
    #expect(batch.spans.map(\.name) == ["capture", "segment.upload"])
    #expect(batch.spans.map(\.parentSpanID?.hex) == [nil, "00000000000000a1"])
    #expect(batch.spans.map(\.status) == [.ok, .error])
    #expect(batch.spans.allSatisfy { $0.traceID.hex == "0f8fad5bd9cb469fa16570867728950e" })
    #expect(batch.spans[0].start == Date(timeIntervalSince1970: 1_793_102_400))
    #expect(batch.spans[1].end == Date(timeIntervalSince1970: 1_793_102_411.75))
    #expect(batch.spans[1].attributes["attempt"] == .int(2))
    #expect(batch.spans[1].attributes["cached"] == .bool(false))
    #expect(batch.spans[1].attributes["ratio"] == .double(0.5))
    #expect(batch.spans[1].attributes["route"] == .string("audio/m4a"))
    #expect(batch.logs.map(\.severity) == [.warn, .info])
    #expect(batch.logs.map(\.traceID?.hex) == ["0f8fad5bd9cb469fa16570867728950e", nil])
  }

  @Test func logsOnlyFixtureIsAMacBatchWithNoSpans() throws {
    let batch = try TelemetryCoding.makeDecoder().decode(
      TelemetryBatch.self, from: Contracts.fixture("telemetry.request.logs-only"))

    #expect(batch.resource.serviceName == .macos)
    #expect(batch.spans.isEmpty)
    #expect(batch.logs.map(\.body) == ["sse.disconnected"])
    #expect(batch.dropped == 0)
  }

  @Test func responseFixtureDecodesToTheReceipt() throws {
    let receipt = try JSONDecoder().decode(TelemetryReceipt.self, from: Contracts.fixture("telemetry.response"))
    #expect(receipt == TelemetryReceipt(accepted: .init(spans: 2, logs: 2)))
  }
}
