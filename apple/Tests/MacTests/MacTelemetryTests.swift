import Foundation
import IrisCapture
import IrisCore
import IrisTelemetry
import Testing

@testable import IrisMac

/// The Mac's take, panel, banners and queue actions as `iris-macos` device records.
@MainActor
@Suite("Mac telemetry")
struct MacTelemetryTests {
  private static let finished = "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34"

  /// A fake-mode log that dumps every batch to a file, and the records read back from it.
  private struct Dump {
    let file = FileManager.default.temporaryDirectory.appending(path: "iris-mac-dump-\(UUID().uuidString).jsonl")
    let log: DeviceLog

    init() {
      log = MacTelemetry.makeDeviceLog(fake: true, credentials: InMemoryCredentialStore(), dump: file)
    }

    func batches() async -> [[String: Any]] {
      await log.flush()
      defer { try? FileManager.default.removeItem(at: file) }
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
      return text.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
      }
    }

    func records() async -> [[String: Any]] {
      await batches().flatMap { $0["logs"] as? [[String: Any]] ?? [] }
    }

    func text() async -> String {
      await log.flush()
      defer { try? FileManager.default.removeItem(at: file) }
      return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }
  }

  private func attributes(_ record: [String: Any]) -> [String: Any] { record["attributes"] as? [String: Any] ?? [:] }

  private func named(_ name: String, in records: [[String: Any]]) -> [[String: Any]] {
    records.filter { attributes($0)["event.name"] as? String == name }
  }

  private func root(_ dump: Dump, extra: [String] = []) -> MacCompositionRoot {
    MacCompositionRoot(
      arguments: [MacCompositionRoot.fakeDataArgument] + extra, credentials: InMemoryCredentialStore(),
      poster: RecordingNotificationPoster(), log: dump.log)
  }

  @Test("the records are the Mac's: service.name is iris-macos")
  func serviceName() async {
    let dump = Dump()
    dump.log.event("app.lifecycle", ["phase": "launch"])
    let resource = await dump.batches().first?["resource"] as? [String: Any]
    #expect(resource?["serviceName"] as? String == "iris-macos")
  }

  @Test("capture events join the take's trace by the memo id without dashes, and name the control that asked")
  func captureEvents() async {
    let dump = Dump()
    let events = DeviceLogCaptureEvents(log: dump.log)
    let memo = UUID()
    dump.log.commandSource = "hotkey"
    events.event("take.phase", memoID: memo, ["phase": "starting"])
    events.event("capture.segment.closed", memoID: memo, ["index": 0])
    events.event("take.phase", memoID: memo, ["phase": "stopped"])
    let records = await dump.records()
    let trace = memo.uuidString.lowercased().replacing("-", with: "")
    #expect(records.map { $0["traceId"] as? String } == [trace, trace, trace])
    #expect(attributes(records[0])["source"] as? String == "hotkey")
  }

  @Test(
    "a take through the panel writes mac.panel records, with the control that asked and a failure's name, not its sentence"
  )
  func panelRecords() async {
    let dump = Dump()
    let root = root(dump)
    root.recording.toggle()
    await root.recording.settled()
    #expect(dump.log.commandSource == "hotkey")
    root.recording.stop()
    await root.recording.settled()
    #expect(dump.log.commandSource == "panel")
    let phases = named("mac.panel", in: await dump.records()).map { attributes($0)["phase"] as? String }
    #expect(phases == ["starting", "recording", "stopping", "idle"])
  }

  @Test("a refused microphone records which failure it was")
  func failureName() async {
    let dump = Dump()
    let root = MacCompositionRoot(
      arguments: [MacCompositionRoot.fakeDataArgument], credentials: InMemoryCredentialStore(),
      poster: RecordingNotificationPoster(), permission: FakeMicrophonePermission(.denied), log: dump.log)
    root.recording.toggle()
    await root.recording.settled()
    let failed = named("mac.panel", in: await dump.records()).last.map(attributes)
    #expect(failed?["phase"] as? String == "failed" && failed?["failure"] as? String == "microphoneDenied")
    #expect(!(await dump.text()).contains("may not use the microphone"))
  }

  @Test("a banner is a notify.mac record on the memo's trace, with its kind and no words of the memo")
  func bannerRecords() async throws {
    let dump = Dump()
    let root = root(dump)
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    let before = try #require(await root.fakeAPI?.memo(id: Self.finished).memo)
    try await root.fakeAPI?.advance(Self.finished, to: .acted)
    try await root.fakeAPI?.advance(Self.finished, to: .notified)
    var posted: [[String: Any]] = []
    #expect(
      await eventually {
        posted = self.named("notify.mac", in: await dump.records())
        return !posted.isEmpty
      })
    let record = try #require(posted.first)
    #expect(attributes(record)["action"] as? String == "posted" && attributes(record)["kind"] as? String == "done")
    #expect(record["traceId"] as? String == Self.finished.replacing("-", with: ""))
    // Nothing the memo said, and no banner text, reaches a record.
    let everything = await dump.text()
    for words in [before.transcript, before.summary?.headline, before.replyText].compactMap({ $0 })
    where words.count > 8 {
      #expect(!everything.contains(words.prefix(24)))
    }
  }

  @Test("Retry now and Discard are outbox.user_action records on the item's trace")
  func outboxActions() async throws {
    let dump = Dump()
    let root = root(dump, extra: [MacCompositionRoot.stalledArgument])
    await root.outbox.refresh()
    let item = try #require(root.outbox.stalled.first)
    await root.outbox.retry(item)
    await root.outbox.discard(item)
    let actions = named("outbox.user_action", in: await dump.records())
    #expect(actions.map { attributes($0)["action"] as? String } == ["retry", "discard"])
    #expect(actions.allSatisfy { $0["traceId"] as? String == item.id.replacing("-", with: "") })
    #expect(attributes(actions[0])["kind"] as? String == "voiceMemo")
  }

  @Test("the launch is recorded")
  func launch() async {
    let dump = Dump()
    root(dump).startTelemetry()
    let launch = named("app.lifecycle", in: await dump.records())
    #expect(launch.map { attributes($0)["phase"] as? String } == ["launch"])
  }

  @Test("an input switch is recorded without the device's id or name")
  func inputSwitch() async throws {
    let events = RecordingCaptureEvents()
    let devices = FakeAudioDeviceDirectory()
    let inner = DirectoryRouteManager(directory: devices, suiteName: "iris.mac.tests.\(UUID().uuidString)")
    let routes = RecoveringRouteManager(inner, store: InMemoryInputRecoveryStore(), events: events)
    try await routes.setPreferredInput(uid: FakeAudioDeviceDirectory.usb.uid)
    try await routes.setPreferredInput(uid: nil)
    let entries = events.entries(named: "audio.input_switch")
    #expect(entries.map { $0.attributes["action"] } == ["pick", "restore"])
    let flattened = entries.flatMap { $0.attributes.values.map { "\($0)" } }.joined()
    #expect(!flattened.contains(FakeAudioDeviceDirectory.usb.uid) && !flattened.contains("USB Microphone"))
  }

  @Test("the attribute values the Mac writes for its enums are spelled out, not derived from the case names")
  func enumNames() {
    #expect(
      [Announcement.done, .needsRoute, .failed].map(\.telemetryName) == ["done", "needsRoute", "failed"])
    #expect(
      [MacLifecyclePhase.launch, .quit].map(\.telemetryName) == ["launch", "quit"])
    #expect(
      [QueuedItem.Kind.voiceMemo, .voiceReply, .typedMemo, .chatMessage, .textReply, .removal].map(\.telemetryName)
        == ["voiceMemo", "voiceReply", "typedMemo", "chatMessage", "textReply", "removal"])
    let failures: [RecordingPanelModel.Failure] = [
      .notConfigured, .microphoneDenied, .couldNotStart, .nothingRecorded, .stoppedEarly, .lost,
    ]
    #expect(
      failures.map(\.telemetryName)
        == ["notConfigured", "microphoneDenied", "couldNotStart", "nothingRecorded", "stoppedEarly", "lost"])
    #expect(
      [RecoveringRouteManager.Recovery.none, .dropped, .restored, .failed, .pending].map(\.telemetryName)
        == ["none", "dropped", "restored", "failed", "pending"])
  }
}
