import Foundation
import IrisCore
import Testing

@testable import Iris

private struct StaticQueue: QueuedItemSource {
  var items: [QueuedItem]
  func queuedItems() async -> [QueuedItem] { items }
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
}
