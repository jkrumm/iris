import Foundation

public struct SegmentKey: Sendable, Hashable, Codable {
  public let memoID: MemoID
  public let index: Int

  public init(memoID: MemoID, index: Int) {
    self.memoID = memoID
    self.index = index
  }
}

public enum OutboxState: Sendable, Equatable, Codable {
  case pending
  case uploading
  case uploaded
  case failed(retryAt: Date)
  /// Out of retries, or refused for good by the server: waits for the user's "retry now" or "discard".
  case stalled
}

public struct OutboxEntry: Sendable, Equatable, Codable {
  public var segment: ClosedSegment
  /// Enqueue order; uploads are dispatched oldest first.
  public var sequence: Int
  public var state: OutboxState
  public var attempts: Int

  public var key: SegmentKey { SegmentKey(memoID: segment.memoID, index: segment.index) }
}

/// A finished take waiting for its `complete` call.
public struct OutboxMemo: Sendable, Equatable, Codable {
  public let memoID: MemoID
  /// Grows only when the startup sweep adopts the next segment file of a take the app died in, or of a memo whose
  /// `complete` was never sent (`adopt(_:)`).
  public internal(set) var segmentCount: Int
  /// `.pending`, `.uploading` or `.failed`; the memo is removed once `complete` succeeds.
  public var completion: OutboxState
  public var attempts: Int
  /// Set when `complete` is handed out and saved with it, never cleared: from then on the server may hold the memo closed with
  /// `segmentCount` segments, so a tail segment found later cannot join it. Always written; a record from before the flag
  /// reads it from the completion state (see `init(from:)`).
  public internal(set) var completeMayHaveLanded: Bool
  /// Not persisted: the record had no flag, so `completeMayHaveLanded` was assumed. The state machine settles it on load
  /// (`OutboxStateMachine.init`), where the queue can prove the completion was never sent.
  var completeFlagIsAssumed = false

  private enum CodingKeys: String, CodingKey {
    case memoID, segmentCount, completion, attempts, completeMayHaveLanded
  }

  init(memoID: MemoID, segmentCount: Int, completion: OutboxState, attempts: Int, completeMayHaveLanded: Bool = false) {
    self.memoID = memoID
    self.segmentCount = segmentCount
    self.completion = completion
    self.attempts = attempts
    self.completeMayHaveLanded = completeMayHaveLanded
  }

  /// A record written before `completeMayHaveLanded` has no flag, and the memo alone does not prove `complete` was never sent:
  /// a completion that is `pending` with no attempts is also what "retry now" leaves behind (it resets the attempts). So an
  /// absent flag reads "may have landed" and is marked assumed; the state machine clears it again when the rest of the queue
  /// proves otherwise (the create is not uploaded, or a segment is not), since `complete` only follows both.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    memoID = try container.decode(MemoID.self, forKey: .memoID)
    segmentCount = try container.decode(Int.self, forKey: .segmentCount)
    completion = try container.decode(OutboxState.self, forKey: .completion)
    attempts = try container.decode(Int.self, forKey: .attempts)
    let stored = try container.decodeIfPresent(Bool.self, forKey: .completeMayHaveLanded)
    completeMayHaveLanded = stored ?? true
    completeFlagIsAssumed = stored == nil
  }
}

public enum OutboxItemKind: Sendable, Equatable, Codable {
  /// A take: the memo is created first, then its segments go up and `complete` closes it.
  case voice
  /// A typed memo or chat message: one `create` carrying the text, nothing else.
  case text(String)
}

/// A take that was discarded after the server may have created its memo: `DELETE /v1/memos/:id` goes out until the server
/// acknowledges it (or answers that the memo is gone or cannot be deleted), so the cancelled take does not stay behind as
/// a `receiving` memo. It is never dropped: when it stalls it shows in the queue (`OutboxQueueItem.isDeletion`) until a
/// retry succeeds or the user stops it. The item itself and its segments are already gone from the queue.
public struct OutboxDeletion: Sendable, Equatable, Codable {
  public let memoID: MemoID
  /// `.pending`, `.uploading`, `.failed` or `.stalled`; the record is removed once the delete is acknowledged.
  public var state: OutboxState
  public var attempts: Int
  /// The discarded take's queue title and time, for its row in the queue.
  public var title: String
  public var queuedAt: Date
  /// Why the last attempt failed, for the queue row.
  public var lastError: String?
  /// The server the discarded memo lives on (``OutboxItem/serverKey``): the `DELETE` goes to that server only.
  public var serverKey: String?

  public init(memoID: MemoID, title: String = "", queuedAt: Date = Date(), serverKey: String? = nil) {
    self.memoID = memoID
    self.title = title.isEmpty ? Self.fallbackTitle(memoID) : title
    self.queuedAt = queuedAt
    self.serverKey = serverKey
    state = .pending
    attempts = 0
    lastError = nil
  }

  /// A row for a record that never had a title: "Voice memo 1a2b3c4d", the memo id's first block.
  static func fallbackTitle(_ memoID: MemoID) -> String {
    "Voice memo \(memoID.uuidString.prefix(8).lowercased())"
  }

  /// Records written before the row existed have no title, time or error.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    memoID = try container.decode(MemoID.self, forKey: .memoID)
    state = try container.decode(OutboxState.self, forKey: .state)
    attempts = try container.decode(Int.self, forKey: .attempts)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.fallbackTitle(memoID)
    // Unknown for a record written before the row existed: the time it was read, so the row sorts last rather than first.
    queuedAt = try container.decodeIfPresent(Date.self, forKey: .queuedAt) ?? Date()
    lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    serverKey = try container.decodeIfPresent(String.self, forKey: .serverKey)
  }
}

/// One whole memo or chat message the user handed over: the queue Settings shows. A voice item's segments and
/// completion are tracked by `OutboxEntry` / `OutboxMemo` under the same memo id; the item owns the `create` call, which
/// must succeed before any of them goes out.
public struct OutboxItem: Sendable, Equatable, Codable {
  public let memoID: MemoID
  public var kind: OutboxItemKind
  /// The `MemoMode` raw value (IrisCapture does not depend on IrisCore).
  public var mode: String
  /// Continues this thread; `nil` for a new memo.
  public var threadID: String?
  public var startedAt: Date
  public var queuedAt: Date
  /// One line for the queue: the text, or what the take is.
  public var title: String
  public var create: OutboxState
  public var attempts: Int
  /// Why the last transfer failed, for the queue row.
  public var lastError: String?
  /// A `create` has been sent and the server did not refuse it, so the memo may exist there even if no answer ever came
  /// (the app was killed, the connection dropped on the way back). Set when the create is handed out, cleared by a refusal:
  /// a discard deletes the memo on the server exactly while this holds.
  public var createMayHaveLanded: Bool
  /// The server this item was made for (a digest of its URL, the server configured when the item is queued). Everything
  /// queued for the memo (the create, its segments, `complete`, a `DELETE`) goes to that server only: after a switch to another
  /// server it waits in the queue, and goes out when the first one is configured again. `nil` for an item queued before the
  /// binding existed, or by an uploader that does not know its server: it goes to whichever server is configured.
  public var serverKey: String?

  public init(
    memoID: MemoID, kind: OutboxItemKind, mode: String, threadID: String? = nil, startedAt: Date, queuedAt: Date,
    title: String, serverKey: String? = nil
  ) {
    self.memoID = memoID
    self.kind = kind
    self.mode = mode
    self.threadID = threadID
    self.startedAt = startedAt
    self.queuedAt = queuedAt
    self.title = title
    self.serverKey = serverKey
    create = .pending
    attempts = 0
    lastError = nil
    createMayHaveLanded = false
  }

  /// Records written before `createMayHaveLanded` read it from the create state and its attempts: only a create that was
  /// never handed out is known not to have landed.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    memoID = try container.decode(MemoID.self, forKey: .memoID)
    kind = try container.decode(OutboxItemKind.self, forKey: .kind)
    mode = try container.decode(String.self, forKey: .mode)
    threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    queuedAt = try container.decode(Date.self, forKey: .queuedAt)
    title = try container.decode(String.self, forKey: .title)
    create = try container.decode(OutboxState.self, forKey: .create)
    attempts = try container.decode(Int.self, forKey: .attempts)
    lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    serverKey = try container.decodeIfPresent(String.self, forKey: .serverKey)
    // Only a create that was never handed out is known not to have landed: a stalled one may have been refused or may have
    // run out of attempts after the server made the memo, and a pending one with failures behind it was sent before.
    let sentBefore =
      switch create {
      case .pending: attempts > 0
      case .stalled, .uploading, .uploaded, .failed: true
      }
    createMayHaveLanded = try container.decodeIfPresent(Bool.self, forKey: .createMayHaveLanded) ?? sentBefore
  }
}

/// A transfer the server refused for good (a 4xx that a retry cannot change): the item stalls at once instead of backing off.
public struct PermanentTransferError: Error, Sendable, Equatable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }
}

/// A transfer found the connection pointing at another server than the one its item was queued for (the connection switched
/// between the dispatch and the request). Nothing was sent; the outbox puts the transfer back, without a backoff or an attempt,
/// and holds it until its own server is configured again.
public struct WrongServerError: Error, Sendable, Equatable {
  public init() {}
}

/// The server a transfer in flight belongs to, for the client to check at the moment it picks its target: the check and the
/// swap of the connection are then one atomic step, which no check done before the call can be. `nil` outside the outbox.
public enum OutboxTransfer {
  @TaskLocal public static var serverKey: String?
}

/// `complete` was refused because the server holds fewer segments than the phone sent (422 `missing_segments`): a segment it
/// had was lost (a restored backup, a write that was refused in flight). The files are still here until `complete` succeeds, so
/// the outbox sends the listed ones again and then tries `complete` again, on a backoff, instead of stalling for good.
public struct MissingSegmentsError: Error, Sendable, Equatable {
  public let indices: [Int]
  public let message: String

  public init(indices: [Int], message: String) {
    self.indices = indices
    self.message = message
  }
}

/// A transfer that failed for a reason that says nothing about the transfer itself (no network, a 5xx, a 408 or 429): it
/// backs off and is tried again for as long as it takes, and does not count toward `OutboxPolicy.maxAttempts`.
public struct TransientTransferError: Error, Sendable, Equatable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }
}

/// Where a queued item stands, derived from its create call, segments and completion.
public enum OutboxItemStatus: Sendable, Equatable {
  /// A take still being recorded (not finished yet).
  case recording
  case waiting
  case sending
  /// `retryAt` is `nil` once the item stalled.
  case failed(retryAt: Date?, reason: String?)
}

/// One row of the queue, for the UI.
public struct OutboxQueueItem: Sendable, Equatable, Identifiable {
  public let item: OutboxItem
  public let status: OutboxItemStatus
  /// A discarded take's server `DELETE` still waiting to be acknowledged (`item` only carries its title and time).
  public let isDeletion: Bool
  public var id: MemoID { item.memoID }

  public init(item: OutboxItem, status: OutboxItemStatus, isDeletion: Bool = false) {
    self.item = item
    self.status = status
    self.isDeletion = isDeletion
  }
}

/// Everything the outbox persists.
public struct OutboxRecord: Sendable, Equatable, Codable {
  public var entries: [OutboxEntry]
  public var memos: [OutboxMemo]
  /// Whole memos and messages, oldest first. Added with the item queue: records written without it decode to `[]`.
  public var items: [OutboxItem]
  /// Discarded takes whose memo the server still has. Added with the cancel-delete: records written without it decode to `[]`.
  public var deletions: [OutboxDeletion]
  public var nextSequence: Int
  /// Memos whose `complete` succeeded, oldest first and capped by the state machine. Lets a repeated
  /// `finishMemo` or late `enqueue` be recognised after the memo and its entries were forgotten.
  /// Added after the first release: records written without it decode to an empty list.
  public var completedMemos: [MemoID]

  public init(
    entries: [OutboxEntry] = [], memos: [OutboxMemo] = [], items: [OutboxItem] = [],
    deletions: [OutboxDeletion] = [], nextSequence: Int = 0, completedMemos: [MemoID] = []
  ) {
    self.entries = entries
    self.memos = memos
    self.items = items
    self.deletions = deletions
    self.nextSequence = nextSequence
    self.completedMemos = completedMemos
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    entries = try container.decode([OutboxEntry].self, forKey: .entries)
    memos = try container.decode([OutboxMemo].self, forKey: .memos)
    items = try container.decodeIfPresent([OutboxItem].self, forKey: .items) ?? []
    deletions = try container.decodeIfPresent([OutboxDeletion].self, forKey: .deletions) ?? []
    nextSequence = try container.decode(Int.self, forKey: .nextSequence)
    completedMemos = try container.decodeIfPresent([MemoID].self, forKey: .completedMemos) ?? []
  }
}

public struct OutboxPolicy: Sendable {
  public var maxConcurrentUploads: Int
  public var baseDelay: TimeInterval
  public var maxDelay: TimeInterval
  /// The delay grows by up to this fraction, scaled by `jitter()`.
  public var jitterFraction: Double
  /// Returns a value in 0..<1. Injected so tests are deterministic.
  public var jitter: @Sendable () -> Double
  /// Failures after which a transfer stalls (waits for "retry now") instead of backing off again. A
  /// `TransientTransferError` is not counted: only a transfer that fails for another reason stalls.
  public var maxAttempts: Int

  public init(
    maxConcurrentUploads: Int = 2,
    baseDelay: TimeInterval = 2,
    maxDelay: TimeInterval = 300,
    jitterFraction: Double = 0.25,
    maxAttempts: Int = 10,
    jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
  ) {
    self.maxConcurrentUploads = maxConcurrentUploads
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.jitterFraction = jitterFraction
    self.maxAttempts = maxAttempts
    self.jitter = jitter
  }

  /// Exponential backoff: `baseDelay * 2^(attempt-1)`, capped at `maxDelay`, plus jitter.
  /// `attempt` is the number of failures so far (1 for the first failure).
  public func delay(forAttempt attempt: Int) -> TimeInterval {
    let exponent = min(max(attempt - 1, 0), 30)
    let capped = min(maxDelay, baseDelay * Double(1 << exponent))
    return capped * (1 + jitterFraction * jitter())
  }
}

/// A unit of network work the state machine hands out.
public enum OutboxWork: Sendable, Equatable {
  case create(OutboxItem)
  case upload(ClosedSegment)
  case complete(MemoID, segmentCount: Int)
  /// `DELETE` of a discarded take's memo.
  case delete(MemoID)
}

public enum OutboxError: Error, Sendable, Equatable {
  /// The queue could not be written to disk, so the item was not accepted.
  case notSaved
}
