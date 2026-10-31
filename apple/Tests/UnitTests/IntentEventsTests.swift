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

  @Test("Stop, Pause and Switch join the take's trace, before and after the take is gone; a Start joins its new memo")
  @MainActor
  func takeContext() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "iris-dump-\(UUID().uuidString).jsonl")
    let log = TelemetryBootstrap.makeDeviceLog(arguments: ["-IrisFakeCapture", "-IrisTelemetryDump", file.path])
    let sink = DeviceLogIntentSink(log: log)
    let memo = UUID()
    func run(_ name: String) -> IntentRun {
      IntentRun(
        intent: name, process: "com.jkrumm.iris", handlerPresent: true, memoID: nil, mode: "background",
        canContinueInForeground: false, pressLagMilliseconds: nil)
    }

    sink.intentPerformed(run("StartMemoIntent"))
    log.trackTake(memo, phase: .string("starting"))
    sink.intentFinished(intent: "StartMemoIntent", error: nil)
    sink.intentPerformed(run("StopMemoIntent"))
    log.trackTake(memo, phase: .string("stopped"))
    sink.intentFinished(intent: "StopMemoIntent", error: nil)

    let records = try await records(file, after: log)
    let trace = memo.uuidString.lowercased().replacing("-", with: "")
    #expect(records.map { $0["traceId"] as? String } == [nil, trace, trace, trace])
  }

  @Test("an intent's error is its type and case, never the payload")
  func errorSummary() {
    enum Failure: Error { case recordingFailed(String) }
    #expect(
      IntentEvents.summary(of: Failure.recordingFailed("/private/var/mobile/secret.m4a")).hasSuffix(".recordingFailed"))
    #expect(!IntentEvents.summary(of: Failure.recordingFailed("/private/var/mobile/secret.m4a")).contains("secret"))
    #expect(IntentEvents.summary(of: StartMemoError.appNotReady).hasSuffix(".appNotReady"))
  }
}
