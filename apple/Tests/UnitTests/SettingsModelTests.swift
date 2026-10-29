import Foundation
import IrisCore
import Testing

@testable import Iris

private struct StaticQueue: QueuedItemSource {
  var items: [QueuedItem]
  func queuedItems() async -> [QueuedItem] { items }
  func isAvailable() async -> Bool { true }
  func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
  func retry(id: String) async {}
  func discard(id: String) async {}
}

@MainActor
@Suite("SettingsModel")
struct SettingsModelTests {
  let client = FakeAPIClient()

  @Test("a healthy server reads as connected, a degraded one names what is down")
  func connection() async {
    let model = SettingsModel(client: client)
    #expect(model.connection == .checking)
    await model.load()
    #expect(model.connection == .connected)

    await client.setHealth(Health(status: .degraded, degraded: ["hermes"], inflight: 0))
    await model.load()
    #expect(model.connection == .degraded(["hermes"]))
  }

  @Test("an unreachable server is not connected")
  func unreachable() async {
    let model = SettingsModel(client: client)
    await client.enqueueFailure(.unexpectedStatus(503), for: .health)
    await model.load()
    #expect(model.connection == .unreachable)
  }

  @Test("the queue starts empty and shows what the source provides")
  func queue() async {
    let empty = SettingsModel(client: client)
    await empty.load()
    #expect(empty.queue.isEmpty)

    let item = QueuedItem(
      id: "q1", kind: .chatMessage, title: "Which index?", queuedAt: MemoFactory.now, state: .waiting)
    let filled = SettingsModel(client: client, queue: StaticQueue(items: [item]))
    await filled.load()
    #expect(filled.queue == [item])
  }

  @Test("a stale load never overwrites a newer one")
  func staleLoad() async {
    let model = SettingsModel(client: client)
    await client.setHealth(Health(status: .degraded, degraded: ["hermes"], inflight: 0))
    let gate = await client.hold(.health)
    let stale = Task { await model.load() }
    defer { gate.release() }
    guard await waitUntilHeld(gate) else { return }

    await client.setHealth(Health(status: .ok, degraded: [], inflight: 0))
    await model.load()
    #expect(model.connection == .connected)
    gate.release()
    await stale.value
    #expect(model.connection == .connected)
  }

  @Test("with no saved connection it says so and asks the server nothing")
  func notConfigured() async {
    let store = InMemoryCredentialStore()
    let model = SettingsModel(client: client, credentials: store)
    #expect(model.connection == .notConfigured)
    await model.load()
    #expect(model.connection == .notConfigured)
    #expect(await client.calls.isEmpty)

    store.set(ConnectionCredentials(urlText: "https://iris.example.com", token: "t"))
    await model.load()
    #expect(model.connection == .connected)
  }
}

/// A queue that cannot be saved to disk.
private struct UnsavableQueue: QueuedItemSource {
  func queuedItems() async -> [QueuedItem] { [] }
  func isAvailable() async -> Bool { true }
  func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
  func retry(id: String) async {}
  func discard(id: String) async {}
  func saveFailure() async -> String? { "disk full" }
}

@MainActor
@Suite("Settings queue save failure")
struct SettingsSaveFailureTests {
  @Test("Settings tells the user when the queue cannot be saved")
  func showsIt() async {
    let model = SettingsModel(client: FakeAPIClient(now: { MemoFactory.now }), queue: UnsavableQueue())
    await model.load()
    #expect(model.queueSaveFailure == "disk full")
  }
}
