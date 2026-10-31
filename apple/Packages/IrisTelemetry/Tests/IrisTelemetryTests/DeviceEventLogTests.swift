import Foundation
import Synchronization
import Testing

@testable import IrisTelemetry

/// Collects console lines; the production console is `os.Logger`.
private final class ConsoleLines: Sendable {
  private let storage = Mutex<[(category: String, line: String)]>([])

  var console: DeviceEventLog.Console {
    { category, _, line in self.storage.withLock { $0.append((category, line)) } }
  }

  var lines: [(category: String, line: String)] { storage.withLock { $0 } }
}

private func makeLog(
  capacity: Int = 1000,
  store: any TelemetryStore = InMemoryTelemetryStore(),
  console: @escaping DeviceEventLog.Console = { _, _, _ in }
) -> (log: DeviceEventLog, buffer: TelemetryBuffer, uptime: Counter) {
  let buffer = TelemetryBuffer(capacity: capacity, store: store)
  let uptime = Counter()
  let log = DeviceEventLog(
    buffer: buffer, clock: ManualClock(), processID: 4242, uptimeMilliseconds: { uptime.next() }, console: console)
  return (log, buffer, uptime)
}

/// 10, 20, 30 ... milliseconds.
private final class Counter: Sendable {
  private let value = Mutex(0)
  func next() -> Int {
    value.withLock { current in
      current += 10; return current
    }
  }
}

private func logs(_ buffer: TelemetryBuffer) async -> [LogRecord] {
  await buffer.drain(max: 1000).entries.compactMap {
    if case .log(let log) = $0 { log } else { nil }
  }
}

struct DeviceEventLogTests {
  @Test func recordCarriesTheReservedAttributesAndTheMemoTrace() async {
    let (log, buffer, _) = makeLog()
    log.setAmbient("app.state", "active")
    log.event("take.phase", memoID: Fixtures.memoID, ["phase": "recording", "mode": "auto"])
    await log.settle()

    let record = try! #require(await logs(buffer).first)
    #expect(record.body == "take.phase")
    #expect(record.traceID == Fixtures.traceID)
    #expect(record.timestamp == Fixtures.epoch)
    #expect(record.attributes["event.name"] == "take.phase")
    #expect(record.attributes["memo.id"] == .string(Fixtures.traceID.hex))
    #expect(record.attributes["seq"] == 1)
    #expect(record.attributes["uptime_ms"] == 10)
    #expect(record.attributes["app.pid"] == 4242)
    #expect(record.attributes["app.state"] == "active")
    #expect(record.attributes["phase"] == "recording")
    #expect(record.attributes["run.id"] == nil)
  }

  @Test func sequenceAndUptimeRiseTogetherInCallOrder() async {
    let (log, buffer, _) = makeLog()
    for index in 0..<50 { log.event("capture.step", ["index": .int(index)]) }
    await log.settle()

    let records = await logs(buffer)
    #expect(records.map { $0.attributes["index"] } == (0..<50).map { .int($0) })
    #expect(records.map { $0.attributes["seq"] } == (1...50).map { .int($0) })
    let uptimes = records.compactMap { record -> Int? in
      if case .int(let value) = record.attributes["uptime_ms"] { value } else { nil }
    }
    #expect(uptimes == uptimes.sorted())
  }

  @Test func concurrentCallersStillGetOrderedSequenceAndUptime() async {
    let (log, buffer, _) = makeLog()
    await withTaskGroup(of: Void.self) { group in
      for caller in 0..<8 {
        group.addTask { for step in 0..<20 { log.event("audio.tick", ["caller": .int(caller), "step": .int(step)]) } }
      }
    }
    await log.settle()

    let records = await logs(buffer)
    #expect(records.count == 160)
    let pairs = records.compactMap { record -> (Int, Int)? in
      guard case .int(let seq) = record.attributes["seq"], case .int(let uptime) = record.attributes["uptime_ms"] else {
        return nil
      }
      return (seq, uptime)
    }
    #expect(pairs.map(\.0) == Array(1...160))
    #expect(pairs.map(\.1) == pairs.map(\.1).sorted())
  }

  @Test func reservedAttributesBeatTheCallers() async {
    let (log, buffer, _) = makeLog()
    log.event("app.launch", ["seq": 999, "app.pid": 1, "event.name": "forged"])
    await log.settle()

    let record = try! #require(await logs(buffer).first)
    #expect(record.attributes["seq"] == 1)
    #expect(record.attributes["app.pid"] == 4242)
    #expect(record.attributes["event.name"] == "app.launch")
  }

  @Test func runIDRidesOnEveryRecordOnceSet() async {
    let (log, buffer, _) = makeLog()
    log.event("ui.screen")
    log.setRunID("  round-7  ")
    log.event("ui.screen")
    log.setRunID("   ")
    log.event("ui.screen")
    await log.settle()

    #expect(await logs(buffer).map { $0.attributes["run.id"] } == [nil, "round-7", nil])
  }

  @Test func everyEventIsAConsoleLineInItsAreaCategory() async {
    let console = ConsoleLines()
    let (log, _, _) = makeLog(console: console.console)
    log.event("audio.route_change", memoID: Fixtures.memoID, ["reason": "newDeviceAvailable"])
    log.event("intent.perform")

    let lines = console.lines
    #expect(lines.map(\.category) == ["audio", "intent"])
    #expect(lines[0].line == "audio.route_change memo=0f8fad5b reason=newDeviceAvailable seq=1 uptime_ms=10")
  }

  @Test func settleWaitsForEverythingRecordedBefore() async {
    let (log, buffer, _) = makeLog(capacity: 100)
    for _ in 0..<200 { log.event("capture.level") }
    await log.settle()
    #expect(await buffer.pendingCount == 100, "capacity 100: all 200 reached the buffer, the oldest were dropped")
    #expect(await buffer.unreportedDropCount == 100)
  }

  @Test func flushOnBackgroundSendsWhatSettleCollected() async {
    let (log, buffer, _) = makeLog()
    let transport = RecordingTransport()
    let exporter = RelayExporter(
      buffer: buffer, transport: transport, resource: Fixtures.resource, clock: ManualClock())
    log.event("app.lifecycle", ["scene.phase": "background"])
    await log.settle()
    await exporter.flushOnBackground()

    let batches = await transport.batches
    #expect(batches.count == 1)
    #expect(batches.first?.logs.map(\.body) == ["app.lifecycle"])
    #expect(batches.first?.resource == Fixtures.resource)
  }

  @Test func aKillLeavesTheRecordsOnDiskAndTheNextLaunchSendsThem() async {
    let file = Fixtures.temporaryFileURL()
    defer { Fixtures.remove(file) }
    do {
      let (log, _, _) = makeLog(store: FileTelemetryStore(fileURL: file))
      log.event("capture.tap.install", memoID: Fixtures.memoID, ["rate": 48000])
      log.event("capture.session.error", memoID: Fixtures.memoID, severity: .error, ["call": "engine.start"])
      await log.settle()
      // The process dies here: no flush, no acknowledge, nothing but what is on disk.
    }

    let relaunchedBuffer = TelemetryBuffer(capacity: 100, store: FileTelemetryStore(fileURL: file))
    let transport = RecordingTransport()
    let exporter = RelayExporter(
      buffer: relaunchedBuffer, transport: transport, resource: Fixtures.resource, clock: ManualClock())
    await exporter.flushOnLaunch()

    let sent = await transport.batches.flatMap(\.logs)
    #expect(sent.map(\.body) == ["capture.tap.install", "capture.session.error"])
    #expect(sent.last?.severity == .error)
    #expect(sent.first?.attributes["rate"] == 48000)
    #expect(sent.allSatisfy { $0.traceID == Fixtures.traceID })
    #expect(await relaunchedBuffer.pendingCount == 0)
    #expect(await FileTelemetryStore(fileURL: file).loadCount == 0, "acknowledged records leave the file")
  }

  @Test func aTornLastLineAfterTheKillDoesNotLoseTheRecordsBeforeIt() async throws {
    let file = Fixtures.temporaryFileURL()
    defer { Fixtures.remove(file) }
    let (log, _, _) = makeLog(store: FileTelemetryStore(fileURL: file))
    log.event("take.phase", ["phase": "recording"])
    await log.settle()
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"sequence":2,"entry":{"kind":"lo"#.utf8))
    try handle.close()

    let buffer = TelemetryBuffer(capacity: 100, store: FileTelemetryStore(fileURL: file))
    await buffer.recover()
    #expect(await logs(buffer).map(\.body) == ["take.phase"])
  }

  @Test func tokensTranscriptsAndRepliesNeverReachARecord() async {
    let console = ConsoleLines()
    let (log, buffer, _) = makeLog(console: console.console)
    log.event(
      "intent.result",
      [
        "ok": true,
        "push_token": "abcdef",
        "Authorization": "Bearer secret",
        "transcript": "hello world",
        "reply_text": "answer",
        "deviceToken": "x",
        "error": .string(String(repeating: "e", count: 1000)),
      ])
    await log.settle()

    let record = try! #require(await logs(buffer).first)
    #expect(record.attributes["ok"] == true)
    for key in ["push_token", "Authorization", "transcript", "reply_text", "deviceToken"] {
      #expect(record.attributes[key] == nil, "\(key) must be dropped")
    }
    if case .string(let text) = record.attributes["error"] {
      #expect(text.count == DeviceEventLog.maxValueLength)
    } else {
      Issue.record("error attribute missing")
    }
    let line = console.lines.map(\.line).joined()
    #expect(!line.contains("secret") && !line.contains("hello world") && !line.contains("abcdef"))
  }

  @Test func hashedIdentifiersAreStableShortAndNotTheInput() {
    let uid = "BuiltInMicrophoneDevice"
    let hash = DeviceEventLog.hashed(uid)
    #expect(hash == DeviceEventLog.hashed(uid))
    #expect(hash.count == 12)
    #expect(!hash.contains(uid))
    #expect(hash != DeviceEventLog.hashed("AnotherDevice"))
  }
}

extension FileTelemetryStore {
  fileprivate var loadCount: Int {
    get async { (try? await load().count) ?? -1 }
  }
}
