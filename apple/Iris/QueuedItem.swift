import Foundation
import IrisCapture

/// One whole memo or chat message that is waiting to be sent (round 2: the outbox is a queue of items, not of
/// segments). `OutboxService` fills it in from the capture outbox; ``QueuedItemSource`` is the seam.
nonisolated struct QueuedItem: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case voiceMemo
    case voiceReply
    case typedMemo
    case chatMessage
    case textReply
    /// A discarded take whose memo the server still has: its `DELETE` is queued and shows until it goes through.
    case removal
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

extension QueuedItem.Kind {
  /// Its Discard drops the row, not a memo: the app stops trying to remove the memo from the server.
  var discardStopsTrying: Bool { self == .removal }
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
  /// `discard(id:)` that says whether it reached the queue: `false` when the queue could not be opened, so nothing was dropped.
  func discardQueued(id: String) async -> Bool
  /// Why the queue could not be saved to disk, `nil` while it can: new segments of a take wait for a save before they go up,
  /// and a crash now could lose what is not saved.
  func saveFailure() async -> String?
  /// Whether the persistent queue is there but cannot be decoded, so that only a reset gets past it.
  func isUnreadable() async -> Bool
  /// Sets the unreadable queue file aside (kept, never deleted) and opens a fresh queue. `false` when that did not work.
  func resetOutbox() async -> OutboxResetOutcome
  /// The queue files earlier resets set aside.
  func quarantinedFiles() async -> [URL]
  /// Everything the app has set aside and kept: queue files and recordings no queue entry owned.
  func setAside() async -> SetAsideSummary
}

extension QueuedItemSource {
  func saveFailure() async -> String? { nil }
  func isUnreadable() async -> Bool { false }
  func resetOutbox() async -> OutboxResetOutcome { .notReset }
  func discardQueued(id: String) async -> Bool {
    await discard(id: id)
    return true
  }
  func quarantinedFiles() async -> [URL] { [] }
  func setAside() async -> SetAsideSummary { SetAsideSummary() }
}

/// What the app set aside instead of deleting: outbox files a reset renamed, and recordings the startup sweep could not attach
/// to a take. Nothing leaves the device until the owner decides, so Settings shows how much there is and lets it be shared.
nonisolated struct SetAsideSummary: Equatable, Sendable {
  /// Past this many files or bytes Settings says so (the bound is a prompt to look, not a deletion).
  static let countBound = 50
  static let byteBound = 200_000_000

  var queueFiles: [SetAsideFile] = []
  var recordings: [SetAsideFile] = []
  /// Recordings the sweep could not move out of the capture directory (and shadows it could not read): kept where they are and
  /// tried again at the next launch, listed here so they are not invisible.
  var unmoved: [SetAsideFile] = []

  var count: Int { queueFiles.count + recordings.count + unmoved.count }
  var byteCount: Int { (queueFiles + recordings + unmoved).reduce(0) { $0 + $1.byteCount } }
  var isEmpty: Bool { count == 0 }
  var exceedsBound: Bool { count > Self.countBound || byteCount > Self.byteBound }

  /// One line per file (name, size, date): what a share or a copy of the diagnostics carries. No audio, no memo content.
  var report: String {
    let header = "Set-aside files: \(count), \(Self.size(byteCount))"
    let lines = (queueFiles + recordings).map { Self.line($0) } + unmoved.map { Self.line($0, note: "  (not moved)") }
    return ([header] + lines).joined(separator: "\n")
  }

  private static func line(_ file: SetAsideFile, note: String = "") -> String {
    let date = file.modifiedAt.map { $0.formatted(.iso8601) } ?? "-"
    return "\(file.url.lastPathComponent)  \(size(file.byteCount))  \(date)\(note)"
  }

  static func size(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
}

nonisolated struct EmptyQueue: QueuedItemSource {
  func queuedItems() async -> [QueuedItem] { [] }
  func isAvailable() async -> Bool { true }
  func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
  func retry(id: String) async {}
  func discard(id: String) async {}
}
