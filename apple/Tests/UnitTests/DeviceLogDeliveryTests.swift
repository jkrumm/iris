import Foundation
import IrisCapture
import IrisTelemetry
import Synchronization
import Testing

@testable import Iris

/// A send that never answers but ends when cancelled, like `URLSession`.
private struct HangingTransport: TelemetryTransport {
  func send(_ batch: TelemetryBatch) async throws {
    try await Task.sleep(for: .seconds(3600))
  }
}

@Suite("DeviceLog delivery and sources")
struct DeviceLogDeliveryTests {
  @Test("a flush on backgrounding ends at its budget when the send never answers")
  func hungSendIsBounded() async throws {
    let buffer = TelemetryBuffer(capacity: 10)
    let resource = TelemetryResource(serviceName: .ios, deviceName: "x", appVersion: "dev")
    let exporter = RelayExporter(
      buffer: buffer, transport: HangingTransport(), resource: resource, sendTimeout: .seconds(3600))
    let log = DeviceLog(
      events: DeviceEventLog(buffer: buffer), exporter: exporter,
      suiteName: "com.jkrumm.iris.tests.\(UUID().uuidString)")
    log.event("app.lifecycle", ["scene.phase": "background"])

    let started = ContinuousClock.now
    await log.flush(within: .milliseconds(100))

    #expect(ContinuousClock.now - started < .seconds(5))
    #expect(await buffer.pendingCount == 1, "the record is kept for the next flush")
  }

  @Test("a command source explains the phases that follow it, then gives way to system")
  func commandSourceGoesStale() {
    let now = Mutex(ContinuousClock.now)
    let box = CommandSourceBox(now: { now.withLock { $0 } })
    #expect(box.current() == CommandSource.system, "no command yet")

    box.set("intent")
    now.withLock { $0 += .seconds(10) }
    #expect(box.current() == "intent")

    box.set("island")
    #expect(box.current() == "island", "the last command wins")

    now.withLock { $0 += CommandSource.freshness + .seconds(1) }
    #expect(box.current() == CommandSource.system, "a failure minutes later is not the island's press")
  }

  @Test("a set-aside m4a is inspected for its moov atom, anything else is not")
  func quarantineInspection() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let finished = directory.appending(path: "a.m4a")
    let torn = directory.appending(path: "b.m4a")
    let queue = directory.appending(path: "outbox.json")
    try Data("ftypM4A moov data".utf8).write(to: finished)
    try Data("ftypM4A mdat only".utf8).write(to: torn)
    try Data("moov".utf8).write(to: queue)

    func moov(_ url: URL) -> AttributeValue? {
      QuarantineInspector.attributes(of: SetAsideFile(url: url, byteCount: 4, modifiedAt: nil))["has_moov"]
    }
    #expect(moov(finished) == true)
    #expect(moov(torn) == false)
    #expect(moov(queue) == false, "only recordings are inspected")
  }

  private func isolatedLog(_ buffer: TelemetryBuffer, suite: String = "com.jkrumm.iris.tests.\(UUID().uuidString)")
    -> DeviceLog
  {
    let resource = TelemetryResource(serviceName: .ios, deviceName: "x", appVersion: "dev")
    let exporter = RelayExporter(buffer: buffer, transport: HangingTransport(), resource: resource)
    return DeviceLog(events: DeviceEventLog(buffer: buffer), exporter: exporter, suiteName: suite)
  }

  @Test("recording the quarantine emits one record per file with the name, never a path")
  func quarantineRecords() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "iris-dump-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    let log = TelemetryBootstrap.makeDeviceLog(arguments: ["-IrisFakeCapture", "-IrisTelemetryDump", file.path])
    let gone = URL(fileURLWithPath: "/nonexistent/dir/\(UUID().uuidString).m4a")
    await log.recordQuarantine([SetAsideFile(url: gone, byteCount: 12, modifiedAt: nil)])
    await log.flush()

    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("capture.quarantine"))
    #expect(text.contains(gone.lastPathComponent))
    #expect(!text.contains("/nonexistent"))
  }

  private func record(_ files: [SetAsideFile], in log: DeviceLog) async {
    await log.recordQuarantine(files)
    await log.events.settle()
  }

  @Test("a launch that finds the same set-aside files again logs no per-file warning; a new file is logged once")
  func quarantineIsLoggedOnce() async {
    let suite = "com.jkrumm.iris.tests.\(UUID().uuidString)"
    let old = [
      SetAsideFile(url: URL(fileURLWithPath: "/q/a.m4a"), byteCount: 1, modifiedAt: nil),
      SetAsideFile(url: URL(fileURLWithPath: "/q/b.m4a"), byteCount: 2, modifiedAt: nil),
    ]
    let first = TelemetryBuffer(capacity: 10)
    await record(old, in: isolatedLog(first, suite: suite))
    #expect(await first.pendingCount == 2, "the launch that sets them aside reports each")

    let second = TelemetryBuffer(capacity: 10)
    let relaunch = isolatedLog(second, suite: suite)
    await record(old, in: relaunch)
    #expect(await second.pendingCount == 0, "the second launch with the same files warns about none")

    let fresh = SetAsideFile(url: URL(fileURLWithPath: "/q/c.m4a"), byteCount: 3, modifiedAt: nil)
    await record(old + [fresh], in: relaunch)
    #expect(await second.pendingCount == 1, "only the file that is new")
    await record(old + [fresh], in: relaunch)
    #expect(await second.pendingCount == 1, "and not again")
  }
}
