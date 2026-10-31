import Foundation
import IrisCapture
import IrisTelemetry

/// The Mac app's device log: the iPhone's `DeviceLog` (compiled in as it is) built for `service.name=iris-macos`.
///
/// `TelemetryBootstrap.makeDeviceLog` is the iPhone's recipe and says `iris-ios`; this is the same recipe with the Mac's
/// resource. Records are buffered through the crash file in the app container and relayed to `POST /v1/telemetry` over the saved
/// connection (`CredentialedTelemetryTransport`: a record is bound to the server it was recorded for, a switch drops the others).
/// Under `-IrisFakeData` nothing leaves the process: the records stay in memory, and `dump` (tests) appends every batch to a file.
nonisolated enum MacTelemetry {
  static func makeDeviceLog(
    fake: Bool, credentials: any CredentialStore, bundle: Bundle = .main, dump: URL? = nil, directory: URL? = nil
  ) -> DeviceLog {
    let store: any TelemetryStore =
      fake
      ? InMemoryTelemetryStore()
      : FileTelemetryStore(
        fileURL: (directory ?? URL.applicationSupportDirectory.appending(path: "Iris", directoryHint: .isDirectory))
          .appending(path: "telemetry.jsonl", directoryHint: .notDirectory))
    let transport: any TelemetryTransport =
      fake ? DumpTelemetryTransport(fileURL: dump) : CredentialedTelemetryTransport(credentials: credentials)
    let buffer = TelemetryBuffer(capacity: TelemetryBootstrap.capacity, store: store)
    let resource = TelemetryResource(
      serviceName: .macos, deviceName: fake ? "Mac" : deviceName(), appVersion: TelemetryBootstrap.buildSHA(bundle))
    let exporter = RelayExporter(buffer: buffer, transport: transport, resource: resource)
    let events = DeviceEventLog(buffer: buffer, console: DeviceConsole.write)
    if !fake, let server = credentials.load()?.serverURL {
      events.setAmbient("server.id", .string(TelemetryBootstrap.serverID(server)))
    }
    // A fake run must not read or write the real install's last-phase marker.
    return DeviceLog(events: events, exporter: exporter, suiteName: fake ? "com.jkrumm.iris.telemetry.fake.mac" : nil)
  }

  private static func deviceName() -> String {
    ProcessInfo.processInfo.hostName.replacing(".local", with: "")
  }
}

/// The Mac-only records, all through ``DeviceLog``. Names are `area.thing`; attributes are enums and counts, never a transcript,
/// reply, park reason, token, URL or device uid. The trace id is the memo id without dashes (`DeviceLog.event(memoWireID:)`).
@MainActor
struct MacEvents {
  let log: DeviceLog

  /// `mac.panel`: the recording panel moved to a phase (`idle`, `starting`, `recording`, `stopping`, `failed`) — and, for
  /// `failed`, which kind of failure (the enum's name, not its sentence).
  func panel(phase: String, failure: String? = nil) {
    var attributes: [String: AttributeValue] = ["phase": .string(phase)]
    if let failure { attributes["failure"] = .string(failure) }
    log.event(
      "mac.panel", memoWireID: log.currentTake?.uuidString.lowercased(), severity: failure == nil ? .info : .warn,
      attributes)
  }

  /// `mac.hotkey`: the global key was pressed.
  func hotkey() {
    log.event("mac.hotkey", memoWireID: log.currentTake?.uuidString.lowercased(), [:])
  }

  /// `notify.mac`: a banner for a memo, by what happened to it (`posted`, `withdrawn`, `catchup`) and the kind it announced.
  func notification(_ action: String, memoID: String?, kind: String?, count: Int? = nil, seen: Int? = nil) {
    var attributes: [String: AttributeValue] = ["action": .string(action)]
    if let kind { attributes["kind"] = .string(kind) }
    if let count { attributes["count"] = .int(count) }
    if let seen { attributes["seen"] = .int(seen) }
    log.event("notify.mac", memoWireID: memoID, attributes)
  }

  /// `outbox.user_action`: Retry now or Discard pressed in the panel, for a queued item (its id is the memo id).
  func outboxAction(_ action: String, memoID: String, kind: String, ok: Bool = true) {
    log.event(
      "outbox.user_action", memoWireID: memoID, severity: ok ? .info : .warn,
      ["action": .string(action), "kind": .string(kind), "ok": .bool(ok)])
  }

  /// `app.lifecycle`: launch and quit of the menu-bar app (it has no scene phases).
  func lifecycle(_ phase: String) {
    // A quit is durable: the process is going, and the crash file is what the next launch sends.
    if phase == "quit" {
      log.durableEvent("app.lifecycle", ["phase": .string(phase), "reason": "process"])
    } else {
      log.event("app.lifecycle", ["phase": .string(phase), "reason": "process"])
    }
  }
}
