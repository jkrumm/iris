import AppKit
import Foundation
import IrisCore
import IrisUI
import Observation
import os

/// The system pasteboard behind the detail's Copy buttons (the iOS app has `UIPasteboard`).
struct MacPasteboard: Pasteboard {
  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// One memo open in the main window's detail pane: its steps, the stats baselines the step durations are judged against, the
/// conversation of a thread memo, Copy and retry. The iOS `MemoDetailModel` also owns the recording and spoken-reply players,
/// which configure an `AVAudioSession`; on the Mac the window owns one ``MacAudioPlayer`` and the pane drives it.
@Observable
final class MacMemoDetailModel {
  enum CopyTarget: Equatable {
    case transcript, reply
  }

  /// `nil` until the memo is known: the list had it when the panel opened, else the first ``load()`` brings it.
  private(set) var detail: MemoDetail?
  /// The conversation a memo in a Hermes session belongs to (`GET /v1/threads/:id`); nil for a memo without one or while it
  /// loads. A failed read leaves the memo's own turns on screen.
  private(set) var thread: ThreadDetail?
  /// The conversation could not be read: the view says so (for a conversation of several memos) and shows the memo's own turns.
  private(set) var threadFailed = false
  /// What the conversation shows, oldest first: the loaded thread's turns, else the open memo's own (the list's copy shows at once,
  /// and a thread that cannot be read still shows the memo's turn).
  private(set) var turns: [ConversationTurn] = []
  /// The pane lays the memo out as a chat: ``Memo/isConversation``. Once a memo has shown as one it stays one, so the chat does not
  /// turn into a document when the memo is deleted meanwhile.
  private(set) var isChat = false
  /// What streams while a turn of this conversation runs: the tools started and the reply text so far (display only, folded from
  /// `memo.delta` / `memo.activity`). A turn that has some shows as the working list, then as the streaming answer.
  @ObservationIgnored private var live = LiveTurns()
  private(set) var baselines = StepBaselines()
  private(set) var isRetrying = false
  private(set) var loadFailed = false
  /// The text last copied, until the confirmation timer ends it; the button reads "Copied" meanwhile.
  private(set) var copied: CopyTarget?
  /// What the last failed action says, until the next action.
  private(set) var failure: String?
  let memoID: String
  /// The owner's own open or close of the waterfall; nil until the first tap.
  private var waterfallChoice: Bool?
  private var baselinesLoaded = false
  /// Bumped by every load and by a retry's answer. A response that finds it changed belongs to a request that was
  /// superseded (an event-triggered load that a retry's load overtook, or the other way round) and is dropped.
  private var generation = 0
  private var copyCount = 0
  private var copiedTimer: Task<Void, Never>?
  private let client: any APIClient
  private let pasteboard: any Pasteboard
  private let copiedDuration: Duration
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "detail")

  init(
    memoID: String, memo: Memo? = nil, client: any APIClient, pasteboard: any Pasteboard,
    copiedDuration: Duration = .seconds(1.5)
  ) {
    self.memoID = memoID
    detail = memo.map { MemoDetail(memo: $0, steps: []) }
    self.client = client
    self.pasteboard = pasteboard
    self.copiedDuration = copiedDuration
    refreshConversation()
  }

  var memo: Memo? { detail?.memo }

  /// The open memo continues a conversation another memo started (a reply, not a first question).
  var continuesThread: Bool { memo?.continuesThread ?? false }

  /// The composer's thread: only a memo that has a Hermes session can be replied to.
  var replyThreadID: String? {
    guard let memo, !memo.isDeleted else { return nil }
    return memo.threadId
  }

  private func refreshConversation() {
    guard let memo else {
      turns = []
      return
    }
    if memo.isConversation { isChat = true }
    let entries = thread.map { ConversationTimeline.entries(of: $0) } ?? ConversationTimeline.entries(of: memo)
    let next = LiveConversation.turns(of: entries, live: &live)
    if next != turns { turns = next }
  }

  // MARK: Live

  /// A live event of the event stream. `ready` (every connect) forgets what was streamed, since `attempt` restarts after a server
  /// restart, and fetches the partial reply again as the base; a delta or tool of a memo of this conversation updates its turn.
  func apply(_ event: ServerEvent) async {
    switch event {
    case .ready:
      live.reset()
      refreshConversation()
      await seedLive()
    case .memoDelta(let delta):
      guard belongs(delta.id) else { return }
      live.apply(event)
      refreshConversation()
    case .memoActivity(let activity):
      guard belongs(activity.id) else { return }
      live.apply(event)
      refreshConversation()
    case .memoUpdated, .memoDone:
      return
    }
  }

  private func belongs(_ id: String) -> Bool {
    memoID == id || (thread?.memos.contains { $0.id == id } ?? false)
  }

  /// Seeds the live turn of every running memo from its detail's `partialReply`, so a pane that opens mid-turn (or after a
  /// reconnect) has a complete base for the deltas that follow.
  func seedLive() async {
    let current = generation
    let memos = thread?.memos ?? (memo.map { [$0] } ?? [])
    for running in memos where !running.state.isResultReady && running.state != .failed {
      do {
        let partial = try await client.memo(id: running.id).partialReply
        guard !Task.isCancelled, current == generation else { return }
        live.seed(memoID: running.id, partial: partial)
      } catch is CancellationError {
        return
      } catch {
        logger.error("partial reply fetch failed: \(String(describing: error), privacy: .public)")
      }
    }
    refreshConversation()
  }

  /// A memo this Mac just created in the open conversation shows at once, as a user turn with its pending answer, before the next
  /// load brings the server's version.
  func didSend(_ memo: Memo) {
    guard let current = thread, let next = current.appending(sent: memo) else { return }
    generation += 1
    thread = next
    refreshConversation()
  }

  /// Puts one turn's text on the pasteboard (an answer as plain text).
  func copyTurn(_ text: String) {
    pasteboard.copy(text)
  }

  /// Details (the step rows and the ids) show under their line: collapsed until the owner opens them, except for a failed
  /// memo, whose failed step (and its retry) is what the owner came for.
  var isWaterfallExpanded: Bool {
    get { waterfallChoice ?? (memo?.state == .failed) }
    set { waterfallChoice = newValue }
  }

  // MARK: Waterfall

  func rows(now: Date) -> [StepWaterfallRow] {
    detail.map { WaterfallBuilder.rows(for: $0, baselines: baselines, now: now) } ?? []
  }

  /// The footer of the waterfall: the run's wall-clock time and summed cost.
  func totalValue(now: Date) -> String? {
    guard let detail, let totals = WaterfallBuilder.totals(for: detail, now: now) else { return nil }
    return StepText.metric(milliseconds: totals.milliseconds, costUsd: totals.costUsd)
  }

  // MARK: Loading

  /// Fetches the memo with its steps, and the stats baselines the first time. A failure keeps what is on screen.
  func load() async {
    generation += 1
    let current = generation
    do {
      let fresh = try await client.memo(id: memoID)
      guard !Task.isCancelled, current == generation else { return }
      detail = fresh
      loadFailed = false
      refreshConversation()
      await loadThread(of: fresh.memo, generation: current)
      refreshConversation()
      await seedLive()
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      logger.error("detail load failed: \(String(describing: error), privacy: .public)")
      loadFailed = true
    }
    guard !baselinesLoaded else { return }
    do {
      baselines = StepBaselines(try await client.stats(StatsQuery()))
      baselinesLoaded = true
    } catch is CancellationError {
      return
    } catch {
      // No baseline means no faster/slower tags, which is the honest state.
      logger.error("stats load failed: \(String(describing: error), privacy: .public)")
    }
  }

  private func loadThread(of memo: Memo, generation current: Int) async {
    guard !memo.isDeleted, let threadId = memo.threadId else {
      thread = nil
      threadFailed = false
      return
    }
    do {
      let fresh = try await client.thread(id: threadId)
      guard !Task.isCancelled, current == generation else { return }
      thread = fresh
      threadFailed = false
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      // A conversation already on screen stays; only a thread that never loaded is reported.
      if thread == nil { threadFailed = true }
      logger.error("thread load failed: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: Copy

  /// Puts the transcript or the reply on the pasteboard as plain text.
  func copy(_ target: CopyTarget) {
    let text =
      switch target {
      case .transcript: memo?.plainTranscript
      case .reply: memo?.plainReply
      }
    guard let text else { return }
    pasteboard.copy(text)
    copiedTimer?.cancel()
    copied = target
    copyCount += 1
    let count = copyCount
    let duration = copiedDuration
    copiedTimer = Task { [weak self] in
      guard (try? await Task.sleep(for: duration)) != nil, self?.copyCount == count else { return }
      self?.copied = nil
    }
  }

  // MARK: Retry

  /// The steps a retry can restart from: every step of the memo's pipeline up to the one that failed. A finished memo whose
  /// optional summarize step failed can restart that step alone. Empty otherwise: the server refuses a retry in any other state.
  var retrySteps: [MemoStep] {
    guard let detail else { return [] }
    let memo = detail.memo
    if memo.isSkippedOptionalStep(.summarize),
      detail.steps.contains(where: { $0.step == .summarize && $0.status == .failed })
    {
      return [.summarize]
    }
    let steps = PipelineSteps.applicable(to: memo)
    guard memo.state == .failed, let failed = memo.failedStep, let last = steps.firstIndex(of: failed) else {
      return []
    }
    return Array(steps[...last])
  }

  func retry(from step: MemoStep) async {
    guard retrySteps.contains(step), !isRetrying else { return }
    isRetrying = true
    failure = nil
    defer { isRetrying = false }
    do {
      let retried = try await client.retryMemo(id: memoID, request: RetryMemoRequest(from: step))
      // The retried memo is newer than any load that is still on the wire.
      generation += 1
      detail?.memo = retried
      refreshConversation()
      await load()
    } catch is CancellationError {
      return
    } catch {
      logger.error("retry failed: \(String(describing: error), privacy: .public)")
      failure = String(localized: "Could not retry the memo", comment: "Detail: a retry failed")
    }
  }
}
