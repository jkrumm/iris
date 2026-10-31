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

  @Test("a batch with nothing for the current server reports the records it leaves behind as dropped")
  func nothingForThisServer() async throws {
    let sent = Sent()
    let transport = CredentialedTelemetryTransport(credentials: credentials(b), sender: sent.sender)
    try await transport.send(
      TelemetryBatch(
        resource: TelemetryResource(serviceName: .ios, deviceName: "x", appVersion: "dev"),
        logs: [record("for-a", server: a), record("also-for-a", server: a)], dropped: 3))
    #expect(sent.all.count == 1)
    #expect(sent.all.first?.1.logs.isEmpty == true)
    #expect(sent.all.first?.1.dropped == 5, "the overflow count plus the two records of the other server")
  }

  @Test("records left behind for another server are counted once the current server takes the batch")
  func leftBehindIsCounted() async throws {
    let sent = Sent()
    let transport = CredentialedTelemetryTransport(credentials: credentials(b), sender: sent.sender)
    try await transport.send(
      TelemetryBatch(
        resource: TelemetryResource(serviceName: .ios, deviceName: "x", appVersion: "dev"),
        logs: [record("for-a", server: a), record("for-b", server: b)]))
    #expect(sent.all.first?.1.logs.map(\.body) == ["for-b"])
    #expect(sent.all.first?.1.dropped == 1)
  }

  @Test("an unreachable server keeps the whole batch: the send throws and nothing is counted as dropped")
  func unreachableServerKeepsTheBatch() async {
    let transport = CredentialedTelemetryTransport(
      credentials: credentials(b), sender: { _, _, _ in throw URLError(.cannotConnectToHost) })
    await #expect(throws: URLError.self) {
      try await transport.send(
        TelemetryBatch(
          resource: TelemetryResource(serviceName: .ios, deviceName: "x", appVersion: "dev"),
          logs: [record("for-a", server: a), record("for-b", server: b)]))
    }
  }

  @Test("the id is stable, does not carry the address and ignores case and a trailing slash")
  func serverIDIsStable() {
    let id = TelemetryBootstrap.serverID(URL(string: "https://A.example.com/")!)
    #expect(id == TelemetryBootstrap.serverID(URL(string: "https://a.example.com")!))
    #expect(!id.contains("example"))
    #expect(id != TelemetryBootstrap.serverID(b))
  }

  @Test("the id ignores the case of scheme and host but not of the path: /Iris and /iris are two servers")
  func serverIDKeepsThePathCase() {
    let upper = TelemetryBootstrap.serverID(URL(string: "https://proxy.example.com/Iris")!)
    let lower = TelemetryBootstrap.serverID(URL(string: "https://proxy.example.com/iris")!)
    #expect(upper != lower)
    #expect(upper == TelemetryBootstrap.serverID(URL(string: "HTTPS://Proxy.Example.com/Iris/")!))
    #expect(
      ConnectionCredentials(urlText: "https://proxy.example.com/Iris", token: "t")?.serverKey
        != ConnectionCredentials(urlText: "https://proxy.example.com/iris", token: "t")?.serverKey)
  }

  /// A connection whose halves are written apart, with a pause between them: a reader without the gate lands in the pause.
  private final class SplitStorage: ConnectionStorage {
    private let halves = Mutex<(token: String?, url: String?)>((nil, nil))
    func readToken() -> String? { halves.withLock { $0.token } }
    func readURL() -> String? { halves.withLock { $0.url } }
    func write(token: String, url: String) throws {
      halves.withLock { $0.token = token }
      usleep(300)
      halves.withLock { $0.url = url }
    }
    func clear() { halves.withLock { $0 = (nil, nil) } }
  }

  @Test("a load during a save sees the old pair or the new one, never the new token with the old URL")
  func loadNeverMixesTheHalves() async throws {
    let store = KeychainCredentialStore(storage: SplitStorage())
    let one = try #require(ConnectionCredentials(urlText: "https://a.example.com", token: "token-a"))
    let two = try #require(ConnectionCredentials(urlText: "https://b.example.com", token: "token-b"))
    try store.save(one)

    let finished = Mutex(false)
    let saver = Task.detached {
      for round in 0..<300 { try? store.save(round.isMultiple(of: 2) ? two : one) }
      finished.withLock { $0 = true }
    }
    let readers = (0..<3).map { _ in
      Task.detached { () -> Int in
        var bad = 0
        while !finished.withLock({ $0 }) {
          guard let seen = store.load() else { continue }
          if seen != one && seen != two { bad += 1 }
        }
        return bad
      }
    }
    await saver.value
    var mixed = 0
    for reader in readers { mixed += await reader.value }
    #expect(mixed == 0)
  }

  @Test("one send reads the connection once: the batch is bound to that server and goes to that URL with that token")
  func sendUsesOneSnapshot() async throws {
    // A store that has moved on to server B by the second read: a send that read twice would pair B's token with A's URL.
    final class Switching: CredentialStore {
      private let reads = Mutex(0)
      let first: ConnectionCredentials
      let later: ConnectionCredentials
      init(first: ConnectionCredentials, later: ConnectionCredentials) {
        self.first = first
        self.later = later
      }
      func load() -> ConnectionCredentials? {
        reads.withLock { n in
          defer { n += 1 }; return n == 0 ? first : later
        }
      }
      func save(_ credentials: ConnectionCredentials) throws {}
      func clear() {}
    }
    let first = try #require(ConnectionCredentials(urlText: a.absoluteString, token: "token-a"))
    let later = try #require(ConnectionCredentials(urlText: b.absoluteString, token: "token-b"))
    let seen = Mutex<[(URL, String)]>([])
    let transport = CredentialedTelemetryTransport(
      credentials: Switching(first: first, later: later),
      sender: { url, token, _ in seen.withLock { $0.append((url, token)) } })

    try await transport.send(
      TelemetryBatch(
        resource: TelemetryResource(serviceName: .ios, deviceName: "x", appVersion: "dev"),
        logs: [record("for-a", server: a), record("for-b", server: b)]))

    let sent = seen.withLock { $0 }
    #expect(sent.count == 1)
    #expect(sent.first?.0 == a && sent.first?.1 == "token-a")
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
