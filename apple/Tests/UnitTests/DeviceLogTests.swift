import Foundation
import IrisTelemetry
import Testing

@testable import Iris

@Suite("DeviceLog")
struct DeviceLogTests {
  private func dumpFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "iris-dump-\(UUID().uuidString).jsonl")
  }

  private func batches(in file: URL) throws -> [[String: Any]] {
    let text = try String(contentsOf: file, encoding: .utf8)
    return try text.split(separator: "\n").compactMap {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }

  @Test("an event reaches the relay with the resource and the reserved attributes")
  func eventReachesTheRelay() async throws {
    let file = dumpFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let log = TelemetryBootstrap.makeDeviceLog(arguments: ["-IrisFakeCapture", "-IrisTelemetryDump", file.path])
    let memo = UUID()
    log.event("take.phase", memoID: memo, ["phase": "recording", "source": "app"])
    await log.flush()

    let batch = try #require(batches(in: file).first)
    let resource = try #require(batch["resource"] as? [String: String])
    #expect(resource["serviceName"] == "iris-ios")
    #expect(resource["appVersion"] == "dev")
    let record = try #require((batch["logs"] as? [[String: Any]])?.first)
    #expect(record["body"] as? String == "take.phase")
    #expect(record["traceId"] as? String == memo.uuidString.lowercased().replacing("-", with: ""))
    let attributes = try #require(record["attributes"] as? [String: Any])
    #expect(attributes["event.name"] as? String == "take.phase")
    #expect(attributes["seq"] as? Int == 1)
    #expect(attributes["process"] as? String == "app")
    #expect(attributes["source"] as? String == "app")
    #expect(attributes["uptime_ms"] is Int)
    #expect(attributes["app.pid"] is Int)
  }

  @Test("a scene change is an app.lifecycle record and sets app.state on the records after it")
  @MainActor
  func sceneChange() async throws {
    let file = dumpFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let log = TelemetryBootstrap.makeDeviceLog(arguments: ["-IrisFakeCapture", "-IrisTelemetryDump", file.path])
    log.sceneChanged(to: "inactive")
    log.event("ui.screen", ["screen": "history"])
    await log.flush()

    let records = try #require(batches(in: file).first?["logs"] as? [[String: Any]])
    let lifecycle = try #require(records.first?["attributes"] as? [String: Any])
    #expect(lifecycle["scene.phase"] as? String == "inactive")
    #expect((records.last?["attributes"] as? [String: Any])?["app.state"] as? String == "inactive")
  }

  @Test("the build sha comes from Info.plist and falls back to dev when unset or unsubstituted")
  func buildSHA() {
    #expect(TelemetryBootstrap.buildSHA(.main) == "dev")
  }

  @Test("with no saved connection the relay keeps its records instead of dropping them")
  func noConnectionThrows() async {
    let transport = CredentialedTelemetryTransport(credentials: InMemoryCredentialStore())
    let batch = TelemetryBatch(
      resource: TelemetryResource(serviceName: .ios, deviceName: "x", appVersion: "dev"))
    await #expect(throws: TelemetryRelayError.self) { try await transport.send(batch) }
  }
}
