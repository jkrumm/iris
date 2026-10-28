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
  /// How many turns (questions asked) the thread holds, for the header.
  private(set) var turnCount = 0
  private(set) var loadFailed = false
  /// When the take in progress began; `nil` when idle.
  private(set) var voiceStartedAt: Date?
  /// A toast for the last failed action. The id tells two toasts with the same words apart.
  struct Failure: Equatable, Identifiable {
    let id: Int
    let message: String
  }

  /// The toast on screen. It goes away after ``toastDuration``, or at ``dismissFailure()``, whichever comes first; a
  /// newer toast takes over and its predecessor's timer is cancelled with it.
  private(set) var failure: Failure?

  private let client: any APIClient
  private let voice: any VoiceReplyCapture
  private let now: () -> Date
  private let toastDuration: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "thread")
  private var beginTask: Task<Bool, Never>?
  /// A take is being stopped and sent: a new hold must wait, the capture is still busy with the last one.
  private var isEndingVoice = false
  /// Bumped by every fetch and every local change; a fetch that is no longer the latest drops its answer.
  private var generation = 0
  private var toastCount = 0
  private var toastTimer: Task<Void, Never>?

  /// A hold shorter than this is a touch, not a take.
  static let minimumTake: TimeInterval = 0.8

  init(
    route: ThreadRoute, client: any APIClient, voice: any VoiceReplyCapture, now: @escaping () -> Date = { Date() },
    toastDuration: Duration = .seconds(4),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.route = route
    self.client = client
    self.voice = voice
    self.now = now
    self.toastDuration = toastDuration
    self.sleep = sleep
  }

  var title: String { detail?.thread.title ?? route.title ?? "" }
  var kind: ThreadKind { detail?.thread.kind ?? .chat }
  var memoIDs: [String] { detail?.memos.map(\.id) ?? [] }
  /// Replies wait for the first load: a thread's kind (chat or Hermes) decides the mode they are created in.
  var canReply: Bool { detail != nil }
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
    turnCount = turns.count { if case .user = $0.content { true } else { false } }
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
        showFailure(String(localized: "Could not start recording", comment: "Toast when a voice reply could not start"))
        voiceStartedAt = nil
        return false
      }
    }
  }

  /// Hold ended. A hold shorter than ``minimumTake`` counts as a cancel with a hint. The memo the take became, when it
  /// became one.
  @discardableResult
  func endVoice(cancelled: Bool) async -> Memo? {
    // Claim the take before the first suspension: the gesture's release and a cancel from the screen can both arrive.
    guard let beginTask else { return nil }
    self.beginTask = nil
    let startedAt = voiceStartedAt ?? now()
    isEndingVoice = true
    defer { isEndingVoice = false }
    let started = await beginTask.value
    let tooShort = now().timeIntervalSince(startedAt) < Self.minimumTake
    voiceStartedAt = nil
    guard started else { return nil }
    do {
      let outcome = try await voice.end(cancelled: cancelled || tooShort)
      if tooShort && !cancelled {
        showFailure(
          String(localized: "Hold the button while you speak", comment: "Toast after a too-short voice reply"))
      }
      switch outcome {
      case .sent(let memo):
        didSend(memo)
        return memo
      case .queued:
        didQueue()
        return nil
      case .discarded:
        return nil
      case .recordingFailed:
        showFailure(
          String(
            localized: "The recording failed and was not saved", comment: "Toast when the recorder failed mid-take"))
        return nil
      }
    } catch {
      logger.error("voice reply failed: \(String(describing: error), privacy: .public)")
      showFailure(String(localized: "Could not send the voice reply", comment: "Toast when a voice reply failed"))
      return nil
    }
  }

  /// A reply (typed or spoken) went to the outbox instead of the server: it joins the thread once it is sent.
  func didQueue() {
    showFailure(
      String(
        localized: "Queued. It is sent as soon as the server answers.",
        comment: "Toast after a reply went to the outbox"))
  }

  func dismissFailure() {
    toastTimer?.cancel()
    toastTimer = nil
    failure = nil
  }

  /// Shows `message` as the toast and starts its timer; the previous toast's timer is cancelled first, so it can
  /// never hide this one.
  private func showFailure(_ message: String) {
    toastTimer?.cancel()
    toastCount += 1
    let toast = Failure(id: toastCount, message: message)
    failure = toast
    let duration = toastDuration
    let sleep = sleep
    toastTimer = Task { [weak self] in
      guard (try? await sleep(duration)) != nil, !Task.isCancelled, self?.failure?.id == toast.id else { return }
      self?.dismissFailure()
    }
  }
}
