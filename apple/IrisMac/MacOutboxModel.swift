import Foundation
import IrisCore
import Observation
import Synchronization

/// What the menu panel shows of the outbox: the memos waiting to be sent, why a stalled one stopped, and Retry now / Discard.
///
/// The same queue and the same actions as the iPhone's Settings list — it reads `OutboxService` through the `QueuedItemSource`
/// port (compiled in from the iPhone target), it does not copy the outbox.
@MainActor
@Observable
final class MacOutboxModel {
  private(set) var items: [QueuedItem] = []
  /// The persistent queue cannot be opened right now, so nothing new is accepted until it can.
  private(set) var isUnavailable = false
  /// Why the queue could not be saved to disk; `nil` while it can. New segments wait for a save before they go up.
  private(set) var saveFailure: String?
  /// A Discard did not reach the queue (it could not be opened), so nothing was dropped.
  private(set) var discardFailed = false

  @ObservationIgnored private let source: any QueuedItemSource
  /// Told what the user did to a queued item (the device log's `outbox.user_action`).
  @ObservationIgnored var report: (_ action: String, _ item: QueuedItem, _ ok: Bool) -> Void = { _, _, _ in }

  init(source: any QueuedItemSource = EmptyQueue()) {
    self.source = source
  }

  /// Items the app has stopped retrying on its own: they wait for the user.
  var stalled: [QueuedItem] {
    items.filter { if case .failed(nil, _) = $0.state { true } else { false } }
  }

  /// Something the user should see: items waiting, or a queue that cannot be read or saved.
  var needsAttention: Bool { !items.isEmpty || isUnavailable || saveFailure != nil }

  /// Follows the queue for as long as the task lives: every change of the outbox refreshes the list.
  func observe() async {
    await refresh()
    for await _ in await source.changes() {
      guard !Task.isCancelled else { return }
      await refresh()
    }
  }

  func refresh() async {
    let available = await source.isAvailable()
    let queued = available ? await source.queuedItems() : []
    let failure = available ? await source.saveFailure() : nil
    items = queued
    isUnavailable = !available
    saveFailure = failure
  }

  /// Sends a failed or stalled item again now.
  func retry(_ item: QueuedItem) async {
    await source.retry(id: item.id)
    report("retry", item, true)
  }

  /// Drops an item from the queue, with what was recorded for it (a queued server delete: stops trying).
  func discard(_ item: QueuedItem) async {
    guard item.canDiscard else { return }
    let reached = await source.discardQueued(id: item.id)
    discardFailed = !reached
    report("discard", item, reached)
    await refresh()
  }
}

/// A queue the test and fake compositions script: nothing touches the outbox or the disk. `retry` moves the item to
/// `.sending`, `discard` removes it, and every change is told to whoever listens.
nonisolated final class ScriptedQueue: QueuedItemSource {
  private struct State {
    var items: [QueuedItem]
    var available = true
    var saveFailure: String?
    var discardReachesQueue = true
    var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    var retried: [String] = []
    var discarded: [String] = []
  }

  private let state: Mutex<State>

  init(_ items: [QueuedItem] = []) {
    state = Mutex(State(items: items))
  }

  var retried: [String] { state.withLock { $0.retried } }
  var discarded: [String] { state.withLock { $0.discarded } }

  func set(_ items: [QueuedItem]) { change { $0.items = items } }
  func setAvailable(_ available: Bool) { change { $0.available = available } }
  func setSaveFailure(_ failure: String?) { change { $0.saveFailure = failure } }
  func setDiscardReachesQueue(_ reaches: Bool) { change { $0.discardReachesQueue = reaches } }

  private func change(_ edit: (inout State) -> Void) {
    let listeners = state.withLock { state in
      edit(&state)
      return Array(state.listeners.values)
    }
    for listener in listeners { listener.yield() }
  }

  func queuedItems() async -> [QueuedItem] { state.withLock { $0.items } }
  func isAvailable() async -> Bool { state.withLock { $0.available } }
  func saveFailure() async -> String? { state.withLock { $0.saveFailure } }

  func changes() async -> AsyncStream<Void> {
    let id = UUID()
    return AsyncStream { continuation in
      state.withLock { $0.listeners[id] = continuation }
      continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.listeners[id] = nil } }
    }
  }

  func retry(id: String) async {
    change { state in
      state.retried.append(id)
      guard let index = state.items.firstIndex(where: { $0.id == id }) else { return }
      state.items[index].state = .sending
    }
  }

  func discard(id: String) async {
    _ = await discardQueued(id: id)
  }

  func discardQueued(id: String) async -> Bool {
    var reached = false
    change { state in
      reached = state.discardReachesQueue
      guard reached else { return }
      state.discarded.append(id)
      state.items.removeAll { $0.id == id }
    }
    return reached
  }
}

extension ScriptedQueue {
  /// The `-IrisMacStalled` sample: a voice memo and a typed memo the server refused, one waiting for its next try.
  static var stalledSample: [QueuedItem] {
    let now = Date()
    return [
      QueuedItem(
        id: "11111111-1111-4111-8111-111111111111", kind: .voiceMemo, title: "Voice memo",
        queuedAt: now.addingTimeInterval(-9 * 60),
        state: .failed(retryAt: nil, reason: "The server refused the recording (413)")),
      QueuedItem(
        id: "22222222-2222-4222-8222-222222222222", kind: .typedMemo, title: "Pick up the parcel on Friday",
        queuedAt: now.addingTimeInterval(-3 * 60), state: .failed(retryAt: now.addingTimeInterval(90), reason: nil)),
      QueuedItem(
        id: "33333333-3333-4333-8333-333333333333", kind: .removal, title: "Discarded memo",
        queuedAt: now.addingTimeInterval(-60), state: .waiting),
    ]
  }
}
