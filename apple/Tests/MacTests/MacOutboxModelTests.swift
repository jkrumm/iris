import Foundation
import Testing

@testable import IrisMac

/// The outbox in the menu panel: the same queue the iPhone's Settings reads, through `QueuedItemSource`.
@MainActor
@Suite("Mac outbox panel")
struct MacOutboxModelTests {
  private static let stalled = QueuedItem(
    id: "11111111-1111-4111-8111-111111111111", kind: .voiceMemo, title: "Voice memo", queuedAt: Date(),
    state: .failed(retryAt: nil, reason: "The server refused the recording (413)"))
  private static let backingOff = QueuedItem(
    id: "22222222-2222-4222-8222-222222222222", kind: .typedMemo, title: "Pick up the parcel", queuedAt: Date(),
    state: .failed(retryAt: Date().addingTimeInterval(60), reason: nil))
  private static let sending = QueuedItem(
    id: "33333333-3333-4333-8333-333333333333", kind: .chatMessage, title: "Hello", queuedAt: Date(), state: .sending)

  private func model(_ items: [QueuedItem]) async -> (MacOutboxModel, ScriptedQueue) {
    let queue = ScriptedQueue(items)
    let model = MacOutboxModel(source: queue)
    await model.refresh()
    return (model, queue)
  }

  @Test("an empty queue shows nothing")
  func empty() async {
    let (model, _) = await model([])
    #expect(model.items.isEmpty && !model.needsAttention)
  }

  @Test("a stalled upload is counted and its reason is the line under the title")
  func stalledCountAndReason() async {
    let (model, _) = await model([Self.stalled, Self.backingOff, Self.sending])
    #expect(model.needsAttention && model.items.count == 3)
    #expect(model.stalled.map(\.id) == [Self.stalled.id])
    #expect(MacOutboxStrip.title(count: 3, stalled: 1) == "1 of 3 could not be sent")
    #expect(MacOutboxStrip.reason(of: model.stalled.first) == "The server refused the recording (413)")
  }

  @Test("a queue that is only busy says how many are waiting and has no reason line")
  func busyQueue() async {
    let (model, _) = await model([Self.backingOff, Self.sending])
    #expect(model.stalled.isEmpty && model.needsAttention)
    #expect(MacOutboxStrip.title(count: 2, stalled: 0) == "2 waiting to send")
    #expect(MacOutboxStrip.reason(of: model.stalled.first) == nil)
  }

  @Test("a stalled item with no reason still gets a sentence")
  func stalledWithoutReason() {
    var item = Self.stalled
    item.state = .failed(retryAt: nil, reason: nil)
    #expect(MacOutboxStrip.reason(of: item) == "The server did not accept it.")
  }

  @Test("Retry now asks the outbox for that item")
  func retry() async {
    let (model, queue) = await model([Self.stalled])
    await model.retry(Self.stalled)
    #expect(queue.retried == [Self.stalled.id])
    await model.refresh()
    #expect(model.items.first?.state == .sending)
  }

  @Test("Discard drops the item from the queue and from the panel")
  func discard() async {
    let (model, queue) = await model([Self.stalled, Self.sending])
    await model.discard(Self.stalled)
    #expect(queue.discarded == [Self.stalled.id] && !model.discardFailed)
    #expect(model.items.map(\.id) == [Self.sending.id])
  }

  @Test("a take still recording has no Discard: its own controls end it")
  func recordingIsNotDiscardable() async {
    var recording = Self.sending
    recording.state = .recording
    let (model, queue) = await model([recording])
    await model.discard(recording)
    #expect(queue.discarded.isEmpty && model.items.count == 1)
  }

  @Test("a Discard that cannot reach the queue says so and drops nothing")
  func discardThatFails() async {
    let (model, queue) = await model([Self.stalled])
    queue.setDiscardReachesQueue(false)
    await model.discard(Self.stalled)
    #expect(model.discardFailed && model.items.count == 1)
  }

  @Test("an unavailable queue or a failed save is shown even with no items")
  func unavailableAndSaveFailure() async {
    let (model, queue) = await model([])
    queue.setAvailable(false)
    await model.refresh()
    #expect(model.isUnavailable && model.needsAttention && model.items.isEmpty)
    queue.setAvailable(true)
    queue.setSaveFailure("disk full")
    await model.refresh()
    #expect(!model.isUnavailable && model.saveFailure != nil && model.needsAttention)
  }

  @Test("the panel follows the queue: a change of the outbox refreshes the list")
  func followsChanges() async {
    let queue = ScriptedQueue([])
    let model = MacOutboxModel(source: queue)
    let following = Task { await model.observe() }
    defer { following.cancel() }
    queue.set([Self.stalled])
    #expect(await eventually { model.items.count == 1 })
    queue.set([])
    #expect(await eventually { model.items.isEmpty })
  }
}
