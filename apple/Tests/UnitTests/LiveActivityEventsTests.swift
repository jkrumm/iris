import Foundation
import IrisCore
import Testing

@testable import Iris

@Suite("Live Activity events")
struct LiveActivityEventsTests {
  @Test("a take's activity calls are liveactivity records for its memo, in order, and still reach the activity")
  func decoratorRecordsEveryCall() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "iris-dump-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    let log = TelemetryBootstrap.makeDeviceLog(arguments: ["-IrisFakeCapture", "-IrisTelemetryDump", file.path])
    let recording = RecordingLiveActivity()
    let activity = ObservedTakeLiveActivity(recording, log: log)
    let memo = UUID().uuidString.lowercased()

    await activity.start(
      memoID: memo, mode: .auto, startedAt: Date(), state: LiveActivityContentState(phase: .recording, hasReply: false))
    await activity.update(memoID: memo, LiveActivityContentState(phase: .uploading, hasReply: false))
    await activity.end(memoID: memo, finalState: nil, dismissal: .immediate)
    activity.logSnapshot(reason: "foreground")
    await log.flush()

    #expect(recording.starts.count == 1)
    #expect(recording.endedIDs == [memo])
    let text = try String(contentsOf: file, encoding: .utf8)
    let firstLine = try #require(text.split(separator: "\n").first)
    let parsed = try JSONSerialization.jsonObject(with: Data(firstLine.utf8))
    let batch = try #require(parsed as? [String: Any])
    let records = try #require(batch["logs"] as? [[String: Any]])
    let attributes = records.compactMap { $0["attributes"] as? [String: Any] }
    #expect(
      attributes.map { $0["event.name"] as? String } == [
        "liveactivity.request", "liveactivity.update", "liveactivity.end", "liveactivity.snapshot",
      ])
    #expect(attributes.prefix(3).map { $0["phase"] as? String } == ["recording", "uploading", "none"])
    #expect(attributes[2]["dismissal"] as? String == "immediate")
    #expect(attributes[3]["reason"] as? String == "foreground")
    #expect(records.prefix(3).allSatisfy { $0["traceId"] as? String == memo.replacing("-", with: "") })
  }
}
