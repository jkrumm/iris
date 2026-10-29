import Foundation
import IrisCapture
import IrisCore
import os

/// What the user sees of a submission: the server has the memo, it waits in the outbox, or it was refused.
enum SendOutcome: Equatable, Sendable {
  case sent(Memo)
  case queued
  /// The outbox could not be opened, so nothing was taken: the caller keeps the text and says so.
  case refused
  /// The server refused it for good (a 4xx a retry cannot change): it will never be sent as it is. The item is not kept, the
  /// caller keeps the text and shows the reason.
  case stalled(reason: String)
}

/// A typed memo or chat message handed to the outbox.
struct TextSubmission: Sendable, Equatable {
  var id: MemoID
  var mode: MemoMode
  var text: String
  var threadId: String?
  var startedAt: Date
}

/// The memos the outbox created on the server, newest last, so a screen that waited for a send can show the memo and
/// History can list it. Bounded: only the recent ones are ever asked for.
actor CreatedMemoLog {
  private static let limit = 64
  private var memos: [String: Memo] = [:]
  private var order: [String] = []
  private var onCreated: (@Sendable (Memo) -> Void)?
  private var onForgotten: (@Sendable (String) -> Void)?
  private var onSettled: (@Sendable (String) -> Void)?

  init() {}

  func setHandler(_ handler: (@Sendable (Memo) -> Void)?) {
    onCreated = handler
  }

  func setForgottenHandler(_ handler: (@Sendable (String) -> Void)?) {
    onForgotten = handler
  }

  /// Called when the server `DELETE` of a discarded memo is over (done, or given up by the user): History no longer needs
  /// to hide it, the server's list decides from here on.
  func setSettledHandler(_ handler: (@Sendable (String) -> Void)?) {
    onSettled = handler
  }

  func record(_ memo: Memo) {
    if memos[memo.id] == nil { order.append(memo.id) }
    memos[memo.id] = memo
    while order.count > Self.limit { memos[order.removeFirst()] = nil }
    onCreated?(memo)
  }

  func memo(id: String) -> Memo? { memos[id] }

  /// The memo was discarded (a cancelled take; the server deletes it): it is no longer a created memo anyone should wait
  /// for, and the handler lets History drop it. Repeatable.
  func forget(_ id: String) {
    memos[id] = nil
    order.removeAll { $0 == id }
    onForgotten?(id)
  }

  /// The discard's server `DELETE` settled: the memo is gone from the server (or the user stopped trying), so History
  /// stops hiding it. Repeatable.
  func settle(_ id: String) {
    memos[id] = nil
    order.removeAll { $0 == id }
    onSettled?(id)
  }
}

/// The app's one door to the outbox: whole memos and messages go in, Settings reads the queue out. The outbox itself (and
/// the capture session around it) is built on first use by `CaptureStack`.
nonisolated final class OutboxService: QueuedItemSource {
  /// How long a screen waits for the first attempt before it settles for "queued"; the item is sent either way.
  static let firstAttemptWindow: Duration = .seconds(6)

  private let stack: CaptureStack
  let created: CreatedMemoLog
  private let now: @Sendable () -> Date
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "outbox")

  init(stack: CaptureStack, created: CreatedMemoLog, now: @escaping @Sendable () -> Date = { Date() }) {
    self.stack = stack
    self.created = created
    self.now = now
  }

  /// Queues the text and tries to send it at once. `.sent` carries the memo when the server answered inside
  /// `window`; `.queued` means it waits in the outbox (offline, a slow server, a failed attempt) and goes out by itself.
  /// Handing over the same submission twice is one memo.
  func submitText(_ submission: TextSubmission, window: Duration = firstAttemptWindow) async -> SendOutcome {
    guard let outbox = try? await stack.outbox() else { return .refused }
    let changes = await outbox.changes()
    let text = submission.text
    let item = OutboxItem(
      memoID: submission.id, kind: .text(text), mode: submission.mode.rawValue, threadID: submission.threadId,
      startedAt: submission.startedAt, queuedAt: now(), title: String(text.prefix(80)))
    do {
      try await outbox.enqueueItem(item)
    } catch {
      // The queue could not be written: nothing is held that a kill would lose, and the caller keeps the text.
      logger.error("item not queued: \(String(describing: error), privacy: .public)")
      return .refused
    }
    let outcome = await outcome(of: submission.id, outbox: outbox, changes: changes, window: window)
    if case .stalled = outcome {
      // The caller keeps the text and shows the reason: an item that can never be sent must not stay behind and go out as a
      // second copy of whatever the user sends next.
      await outbox.discard(submission.id)
    }
    return outcome
  }

  /// The outcome of a memo that is already in the outbox (a take that just stopped): `.sent` once the server has it.
  func awaitCreated(_ memoID: MemoID, window: Duration = firstAttemptWindow) async -> SendOutcome {
    guard let outbox = try? await stack.outbox() else { return .queued }
    let changes = await outbox.changes()
    return await outcome(of: memoID, outbox: outbox, changes: changes, window: window)
  }

  /// Sends what is waiting out a backoff now, and opens the queue if it is not open yet. The app calls it at launch,
  /// when the connection settings change and when it comes to the foreground: the moments the network may be back, so a
  /// transfer does not wait out the rest of a five-minute delay. What the server refused stays stalled until the user
  /// retries it.
  func resume() async {
    await (try? await stack.outbox())?.retryBackedOff()
  }

  // MARK: QueuedItemSource

  func queuedItems() async -> [QueuedItem] {
    guard let outbox = try? await stack.outbox() else { return [] }
    return await outbox.queue().map(QueuedItem.init)
  }

  func changes() async -> AsyncStream<Void> {
    guard let outbox = try? await stack.outbox() else { return AsyncStream { $0.finish() } }
    return await outbox.changes()
  }

  func retry(id: String) async {
    guard let memoID = UUID(uuidString: id) else { return }
    await (try? await stack.outbox())?.retryNow(memoID)
  }

  func discard(id: String) async {
    _ = await discardQueued(id: id)
  }

  /// The memos whose server `DELETE` is still queued (running, waiting for a retry or stalled), by wire id. `nil` when the
  /// outbox cannot be opened: that is "unknown", never "none", and a caller must not act on it.
  func pendingDeletionIDs() async -> Set<String>? {
    guard let outbox = try? await stack.outbox() else { return nil }
    return Set(await outbox.queue().filter(\.isDeletion).map { $0.id.wireID })
  }

  func discardQueued(id: String) async -> Bool {
    guard let memoID = UUID(uuidString: id) else { return false }
    guard let outbox = try? await stack.outbox() else {
      logger.error("discard of \(id, privacy: .public) not applied, the outbox cannot be opened")
      return false
    }
    // A row that is a stalled server `DELETE` has nothing to discard but the attempt itself.
    if await outbox.queue().first(where: { $0.id == memoID })?.isDeletion == true {
      await outbox.abandonDeletion(memoID)
      await created.settle(memoID.wireID)
      return true
    }
    return await discard(memoID)
  }

  /// Drops the item (a cancelled take or a queue row): History stops showing its memo at once, the server deletes it.
  /// `false` (logged) when the outbox cannot be opened: nothing was dropped there, and the caller must not look done.
  @discardableResult
  func discard(_ memoID: MemoID) async -> Bool {
    await created.forget(memoID.wireID)
    guard let outbox = try? await stack.outbox() else {
      logger.error("discard of \(memoID.wireID, privacy: .public) not applied, the outbox cannot be opened")
      return false
    }
    await outbox.discard(memoID)
    return true
  }

  /// Whether the memo left the queue because it was discarded, not because the server has it complete.
  func wasDiscarded(_ memoID: MemoID) async -> Bool {
    guard let outbox = try? await stack.outbox() else { return false }
    return await outbox.wasDiscarded(memoID)
  }

  func isAvailable() async -> Bool {
    await stack.isAvailable()
  }

  func isUnreadable() async -> Bool {
    await stack.availability() == .unreadable
  }

  func resetOutbox() async -> OutboxResetOutcome {
    do {
      return try await stack.resetOutbox()
    } catch {
      logger.error("outbox not reset: \(String(describing: error), privacy: .public)")
      return .notReset
    }
  }

  func quarantinedFiles() async -> [URL] {
    await stack.quarantinedFiles()
  }

  func saveFailure() async -> String? {
    guard let outbox = try? await stack.outbox() else { return nil }
    return await outbox.saveFailure()
  }

  // MARK: Internals

  private func outcome(
    of memoID: MemoID, outbox: Outbox, changes: AsyncStream<Void>, window: Duration
  ) async -> SendOutcome {
    await withTaskGroup(of: SendOutcome.self) { group in
      group.addTask { await self.watch(memoID, outbox: outbox, changes: changes) }
      group.addTask {
        try? await Task.sleep(for: window)
        return .queued
      }
      let first = await group.next() ?? .queued
      group.cancelAll()
      return first
    }
  }

  /// Ends with the memo as soon as the server has created it, or `.queued` once the item failed or left the queue.
  private func watch(_ memoID: MemoID, outbox: Outbox, changes: AsyncStream<Void>) async -> SendOutcome {
    // The state right now first: a stall that happened before the watch began raises no further change.
    if let settled = await settled(memoID, outbox: outbox) { return settled }
    for await _ in changes {
      if let settled = await settled(memoID, outbox: outbox) { return settled }
    }
    return .queued
  }

  /// The outcome when the memo is settled one way or the other, `nil` while the outbox is still on it.
  private func settled(_ memoID: MemoID, outbox: Outbox) async -> SendOutcome? {
    if let memo = await created.memo(id: memoID.wireID) { return .sent(memo) }
    // A discarded take's queued `DELETE` is not the memo: it never makes the memo "on its way".
    switch await outbox.queue().first(where: { $0.id == memoID && !$0.isDeletion })?.status {
    case .failed(nil, let reason)?: return .stalled(reason: reason ?? String(localized: "refused by the server"))
    case .failed?, nil: return .queued
    default: return nil
    }
  }
}

extension QueuedItem {
  nonisolated init(_ queued: OutboxQueueItem) {
    let item = queued.item
    let kind: Kind =
      switch (item.kind, item.threadID) {
      case _ where queued.isDeletion: .removal
      case (.voice, nil): .voiceMemo
      case (.voice, _): .voiceReply
      case (.text, nil): item.mode == MemoMode.chat.rawValue ? .chatMessage : .typedMemo
      case (.text, _): .textReply
      }
    let state: State =
      switch queued.status {
      case .recording: .recording
      case .waiting: .waiting
      case .sending: .sending
      case .failed(let retryAt, let reason): .failed(retryAt: retryAt, reason: reason)
      }
    self.init(id: item.memoID.wireID, kind: kind, title: item.title, queuedAt: item.queuedAt, state: state)
  }
}
