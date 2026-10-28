import Foundation

/// One whole memo or chat message that is waiting to be sent (round 2: the outbox is a queue of items, not of
/// segments). Capture fills this in when it lands; ``QueuedItemSource`` is the seam.
nonisolated struct QueuedItem: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case voiceMemo
    case chatMessage
  }

  enum State: Equatable, Sendable {
    case waiting
    case sending
    case failed(retryAt: Date?)
  }

  var id: String
  var kind: Kind
  var title: String
  var queuedAt: Date
  var state: State
}

/// Where Settings reads the queue from. The capture work provides the real one; until then the queue is empty.
nonisolated protocol QueuedItemSource: Sendable {
  func queuedItems() async -> [QueuedItem]
}

nonisolated struct EmptyQueue: QueuedItemSource {
  func queuedItems() async -> [QueuedItem] { [] }
}
