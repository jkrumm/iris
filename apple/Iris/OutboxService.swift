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

  init() {}

  func setHandler(_ handler: (@Sendable (Memo) -> Void)?) {
    onCreated = handler
  }

  func record(_ memo: Memo) {
    if memos[memo.id] == nil { order.append(memo.id) }
    memos[memo.id] = memo
    while order.count > Self.limit { memos[order.removeFirst()] = nil }
    onCreated?(memo)
  }

  func memo(id: String) -> Memo? { memos[id] }
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
    return await outcome(of: submission.id, outbox: outbox, changes: changes, window: window)
  }

  /// The outcome of a memo that is already in the outbox (a take that just stopped): `.sent` once the server has it.
  func awaitCreated(_ memoID: MemoID, window: Duration = firstAttemptWindow) async -> SendOutcome {
    guard let outbox = try? await stack.outbox() else { return .queued }
    let changes = await outbox.changes()
    return await outcome(of: memoID, outbox: outbox, changes: changes, window: window)
  }

  /// Retries what the server refused or what ran out of attempts; the app calls it again when the connection changes.
  func resume() async {
    await (try? await stack.outbox())?.resume()
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
    guard let memoID = UUID(uuidString: id) else { return }
    await (try? await stack.outbox())?.discard(memoID)
  }

  func isAvailable() async -> Bool {
    await stack.isAvailable()
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
    if let memo = await created.memo(id: memoID.wireID) { return .sent(memo) }
    for await _ in changes {
      if let memo = await created.memo(id: memoID.wireID) { return .sent(memo) }
      switch await outbox.queue().first(where: { $0.id == memoID })?.status {
      case .failed, nil: return .queued
      default: continue
      }
    }
    return .queued
  }
}

extension QueuedItem {
  nonisolated init(_ queued: OutboxQueueItem) {
    let item = queued.item
    let kind: Kind =
      switch (item.kind, item.threadID) {
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
