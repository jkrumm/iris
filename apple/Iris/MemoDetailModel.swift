import Foundation
import IrisCore
import IrisUI
import Observation
import os

/// One open memo: its detail (steps included), the stats baselines the step durations are judged against, and the
/// actions (retry). A `memo.updated` event for the memo makes the screen call ``load()`` again; the model holds no
/// event stream of its own.
@Observable
final class MemoDetailModel {
  private(set) var detail: MemoDetail
  /// The transcript the memo is a part of (`GET /v1/threads/:id`), once the memo has a thread: a first part that something
  /// continued, or a continuation. Nil for a single recording, while it loads and when it cannot be read.
  private(set) var thread: ThreadDetail?
  private(set) var baselines = StepBaselines()
  private(set) var isRetrying = false

  /// What the Copy buttons copy.
  enum CopyTarget: Equatable {
    case transcript, reply, part
  }

  /// The text last copied, until the confirmation timer (``copiedDuration``) or ``clearCopied()`` ends it: the button shows "Copied" meanwhile.
  private(set) var copied: CopyTarget?
  /// Bumped on every copy; the confirmation timer of an older copy sees the newer count and leaves "Copied" alone.
  private(set) var copyCount = 0
  /// A toast for the last failed action. The id tells two toasts with the same words apart.
  struct Failure: Equatable, Identifiable {
    let id: Int
    let message: String
  }

  /// The toast on screen. It goes away after the toast duration, or at ``dismissFailure()``, whichever comes first; a
  /// newer toast takes over and its predecessor's timer is cancelled with it, so a stale timer never hides it.
  private(set) var failure: Failure?

  private let client: any APIClient
  private let pasteboard: any Pasteboard
  let media: any MemoMediaSource
  /// The app's one spoken-reply player (Play, `PlayReplyIntent` and spoken replies share it).
  let speech: SpeechPlayer
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "detail")
  private var baselinesLoaded = false
  private var toastCount = 0
  private let toastTimer: ExpiryTimer
  private let copiedTimer: ExpiryTimer
  private let copiedDuration: Duration
  private let toastDuration: Duration

  /// `memo` is what the list already knows; the steps arrive with the first ``load()``.
  init(
    memo: Memo, client: any APIClient, media: any MemoMediaSource, speech: SpeechPlayer,
    pasteboard: any Pasteboard = SystemPasteboard(), toastDuration: Duration = .seconds(4),
    copiedDuration: Duration = .seconds(1.5),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    detail = MemoDetail(memo: memo, steps: [])
    self.client = client
    self.media = media
    self.speech = speech
    self.pasteboard = pasteboard
    self.toastDuration = toastDuration
    self.copiedDuration = copiedDuration
    toastTimer = ExpiryTimer(sleep: sleep)
    copiedTimer = ExpiryTimer(sleep: sleep)
  }

  var memo: Memo { detail.memo }
  var audioRequest: MediaRequest? { media.audio(for: memo) }
  var speechRequest: MediaRequest? { media.speech(for: memo) }

  /// The parts of the transcript this memo belongs to, oldest first: the loaded thread's, else the memo alone. The open memo is
  /// always the freshest copy of itself.
  var parts: [Memo] {
    guard let thread, thread.thread.kind == "transcript" else { return [memo] }
    var parts = thread.memos.filter { !$0.isDeleted && $0.id != memo.id }
    parts.append(memo)
    return parts.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
  }

  /// Every part's words, joined in order: what Copy transcript copies.
  var wholeTranscript: String? { TranscriptText.whole(of: parts) }

  /// The thread a Continue recording takes belongs to (the first part's id); nil while the memo has no transcript to continue,
  /// since the server refuses a continuation until the first part has one.
  var continuationTarget: String? {
    guard let target = memo.transcriptThreadID else { return nil }
    let head = parts.first { $0.id == target } ?? memo
    return head.plainTranscript == nil ? nil : target
  }

  /// Reply speech exists once the memo is done and has something to say.
  var canPlayReply: Bool { memo.state == .notified && speechRequest != nil }

  /// Day · time · what the run cost, for the header of a detail screen and of the Details sheet.
  var metaLine: String {
    [HistoryDaySection.title(of: memo.createdAt), memo.timeText, totalCostUsd.map { StepText.dollars($0) }]
      .compactMap { $0 }.joined(separator: " · ")
  }

  // MARK: Waterfall

  func rows(now: Date) -> [StepWaterfallRow] {
    WaterfallBuilder.rows(for: detail, baselines: baselines, now: now)
  }

  /// The footer of the waterfall: the run's wall-clock time and summed cost.
  func totalValue(now: Date) -> String? {
    guard let totals = WaterfallBuilder.totals(for: detail, now: now) else { return nil }
    return StepText.metric(milliseconds: totals.milliseconds, costUsd: totals.costUsd)
  }

  /// What the run cost, summed over the steps that report a cost (the header's meta line); nil while none does.
  var totalCostUsd: Double? {
    WaterfallBuilder.totals(for: detail, now: .now)?.costUsd
  }

  // MARK: Copy

  /// Puts the transcript or the reply on the pasteboard as plain text (a string, no markup, no style).
  func copy(_ target: CopyTarget) {
    let text: String? =
      switch target {
      case .transcript: wholeTranscript
      case .reply: memo.plainReply
      // A single part is copied through ``copyPart(_:)``, which knows which one.
      case .part: nil
      }
    guard let text else { return }
    put(text, as: target)
  }

  /// One part's words (a bubble's own Copy).
  func copyPart(_ part: Memo) {
    guard let text = part.plainTranscript else { return }
    put(text, as: .part)
  }

  private func put(_ text: String, as target: CopyTarget) {
    pasteboard.copy(text)
    copied = target
    copyCount += 1
    copiedTimer.arm(after: copiedDuration) { [weak self] in self?.clearCopied() }
  }

  /// Ends the "Copied" confirmation: its timer, or a newer state, calls this.
  func clearCopied() {
    copiedTimer.cancel()
    copied = nil
  }

  // MARK: Loading

  /// Fetches the memo with its steps, and the stats baselines the first time. A failure keeps what is on screen.
  func load() async {
    do {
      let fresh = try await client.memo(id: memo.id)
      guard !Task.isCancelled else { return }
      detail = fresh
      await loadThread()
    } catch is CancellationError {
      return
    } catch {
      logger.error("detail load failed: \(String(describing: error), privacy: .public)")
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

  /// A transcript with more than one recording has a thread: its other parts come from there. A failed read keeps the parts on
  /// screen.
  private func loadThread() async {
    guard memo.mode == .transcribe, !memo.isDeleted, let threadId = memo.threadId else {
      thread = nil
      return
    }
    do {
      let fresh = try await client.thread(id: threadId)
      guard !Task.isCancelled else { return }
      thread = fresh
    } catch is CancellationError {
      return
    } catch {
      logger.error("transcript thread load failed: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: Retry

  /// The steps a retry can restart from: every step of the memo's pipeline up to the one that failed. A finished memo
  /// whose optional summarize step failed can restart that step alone (the server refuses any other retry on it).
  /// Empty otherwise: the server refuses a retry in any other state.
  var retrySteps: [MemoStep] {
    if memo.isSkippedOptionalStep(.summarize),
      detail.steps.contains(where: { $0.step == .summarize && $0.status == .failed })
    {
      return [.summarize]
    }
    // An old memo failed at a step the new pipeline no longer has.
    let steps =
      memo.failedStep == .route || memo.failedStep == .summarize
      ? PipelineSteps.legacy(for: memo) : PipelineSteps.applicable(to: memo)
    guard memo.state == .failed, let failed = memo.failedStep, let last = steps.firstIndex(of: failed) else {
      return []
    }
    return Array(steps[...last])
  }

  /// A plain tap on retry restarts at the step that failed.
  var primaryRetryStep: MemoStep? { retrySteps.last }

  func retry(from step: MemoStep) async {
    guard retrySteps.contains(step), !isRetrying else { return }
    isRetrying = true
    defer { isRetrying = false }
    do {
      detail.memo = try await client.retryMemo(id: memo.id, request: RetryMemoRequest(from: step))
      await load()
    } catch is CancellationError {
      return
    } catch {
      logger.error("retry failed: \(String(describing: error), privacy: .public)")
      showFailure(String(localized: "Could not retry the memo", comment: "Toast when a retry failed"))
    }
  }

  func dismissFailure() {
    toastTimer.cancel()
    failure = nil
  }

  /// Shows `message` as the toast and starts its timer; the previous toast's timer is cancelled first.
  private func showFailure(_ message: String) {
    toastCount += 1
    failure = Failure(id: toastCount, message: message)
    toastTimer.arm(after: toastDuration) { [weak self] in self?.dismissFailure() }
  }
}
