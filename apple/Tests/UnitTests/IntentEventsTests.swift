import Foundation
import IrisTelemetry
import Testing

@testable import Iris

@Suite("Intent events")
struct IntentEventsTests {
  private func records(_ file: URL, after log: DeviceLog) async throws -> [[String: Any]] {
    await log.flush()
    defer { try? FileManager.default.removeItem(at: file) }
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    return try text.split(separator: "\n").flatMap { line -> [[String: Any]] in
      let batch = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      return batch?["logs"] as? [[String: Any]] ?? []
    }
  }

  @Test("an intent that found no handler is a perform with handler.present=false and an error result")
  @MainActor
  func appNotReady() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "iris-dump-\(UUID().uuidString).jsonl")
    let log = TelemetryBootstrap.makeDeviceLog(arguments: ["-IrisFakeCapture", "-IrisTelemetryDump", file.path])
    let sink = DeviceLogIntentSink(log: log)
    let memo = UUID().uuidString.lowercased()
    sink.intentPerformed(
      IntentRun(
        intent: "StartMemoIntent", process: "com.jkrumm.iris.widgets", handlerPresent: false, memoID: memo,
        mode: "background", canContinueInForeground: true, pressLagMilliseconds: 40))
    sink.intentFinished(intent: "StartMemoIntent", error: "appNotReady")

    let records = try await records(file, after: log)
    let perform = try #require(records.first?["attributes"] as? [String: Any])
    #expect(perform["event.name"] as? String == "intent.perform")
    #expect(perform["handler.present"] as? Bool == false)
    #expect(perform["process"] as? String == "com.jkrumm.iris.widgets")
    #expect(perform["press_lag_ms"] as? Int == 40)
    #expect(records[0]["traceId"] as? String == memo.replacing("-", with: ""))
    let result = try #require(records.last?["attributes"] as? [String: Any])
    #expect(result["event.name"] as? String == "intent.result")
    #expect(result["ok"] as? Bool == false)
    #expect(result["error"] as? String == "appNotReady")
    #expect(records.last?["severity"] as? String == "error")
  }
}
