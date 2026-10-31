import Foundation

/// One job at a time: a call with the key of the running job joins it, a call with another key cancels it and runs its own.
/// The sweep of the Live Activities uses it with the server's key, so a sweep stalled on the old server never holds up the
/// sweep of the new one.
final class KeyedSingleFlight<Key: Equatable> {
  private var current: (key: Key, id: UUID, task: Task<Void, Never>)?

  /// Runs `work` (or waits for the running job of the same key); returns when that job is over, cancelled or not.
  func run(key: Key, _ work: @escaping () async -> Void) async {
    if let running = current, running.key == key { return await running.task.value }
    current?.task.cancel()
    let id = UUID()
    // Owned by `current` until it finishes; the next call with another key cancels it.
    let task = Task { await work() }
    current = (key, id, task)
    await task.value
    if current?.id == id { current = nil }
  }
}
