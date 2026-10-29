import Foundation

/// One whole memo or chat message that is waiting to be sent (round 2: the outbox is a queue of items, not of
/// segments). `OutboxService` fills it in from the capture outbox; ``QueuedItemSource`` is the seam.
nonisolated struct QueuedItem: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case voiceMemo
    case voiceReply
    case typedMemo
    case chatMessage
    case textReply
  }

  enum State: Equatable, Sendable {
    /// A take still being recorded.
    case recording
    case waiting
    case sending
    /// `retryAt` is `nil` once the item stalled: it waits for "retry now" or "discard".
    case failed(retryAt: Date?, reason: String?)
  }

  var id: String
  var kind: Kind
  var title: String
  var queuedAt: Date
  var state: State

  /// A take that is still being recorded is ended by its own controls: dropping its row would leave the recorder running.
  var canDiscard: Bool { state != .recording }
}

/// Where Settings reads the queue from, and what it can do to an item.
nonisolated protocol QueuedItemSource: Sendable {
  func queuedItems() async -> [QueuedItem]
  /// `false` when the persistent queue cannot be opened: nothing can be queued until it can, and Settings says so. Asking
  /// tries to open it again.
  func isAvailable() async -> Bool
  /// Yields once per change of the queue, for as long as the consumer iterates.
  func changes() async -> AsyncStream<Void>
  /// Sends a failed or stalled item again now.
  func retry(id: String) async
  /// Drops the item and what was recorded for it.
  func discard(id: String) async
  /// Why the queue could not be saved to disk, `nil` while it can: new segments of a take wait for a save before they go up,
  /// and a crash now could lose what is not saved.
  func saveFailure() async -> String?
}

extension QueuedItemSource {
  func saveFailure() async -> String? { nil }
}

nonisolated struct EmptyQueue: QueuedItemSource {
  func queuedItems() async -> [QueuedItem] { [] }
  func isAvailable() async -> Bool { true }
  func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
  func retry(id: String) async {}
  func discard(id: String) async {}
}
