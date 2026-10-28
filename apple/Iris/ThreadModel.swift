import Foundation
import IrisCore
import IrisUI
import Observation
import os

/// One open conversation: the thread with its memos, the turns they make up, the pending answer of a memo still in the
/// pipeline, and the reply by voice. A `memo.updated` event for any memo of the thread makes the screen call ``load()``
/// again; when the reply lands, the pending turn turns into the answer in place.
@Observable
final class ThreadModel {
  /// One block of the document, in the order it is read.
  struct Turn: Identifiable, Equatable {
    enum Content: Equatable {
      case user(String)
      case assistant(String, mermaid: [Int: MermaidAsset])
      case pending(StepProgress, caption: String)
      case failed(String)
    }

    let id: String
    let date: Date?
    let content: Content
  }

  let route: ThreadRoute
  private(set) var detail: ThreadDetail?
  /// The document, derived once per change of ``detail`` (not per render).
  private(set) var turns: [Turn] = []
  /// How many questions the thread holds, for the header.
  private(set) var questionCount = 0
  private(set) var loadFailed = false
  /// When the take in progress began; `nil` when idle.
  private(set) var voiceStartedAt: Date?
  /// The words of the last failed action, shown as a toast and cleared by ``dismissFailure()``.
  private(set) var failure: String?

  private let client: any APIClient
  private let voice: any VoiceReplyCapture
  private let now: () -> Date
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "thread")
  private var beginTask: Task<Bool, Never>?
  /// A take is being stopped and sent: a new hold must wait, the capture is still busy with the last one.
  private var isEndingVoice = false
  /// Bumped by every fetch and every local change; a fetch that is no longer the latest drops its answer.
  private var generation = 0

  /// A hold shorter than this is a touch, not a take.
  static let minimumTake: TimeInterval = 0.8

  init(route: ThreadRoute, client: any APIClient, voice: any VoiceReplyCapture, now: @escaping () -> Date = { Date() })
  {
    self.route = route
    self.client = client
    self.voice = voice
    self.now = now
  }

  var title: String { detail?.thread.title ?? route.title ?? "" }
  var kind: ThreadKind { detail?.thread.kind ?? .chat }
  var memoIDs: [String] { detail?.memos.map(\.id) ?? [] }
  var canRecordVoice: Bool { voice.isAvailable && !isEndingVoice }

  /// The mode a reply is created in: a chat keeps its marker, every other thread continues through Hermes.
  var replyMode: MemoMode { ComposerRequest.reply(toThread: route.id, kind: kind).mode }

  // MARK: Turns

  private static func makeTurns(_ detail: ThreadDetail?) -> [Turn] {
    guard let detail else { return [] }
    var users: [String: ThreadMessage] = [:]
    var replies: [String: ThreadMessage] = [:]
    for message in detail.messages {
      if message.role == .user { users[message.memoId] = message } else { replies[message.memoId] = message }
    }
    var turns: [Turn] = []
    for memo in detail.memos {
      if let user = users[memo.id] {
        turns.append(Turn(id: "\(memo.id).user", date: user.createdAt, content: .user(user.content)))
      }
      if let reply = replies[memo.id] {
        turns.append(
          Turn(
            id: "\(memo.id).reply", date: reply.createdAt,
            content: .assistant(reply.content, mermaid: memo.mermaidAssets)))
      } else if memo.state == .failed {
        turns.append(
          Turn(
            id: "\(memo.id).failed", date: memo.updatedAt,
            content: .failed(memo.error ?? String(localized: "This turn failed.", comment: "Failed turn in a thread"))))
      } else if !memo.state.isResultReady {
        turns.append(
          Turn(
            id: "\(memo.id).pending", date: nil,
            content: .pending(memo.stepProgress, caption: memo.pendingCaption)))
      }
    }
    return turns
  }

  private func apply(_ fresh: ThreadDetail) {
    detail = fresh
    turns = Self.makeTurns(fresh)
    questionCount = turns.count { if case .user = $0.content { true } else { false } }
  }

  // MARK: Loading

  /// Fetches the thread. A failure keeps what is on screen.
  func load() async {
    generation += 1
    let mine = generation
    do {
      let fresh = try await client.thread(id: route.id)
      guard !Task.isCancelled, mine == generation else { return }
      apply(fresh)
      loadFailed = false
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, mine == generation else { return }
      logger.error("thread load failed: \(String(describing: error), privacy: .public)")
      loadFailed = detail == nil
    }
  }

  /// A memo this device just created in the thread shows at once, as a user turn with its pending answer, before the
  /// next fetch brings the server's version.
  func didSend(_ memo: Memo) {
    guard var current = detail, !current.memos.contains(where: { $0.id == memo.id }) else { return }
    current.memos.append(memo)
    if let transcript = memo.transcript {
      current.messages.append(
        ThreadMessage(memoId: memo.id, role: .user, content: transcript, createdAt: memo.createdAt))
    }
    generation += 1
    apply(current)
  }

  // MARK: Voice

  /// Hold began. The state flips at once; the capture starts behind it, and ``endVoice(cancelled:)`` waits for that.
  func beginVoice() {
    guard voiceStartedAt == nil, !isEndingVoice, voice.isAvailable else { return }
    voiceStartedAt = now()
    let request = VoiceReplyRequest(threadId: route.id, mode: replyMode)
    beginTask = Task {
      do {
        try await voice.begin(request)
        return true
      } catch {
        logger.error("voice reply could not start: \(String(describing: error), privacy: .public)")
        failure = String(localized: "Could not start recording", comment: "Toast when a voice reply could not start")
        voiceStartedAt = nil
        return false
      }
    }
  }

  /// Hold ended. A hold shorter than ``minimumTake`` counts as a cancel with a hint. The memo the take became, when it
  /// became one.
  @discardableResult
  func endVoice(cancelled: Bool) async -> Memo? {
    guard let beginTask else { return nil }
    let startedAt = voiceStartedAt ?? now()
    isEndingVoice = true
    defer { isEndingVoice = false }
    let started = await beginTask.value
    self.beginTask = nil
    let tooShort = now().timeIntervalSince(startedAt) < Self.minimumTake
    voiceStartedAt = nil
    guard started else { return nil }
    do {
      let memo = try await voice.end(cancelled: cancelled || tooShort)
      if tooShort && !cancelled {
        failure = String(localized: "Hold the button while you speak", comment: "Toast after a too-short voice reply")
      }
      if let memo { didSend(memo) }
      return memo
    } catch {
      logger.error("voice reply failed: \(String(describing: error), privacy: .public)")
      failure = String(localized: "Could not send the voice reply", comment: "Toast when a voice reply failed")
      return nil
    }
  }

  func dismissFailure() {
    failure = nil
  }
}
