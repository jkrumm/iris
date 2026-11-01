import Foundation
import IrisCapture
import IrisTelemetry
import os

/// A reason the relay cannot send yet; the exporter keeps the records and tries again later.
nonisolated enum TelemetryRelayError: Error {
  case notConnected
}

/// Posts to the server saved in Settings. Reads the connection at every send, so a changed server or token is followed and a
/// device with nothing saved keeps its records (in the crash file) until there is somewhere to send them.
///
/// A record is bound to the server it was recorded for (`server.id`, set when the connection changes). One bound to another
/// server is dropped and counted in `dropped`: the records of server A are not for server B, and holding them would block the
/// queue behind them for ever. While the current server is unreachable nothing is dropped: the send throws and the batch stays.
/// A record with no `server.id` was recorded before any connection existed and goes to the first server there is.
nonisolated struct CredentialedTelemetryTransport: TelemetryTransport {
  typealias Sender = @Sendable (_ server: URL, _ token: String, _ batch: TelemetryBatch) async throws -> Void

  let credentials: any CredentialStore
  var sender: Sender = { server, token, batch in
    try await URLSessionTelemetryTransport(baseURL: server, bearerToken: token).send(batch)
  }

  func send(_ batch: TelemetryBatch) async throws {
    guard let saved = credentials.load() else { throw TelemetryRelayError.notConnected }
    let current = TelemetryBootstrap.serverID(saved.serverURL)
    var mine = batch
    mine.logs = batch.logs.filter { Self.isFor(current, $0.attributes) }
    mine.spans = batch.spans.filter { Self.isFor(current, $0.attributes) }
    // What is left behind is counted in `dropped`, so the server sees a gap instead of nothing. The count rides on this send; if
    // the send fails the exporter puts the whole batch back and the next attempt counts it again, so it is never reported twice.
    let leftBehind = (batch.logs.count - mine.logs.count) + (batch.spans.count - mine.spans.count)
    mine.dropped = batch.dropped + leftBehind
    guard !mine.logs.isEmpty || !mine.spans.isEmpty || mine.dropped > 0 else { return }
    try await sender(saved.serverURL, saved.token, mine)
  }

  private static func isFor(_ server: String, _ attributes: [String: AttributeValue]) -> Bool {
    guard case .string(let bound)? = attributes["server.id"] else { return true }
    return bound == server
  }
}

/// `-IrisFakeCapture`: no network. With `-IrisTelemetryDump <file>` every batch is appended to that file as one JSON line (the
/// body `POST /v1/telemetry` would carry), so a simulator run can be read back and checked against the server's schema.
nonisolated struct DumpTelemetryTransport: TelemetryTransport {
  let fileURL: URL?

  func send(_ batch: TelemetryBatch) async throws {
    guard let fileURL else { return }
    var line = try batch.jsonData()
    line.append(0x0A)
    if let handle = try? FileHandle(forWritingTo: fileURL) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } else {
      try line.write(to: fileURL)
    }
  }
}

/// Builds the pieces of ``DeviceLog``: the crash file, the transport, the resource attributes.
nonisolated enum TelemetryBootstrap {
  /// The batch limit is 500 records; the buffer keeps well more than a long take writes in the 5 minutes the relay may back off.
  static let capacity = 2_000

  static func makeDeviceLog(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    credentials: any CredentialStore = KeychainCredentialStore(),
    bundle: Bundle = .main
  ) -> DeviceLog {
    let fake = FakeCapture.isRequested(arguments: arguments)
    let store: any TelemetryStore =
      fake
      ? InMemoryTelemetryStore()
      : FileTelemetryStore(
        fileURL: URL.applicationSupportDirectory.appending(path: "Iris/telemetry.jsonl", directoryHint: .notDirectory))
    let transport: any TelemetryTransport =
      fake
      ? DumpTelemetryTransport(fileURL: value(of: "-IrisTelemetryDump", in: arguments).map { URL(fileURLWithPath: $0) })
      : CredentialedTelemetryTransport(credentials: credentials)
    let buffer = TelemetryBuffer(capacity: capacity, store: store)
    let resource = TelemetryResource(
      serviceName: .ios, deviceName: fake ? "Simulator" : deviceName(), appVersion: buildSHA(bundle))
    let exporter = RelayExporter(buffer: buffer, transport: transport, resource: resource)
    let events = DeviceEventLog(buffer: buffer, console: DeviceConsole.write)
    if !fake, let server = credentials.load()?.serverURL { events.setAmbient("server.id", .string(serverID(server))) }
    // A simulator run must not read or write the real install's last-phase marker.
    return DeviceLog(
      events: events, exporter: exporter, suiteName: fake ? "com.jkrumm.iris.telemetry.fake" : nil)
  }

  /// A short stable id of a server, so a record can say which one it is for without carrying the address. Case and a trailing
  /// slash of the scheme and host do not matter, the path does (``ConnectionCredentials/normalizedAddress(of:)``).
  static func serverID(_ url: URL) -> String {
    DeviceEventLog.hashed(ConnectionCredentials.normalizedAddress(of: url))
  }

  /// The git sha of the build (`IRIS_BUILD_SHA`, passed by the device build), or `dev`.
  static func buildSHA(_ bundle: Bundle) -> String {
    let value = bundle.object(forInfoDictionaryKey: "IrisBuildSHA") as? String
    guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return "dev" }
    return value
  }

  private static func deviceName() -> String {
    ProcessInfo.processInfo.hostName.replacing(".local", with: "")
  }

  private static func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }
}
