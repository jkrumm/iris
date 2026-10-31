import Foundation
import IrisTelemetry
import Synchronization
import Testing

@testable import Iris

@Suite("Telemetry bound to its server")
struct ServerBindingTests {
  private final class Sent: Sendable {
    private let batches = Mutex<[(URL, TelemetryBatch)]>([])
    var sender: CredentialedTelemetryTransport.Sender {
      { url, _, batch in self.batches.withLock { $0.append((url, batch)) } }
    }
    var all: [(URL, TelemetryBatch)] { batches.withLock { $0 } }
  }

  private let a = URL(string: "https://a.example.com")!
  private let b = URL(string: "https://b.example.com")!

  private func record(_ body: String, server: URL?) -> LogRecord {
    var attributes: [String: AttributeValue] = [:]
    if let server { attributes["server.id"] = .string(TelemetryBootstrap.serverID(server)) }
    return LogRecord(timestamp: Date(), body: body, attributes: attributes)
  }

  private func credentials(_ url: URL) -> InMemoryCredentialStore {
    InMemoryCredentialStore(ConnectionCredentials(urlText: url.absoluteString, token: "test-token"))
  }

  @Test("a queue written for server A is not delivered to server B after a switch")
  func switchDropsTheOldQueue() async throws {
    let store = credentials(b)
    let sent = Sent()
    let transport = CredentialedTelemetryTransport(credentials: store, sender: sent.sender)
    let batch = TelemetryBatch(
      resource: TelemetryResource(serviceName: .ios, deviceName: "x", appVersion: "dev"),
      logs: [record("for-a", server: a), record("for-b", server: b), record("before-any-server", server: nil)])

    try await transport.send(batch)

    #expect(sent.all.count == 1)
    #expect(sent.all.first?.0 == b)
    #expect(sent.all.first?.1.logs.map(\.body) == ["for-b", "before-any-server"])
  }

  @Test("a batch with nothing for the current server is acknowledged without a request")
  func nothingForThisServer() async throws {
    let sent = Sent()
    let transport = CredentialedTelemetryTransport(credentials: credentials(b), sender: sent.sender)
    try await transport.send(
      TelemetryBatch(
        resource: TelemetryResource(serviceName: .ios, deviceName: "x", appVersion: "dev"),
        logs: [record("for-a", server: a)]))
    #expect(sent.all.isEmpty)
  }

  @Test("the id is stable, does not carry the address and ignores case and a trailing slash")
  func serverIDIsStable() {
    let id = TelemetryBootstrap.serverID(URL(string: "https://A.example.com/")!)
    #expect(id == TelemetryBootstrap.serverID(URL(string: "https://a.example.com")!))
    #expect(!id.contains("example"))
    #expect(id != TelemetryBootstrap.serverID(b))
  }

  @Test("a connection change binds the records after it to the new server")
  func connectionChangeSetsTheAmbientId() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "iris-dump-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    let log = TelemetryBootstrap.makeDeviceLog(arguments: ["-IrisFakeCapture", "-IrisTelemetryDump", file.path])
    log.serverChanged(a)
    log.event("one")
    log.serverChanged(b)
    log.event("two")
    await log.flush()

    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains(TelemetryBootstrap.serverID(a)))
    #expect(text.contains(TelemetryBootstrap.serverID(b)))
  }
}
