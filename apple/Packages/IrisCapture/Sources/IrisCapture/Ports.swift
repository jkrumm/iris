import Foundation

/// Owns the shared audio session: category, activation and interruption delivery.
/// Production: `AVAudioSessionController` (iOS only). Fake: `FakeAudioSessionController`.
public protocol AudioSessionController: Sendable {
  /// Interruptions of the session. One consumer per controller; the stream is created once.
  var interruptions: AsyncStream<InterruptionEvent> { get }

  /// `.playAndRecord`, mode `.default`, Bluetooth HFP/A2DP/high-quality-recording options,
  /// and no interruptions from system alerts.
  func configure() async throws
  func activate() async throws
  func deactivate() async throws
}

/// Lists inputs, applies the preferred input and owns the per-route preference rules.
/// Production: `AVAudioSessionRouteManager` (iOS only). Fake: `FakeRouteManager`.
public protocol RouteManager: Sendable {
  /// Route changes (device appeared/disappeared, user selection). One consumer per manager.
  var routeChanges: AsyncStream<RouteChange> { get }

  func currentRoute() async -> RouteSnapshot
  /// Selects the input with this UID, or restores the system default for `nil`.
  func setPreferredInput(uid: String?) async throws

  /// Device-local rules: route fingerprint -> preferred input port UID.
  func rules() async -> [String: String]
  func setRule(fingerprint: String, preferredPortUID: String?) async
}

/// Records one take as a series of segment files.
/// Production: `AVAudioEngineSegmentRecorder`. Fake: `FakeSegmentRecorder`.
public protocol SegmentRecorder: Sendable {
  /// Closed segments and take lifecycle. One consumer per recorder.
  var events: AsyncStream<CaptureEvent> { get }
  /// Input level in 0...1 (tap RMS), for the UI and the Live Activity.
  var levels: AsyncStream<Float> { get }

  func start(memoID: MemoID) async throws
  /// Flushes the final partial segment, then emits `.stopped`.
  func stop() async throws
  /// Closes the open segment (if it has frames) and continues in a new one.
  func rotate(for reason: RotationReason) async
  /// Closes the open segment and stops consuming input until `resume()`.
  func pause() async
  func resume() async
}

/// Receives closed segments. `Outbox` is the production implementation.
public protocol SegmentOutbox: Sendable {
  /// Idempotent per (memo, segment index).
  func enqueue(_ segment: ClosedSegment) async
  /// The take is over and had `segmentCount` segments; `complete` goes out once all are uploaded.
  func finishMemo(_ memoID: MemoID, segmentCount: Int) async
}

/// The network side of the outbox. Idempotent on the server per memo id and per (memo, index). A failure that a retry
/// cannot fix (a 4xx the server will repeat) is thrown as `PermanentTransferError`; any other error is retried.
public protocol SegmentUploader: Sendable {
  /// Creates the memo on the server: `POST /memos` for a take, `POST /memos/text` for a typed item.
  func create(_ item: OutboxItem) async throws
  func upload(_ segment: ClosedSegment) async throws
  func complete(memoID: MemoID, segmentCount: Int) async throws
  /// Removes the memo of a discarded take (`DELETE /memos/:id`). Done when the server has deleted it, no longer has it, or
  /// refuses for good (the memo moved past `receiving`): the latter two return normally. Anything else throws and is retried.
  func delete(memoID: MemoID) async throws
}

/// Persistence for the outbox queue (App Group container in production).
public protocol OutboxStore: Sendable {
  /// Throws `OutboxStoreError.undecodable` when the saved queue is there but cannot be read; it is left as it is.
  func load() async throws -> OutboxRecord
  func save(_ record: OutboxRecord) async throws
  /// Sets the unreadable saved queue aside under a timestamped name next to it, so the next `load()` opens an empty
  /// queue. Never deletes. The moved file, or `nil` when there was none.
  func quarantine() async throws -> URL?
  /// The queue files `quarantine()` has set aside, oldest first.
  func quarantined() async -> [URL]
}

extension OutboxStore {
  /// A store with no file of its own has nothing to set aside.
  public func quarantine() async throws -> URL? { nil }
  public func quarantined() async -> [URL] { [] }
}
