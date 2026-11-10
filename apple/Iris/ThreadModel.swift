import Foundation
import IrisCore
import IrisUI
import Observation
import os

/// How a typed reply left the device: the server has the memo, the outbox keeps it for later, or nothing took it.
enum TypedReplyResult: Equatable {
  case sent(Memo)
  case queued
  case failed
}

/// One open conversation, anchored at the memo History opened: the thread with its memos, the turns they make up, the
/// pending answer of a memo still in the pipeline, and the reply bar (typed or spoken). Before the thread loads, or when
/// it cannot, the screen shows the anchor's own turns. A `memo.updated` event for the anchor or any memo of the thread
/// makes the screen call ``load()`` again; when the reply lands, the pending turn turns into the answer in place.
///
/// The server creates a thread record at the first memo's `act`, so a reply typed while the first memo is still before
/// `act` is held on this device (shown as a turn waiting for the first answer) and sent as soon as the memo has a thread id.
@Observable
final class ThreadModel {
  /// The memo the screen was opened on, as fresh as the last load.
  private(set) var anchor: Memo
  private(set) var detail: ThreadDetail?
  /// The document, derived once per change of its sources (not per render).
  private(set) var turns: [ConversationTurn] = []
  /// How many turns (questions asked) the thread holds, for the header.
  private(set) var turnCount = 0
  private(set) var loadFailed = false
  /// The bottom bar: the draft and the voice take.
  let replyBar: ReplyBarModel
  /// A toast for the last failed action. The id tells two toasts with the same words apart.
  struct Failure: Equatable, Identifiable {
    let id: Int
    let message: String
  }

  /// The toast on screen. It goes away after ``toastDuration``, or at ``dismissFailure()``, whichever comes first; a
  /// newer toast takes over and its predecessor's timer is cancelled with it.
  private(set) var failure: Failure?
  /// Told of every memo this screen creates (History lists it at once).
  @ObservationIgnored var onSent: (Memo) -> Void = { _ in }

  /// Memos sent from this screen before the thread loaded.
  private var sentMemos: [Memo] = []
  /// A typed reply waiting for the first memo's thread.
  private var held: String?
  /// The tools and reply text of the memos still in `act`. Display only: never logged or stored.
  @ObservationIgnored private var live = LiveTurns()

  private let client: any APIClient
  private let sendText: (_ text: String, _ threadID: String) async -> TypedReplyResult
  private let toastDuration: Duration
  private let heldReplies: HeldReplyQueue
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "thread")
  /// Bumped by every fetch and every local change; a fetch that is no longer the latest drops its answer.
  private var generation = 0
  private var toastCount = 0
  private let toastTimer: ExpiryTimer

  init(
    memo: Memo, client: any APIClient, voice: any VoiceReplyCapture,
    sendText: @escaping (_ text: String, _ threadID: String) async -> TypedReplyResult,
    now: @escaping () -> Date = { Date() }, toastDuration: Duration = .seconds(4),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    heldReplies: HeldReplyQueue? = nil
  ) {
    anchor = memo
    self.client = client
    self.sendText = sendText
    self.toastDuration = toastDuration
    self.heldReplies = heldReplies ?? HeldReplyQueue(client: client, sendText: sendText, sleep: sleep)
    toastTimer = ExpiryTimer(sleep: sleep)
    replyBar = ReplyBarModel(voice: voice, now: now)
    replyBar.onNotice = { [weak self] notice in self?.show(notice) }
    reclaimHeld()
    rebuild()
  }

  /// The screen (re)appears: what the queue still holds for the anchor comes back here. Also on a reappear of a screen whose
  /// model lives on (a full-screen cover such as the diagram zoom ends the presenter's appearance and hands the reply over).
  func reclaimHeld() {
    switch heldReplies.reclaim(anchorID: anchor.id) {
    case .held(let text):
      held = held.map { $0 + "\n" + text } ?? text
    case .draft(let text):
      replyBar.restoreDraft(text)
      showFailure(
        String(
          localized: "A reply you wrote earlier could not be sent. It is back in the field.",
          comment: "Toast when a reply handed over by a closed screen found no conversation to go to"))
    case nil:
      return
    }
    rebuild()
  }

  /// The screen goes away: a reply still held for the first memo's thread outlives it in the queue.
  func handOver() {
    guard let text = held else { return }
    held = nil
    rebuild()
    heldReplies.hand(text, anchor: anchor)
  }

  var title: String { detail?.thread.title ?? anchor.rowHeadline }
  var memoIDs: [String] { detail?.memos.map(\.id) ?? [anchor.id] }
  var threadID: String? { detail?.thread.id ?? anchor.threadId }
  /// The first memo is still on its way to `act`: a reply typed now is held.
  private var anchorIsRunning: Bool { !anchor.state.isResultReady }
  /// A reply can be typed once the conversation has a thread, or will get one when the first answer lands.
  var canType: Bool { !anchor.isDeleted && (threadID != nil || anchorIsRunning) }
  var canRecordVoice: Bool { replyBar.isVoiceAvailable && threadID != nil }

  private func rebuild() {
    let entries =
      if let detail {
        ConversationTimeline.entries(of: detail)
      } else {
        ([anchor] + sentMemos).flatMap { ConversationTimeline.entries(of: $0) }
      }
    dropFinishedLiveTurns(entries)
    var next = entries.map { liveTurn(for: $0) ?? ConversationTurn($0) }
    turnCount = next.count { if case .user = $0.content { true } else { false } }
    if let held {
      next.append(ConversationTurn(id: "held.user", memoID: nil, date: nil, content: .user(held)))
      next.append(
        ConversationTurn(
          id: "held.pending", memoID: nil, date: nil,
          content: .pending(
            StepProgress(completed: 0, total: 0),
            caption: String(localized: "Sends after the first answer", comment: "Pending turn of a held reply"))))
    }
    if next != turns { turns = next }
  }

  /// A memo that ended (result-ready or failed) no longer has a live turn.
  private func dropFinishedLiveTurns(_ entries: [ConversationEntry]) {
    for entry in entries where entry.memo.state.isResultReady || entry.memo.state == .failed {
      live.drop(memoID: entry.memo.id)
    }
  }

  /// The pending entry of a memo with live events: the streaming reply once there is a complete base, else the tool list. The
  /// streaming turn takes the id of the final reply, so the finished answer replaces it in place.
  private func liveTurn(for entry: ConversationEntry) -> ConversationTurn? {
    guard case .pending = entry.kind, let turn = live.turn(for: entry.memo.id) else { return nil }
    if !turn.shownText.isEmpty {
      return ConversationTurn(
        id: "\(entry.memo.id).reply", memoID: entry.memo.id, date: nil,
        content: .streaming(markdown: turn.shownText, activity: turn.currentTool.map(ToolActivityText.label(for:))))
    }
    guard !turn.tools.isEmpty else { return nil }
    let lines = turn.tools.enumerated().map {
      ActivityLine(id: $0.offset, label: ToolActivityText.label(for: $0.element))
    }
    return ConversationTurn(id: entry.id, memoID: entry.memo.id, date: nil, content: .working(lines))
  }

  /// The memo for a turn's Details sheet: the loaded thread's version, or the anchor.
  func memo(id: String) -> Memo? {
    if let found = detail?.memos.first(where: { $0.id == id }) { return found }
    return ([anchor] + sentMemos).first { $0.id == id }
  }

  // MARK: Loading

  /// Fetches the thread (the anchor first, when it has no thread id yet) and sends a held reply once there is a thread. A
  /// failure keeps what is on screen.
  func load() async {
    generation += 1
    let mine = generation
    do {
      if threadID == nil {
        let fresh = try await client.memo(id: anchor.id).memo
        guard !Task.isCancelled, mine == generation else { return }
        anchor = fresh
        if fresh.threadId == nil {
          dropHeldIfAnchorEnded()
          rebuild()
          loadFailed = false
          await seedLive()
          return
        }
      }
      guard let id = threadID else { return }
      let fresh = try await client.thread(id: id)
      guard !Task.isCancelled, mine == generation else { return }
      detail = fresh
      sentMemos = []
      loadFailed = false
      rebuild()
      await seedLive()
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, mine == generation else { return }
      logger.error("thread load failed: \(String(describing: error), privacy: .public)")
      loadFailed = detail == nil && turns.isEmpty
      rebuild()
    }
    await sendHeld()
  }

  // MARK: Live

  /// A live event: `ready` (every connect) forgets what was streamed, since `attempt` restarts after a server restart, and
  /// fetches the partial reply again; a delta or tool of a memo of this conversation updates its live turn.
  func apply(_ event: ServerEvent) async {
    switch event {
    case .ready:
      live.reset()
      rebuild()
      await seedLive()
    case .memoDelta(let delta):
      guard belongs(delta.id) else { return }
      live.apply(event)
      rebuild()
    case .memoActivity(let activity):
      guard belongs(activity.id) else { return }
      live.apply(event)
      rebuild()
    case .memoUpdated, .memoDone:
      return
    }
  }

  private func belongs(_ memoID: String) -> Bool {
    memoIDs.contains(memoID) || sentMemos.contains { $0.id == memoID }
  }

  /// Seeds the live turn of every running memo from its detail's `partialReply`, so a screen that opens mid-turn (or after a
  /// reconnect) has a complete base for the deltas that follow.
  private func seedLive() async {
    let mine = generation
    let running = currentMemos.filter { !$0.state.isResultReady && $0.state != .failed }.map(\.id)
    for id in running {
      do {
        let partial = try await client.memo(id: id).partialReply
        guard !Task.isCancelled, mine == generation else { return }
        live.seed(memoID: id, partial: partial)
      } catch is CancellationError {
        return
      } catch {
        logger.error("partial reply fetch failed: \(String(describing: error), privacy: .public)")
      }
    }
    rebuild()
  }

  private var currentMemos: [Memo] { detail?.memos ?? ([anchor] + sentMemos) }

  /// The first memo ended without a thread (it failed, or it finished with none): a held reply has nowhere to go.
  private func dropHeldIfAnchorEnded() {
    guard let text = held, !anchorIsRunning else { return }
    held = nil
    replyBar.restoreDraft(text)
    showFailure(
      String(
        localized: "The first memo has no conversation yet, so the reply was not sent",
        comment: "Toast when a held reply cannot be sent because the first memo ended without a thread"))
  }

  private func sendHeld() async {
    guard let text = held, let id = threadID else { return }
    held = nil
    rebuild()
    await send(text, threadID: id)
  }

  // MARK: Typed reply

  /// Sends the draft: into the thread, or held while the first memo has none yet.
  func sendDraft() async {
    guard canType, let text = replyBar.takeDraft() else { return }
    guard let id = threadID else {
      held = held.map { $0 + "\n" + text } ?? text
      rebuild()
      return
    }
    await send(text, threadID: id)
  }

  private func send(_ text: String, threadID: String) async {
    switch await sendText(text, threadID) {
    case .sent(let memo):
      didSend(memo)
      onSent(memo)
    case .queued:
      show(.queued)
    case .failed:
      replyBar.restoreDraft(text)
      showFailure(
        String(
          localized: "Could not send the reply. Your text is back in the field.",
          comment: "Toast when a typed reply could not be sent"))
    }
  }

  /// A memo this device just created in the thread shows at once, as a user turn with its pending answer, before the
  /// next fetch brings the server's version.
  func didSend(_ memo: Memo) {
    if let current = detail {
      guard let next = current.appending(sent: memo) else { return }
      detail = next
    } else {
      guard !sentMemos.contains(where: { $0.id == memo.id }) else { return }
      sentMemos.append(memo)
    }
    generation += 1
    rebuild()
  }

  // MARK: Voice

  /// Hold began. Voice needs a thread to bind the memo to, so it waits for ``threadID``.
  func beginVoice() {
    guard let threadID else { return }
    replyBar.beginVoice(threadID: threadID)
  }

  /// Hold ended; the memo the take became joins the thread and History.
  func endVoice(cancelled: Bool) async {
    guard let memo = await replyBar.endVoice(cancelled: cancelled) else { return }
    didSend(memo)
    onSent(memo)
  }

  // MARK: Toast

  private func show(_ notice: ReplyBarModel.Notice) {
    switch notice {
    case .couldNotStartRecording:
      showFailure(String(localized: "Could not start recording", comment: "Toast when a voice reply could not start"))
    case .tooShort:
      showFailure(String(localized: "That was too short to send", comment: "Toast after a too-short voice reply"))
    case .recordingFailed:
      showFailure(
        String(localized: "The recording failed and was not saved", comment: "Toast when the recorder failed mid-take"))
    case .voiceFailed:
      showFailure(String(localized: "Could not send the voice reply", comment: "Toast when a voice reply failed"))
    case .queued:
      showFailure(
        String(
          localized: "Queued. It is sent as soon as the server answers.",
          comment: "Toast after a reply went to the outbox"))
    }
  }

  func dismissFailure() {
    toastTimer.cancel()
    failure = nil
  }

  /// Shows `message` as the toast and starts its timer; the previous toast's timer is cancelled first, so it can
  /// never hide this one.
  private func showFailure(_ message: String) {
    toastCount += 1
    failure = Failure(id: toastCount, message: message)
    toastTimer.arm(after: toastDuration) { [weak self] in self?.dismissFailure() }
  }
}
