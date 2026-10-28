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
}

nonisolated struct EmptyQueue: QueuedItemSource {
  func queuedItems() async -> [QueuedItem] { [] }
  func isAvailable() async -> Bool { true }
  func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
  func retry(id: String) async {}
  func discard(id: String) async {}
}
