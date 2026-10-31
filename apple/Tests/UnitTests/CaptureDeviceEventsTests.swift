import Foundation
import IrisCapture
import IrisTelemetry
import Testing

@testable import Iris

/// A throwaway log that dumps to a file, and the records read back from it.
private struct Dump {
  let file = FileManager.default.temporaryDirectory.appending(path: "iris-dump-\(UUID().uuidString).jsonl")
  let log: DeviceLog

  init() {
    log = TelemetryBootstrap.makeDeviceLog(arguments: ["-IrisFakeCapture", "-IrisTelemetryDump", file.path])
  }

  func records() async throws -> [[String: Any]] {
    await log.flush()
    defer { try? FileManager.default.removeItem(at: file) }
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    return try text.split(separator: "\n").flatMap { line -> [[String: Any]] in
      let batch = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      return batch?["logs"] as? [[String: Any]] ?? []
    }
  }
}

private func attributes(_ record: [String: Any]) -> [String: Any] { record["attributes"] as? [String: Any] ?? [:] }

private struct ScriptedUploader: SegmentUploader {
  var failure: (any Error)?
  func create(_ item: OutboxItem) async throws {}
  func upload(_ segment: ClosedSegment) async throws { if let failure { throw failure } }
  func complete(memoID: MemoID, segmentCount: Int) async throws { if let failure { throw failure } }
  func delete(memoID: MemoID) async throws {}
}

@Suite("Capture device events")
struct CaptureDeviceEventsTests {
  private let segment = ClosedSegment(
    memoID: UUID(), index: 2, fileURL: URL(fileURLWithPath: "/tmp/x.m4a"), byteCount: 100, duration: 10)

  @Test("take.phase carries the control that asked, and events below the take join its memo")
  func sourceAndMemo() async throws {
    let dump = Dump()
    let events = DeviceLogCaptureEvents(log: dump.log)
    let memo = UUID()
    dump.log.commandSource = "island"
    events.event("take.phase", memoID: memo, ["phase": "starting"])
    events.event(
      "capture.session.error", memoID: nil, error: true, ["call": "setActive", "error.code": 561_145_187])
    events.event("take.phase", memoID: memo, ["phase": "stopped"])
    events.event("audio.route_change", memoID: nil, error: false, ["reason": "override"])

    let records = try await dump.records()
    #expect(
      records.map { attributes($0)["event.name"] as? String } == [
        "take.phase", "capture.session.error", "take.phase", "audio.route_change",
      ])
    #expect(attributes(records[0])["source"] as? String == "island")
    #expect(records[1]["traceId"] as? String == memo.uuidString.lowercased().replacing("-", with: ""))
    #expect(records[1]["severity"] as? String == "error")
    #expect(attributes(records[1])["error.code"] as? Int == 561_145_187)
    #expect(records[3]["traceId"] == nil, "the take is over: later events belong to no memo")
  }

  @Test("an upload is a line with its index, attempt, status and duration")
  func uploadSucceeds() async throws {
    let dump = Dump()
    let uploader = ObservedSegmentUploader(ScriptedUploader(), log: dump.log)
    try await uploader.upload(segment)
    try await uploader.complete(memoID: segment.memoID, segmentCount: 3)

    let records = try await dump.records()
    let upload = attributes(records[0])
    #expect(upload["event.name"] as? String == "outbox.segment.upload")
    #expect(upload["index"] as? Int == 2)
    #expect(upload["attempt"] as? Int == 1)
    #expect(upload["status"] as? String == "ok")
    #expect(upload["ms"] is Int)
    #expect(attributes(records[1])["segment_count"] as? Int == 3)
    #expect(records[0]["traceId"] as? String == segment.memoID.wireID.replacing("-", with: ""))
  }

  @Test("a failed upload is a warning with the error and the attempt count, and still throws")
  func uploadFails() async throws {
    let dump = Dump()
    let uploader = ObservedSegmentUploader(
      ScriptedUploader(failure: PermanentTransferError("the server refused the segment")), log: dump.log)
    for _ in 1...2 { await #expect(throws: PermanentTransferError.self) { try await uploader.upload(segment) } }

    let records = try await dump.records()
    #expect(records.map { attributes($0)["attempt"] as? Int } == [1, 2])
    #expect(records.allSatisfy { $0["severity"] as? String == "warn" })
    #expect(attributes(records[0])["status"] as? String == "permanent")
    #expect(attributes(records[0])["error"] as? String == "PermanentTransferError")
    let wire = String(describing: records)
    #expect(!wire.contains("refused"), "the server's own words never reach a record")
  }
}
