import Foundation
import IrisCore
import os

/// Typed replies written while a conversation's first memo was still before `act`, and kept past the life of their screen.
///
/// The server has no thread to continue until the first memo's `act`, so ``ThreadModel`` holds such a reply on the device. When the
/// screen goes away first, the model ``hand(_:anchor:)``s the text over: one follower per anchor memo polls the memo until it has a
/// thread id and sends the reply the way the screen would have. What is left when the screen opens again comes back through
/// ``reclaim(anchorID:)``.
@MainActor
final class HeldReplyQueue {
  /// What ``reclaim(anchorID:)`` gives back: still waiting for the thread, or a reply that has nowhere to go and returns to the field.
  enum Reclaimed: Equatable {
    case held(String)
    case draft(String)
  }

  private struct Entry {
    var text: String
    var isDraft = false
    var follower: Task<Void, Never>?
  }

  /// Told of every memo a follower creates (History lists it at once).
  var onSent: (Memo) -> Void = { _ in }

  private var entries: [String: Entry] = [:]
  private let client: any APIClient
  private let sendText: (_ text: String, _ threadID: String) async -> TypedReplyResult
  private let sleep: @Sendable (Duration) async throws -> Void
  private let firstDelay: Duration
  private let maxDelay: Duration
  private let giveUpAfter: Duration
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "thread")

  init(
    client: any APIClient,
    sendText: @escaping (_ text: String, _ threadID: String) async -> TypedReplyResult,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    firstDelay: Duration = .seconds(2), maxDelay: Duration = .seconds(30), giveUpAfter: Duration = .seconds(30 * 60)
  ) {
    self.client = client
    self.sendText = sendText
    self.sleep = sleep
    self.firstDelay = firstDelay
    self.maxDelay = maxDelay
    self.giveUpAfter = giveUpAfter
  }

  /// The screen went away holding `text` for `anchor`: keep it and follow the memo until it has a thread.
  func hand(_ text: String, anchor: Memo) {
    let id = anchor.id
    var entry = entries[id] ?? Entry(text: "")
    entry.follower?.cancel()
    entry.text = entry.text.isEmpty ? text : entry.text + "\n" + text
    entry.isDraft = false
    entry.follower = Task { [weak self] in await self?.follow(anchorID: id) }
    entries[id] = entry
    logger.info("held reply handed over for memo \(id, privacy: .public)")
  }

  /// The screen of `anchorID` opened: stops the follower and returns what is left of its reply.
  func reclaim(anchorID: String) -> Reclaimed? {
    guard let entry = entries.removeValue(forKey: anchorID) else { return nil }
    entry.follower?.cancel()
    return entry.isDraft ? .draft(entry.text) : .held(entry.text)
  }

  private func follow(anchorID: String) async {
    var delay = firstDelay
    var waited = Duration.zero
    while !Task.isCancelled {
      do { try await sleep(delay) } catch { return }
      waited += delay
      delay = min(delay * 2, maxDelay)
      guard !Task.isCancelled, entries[anchorID] != nil else { return }
      if waited >= giveUpAfter {
        logger.info("held reply for memo \(anchorID, privacy: .public) waits on: no thread after the give-up time")
        return
      }
      let memo: Memo
      do {
        memo = try await client.memo(id: anchorID).memo
      } catch {
        logger.error("held reply poll failed: \(String(describing: error), privacy: .public)")
        continue
      }
      guard !Task.isCancelled, entries[anchorID] != nil else { return }
      if memo.isDeleted || (memo.state.isResultReady && memo.threadId == nil) {
        entries[anchorID]?.isDraft = true
        entries[anchorID]?.follower = nil
        logger.info("held reply for memo \(anchorID, privacy: .public) has no thread to go to")
        return
      }
      if let threadID = memo.threadId {
        await deliver(anchorID: anchorID, threadID: threadID)
        return
      }
    }
  }

  /// Sends the reply into the thread. The entry leaves the table first, so a screen that opens meanwhile cannot send it twice.
  private func deliver(anchorID: String, threadID: String) async {
    guard let entry = entries.removeValue(forKey: anchorID) else { return }
    switch await sendText(entry.text, threadID) {
    case .sent(let memo):
      onSent(memo)
    case .queued:
      logger.info("held reply for memo \(anchorID, privacy: .public) went to the outbox")
    case .failed:
      entries[anchorID] = Entry(text: entry.text, isDraft: true)
      logger.error("held reply for memo \(anchorID, privacy: .public) could not be sent")
    }
  }
}
