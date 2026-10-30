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
  private(set) var baselines = StepBaselines()
  private(set) var isRetrying = false
  /// The owner's own open or close of the waterfall; nil until the first tap.
  private var waterfallChoice: Bool?

  /// The step rows show under the waterfall's total line: collapsed until the owner opens them, except for a failed
  /// memo, whose failed step (and its retry) is what the owner came for. A tap wins over that default.
  var isWaterfallExpanded: Bool {
    get { waterfallChoice ?? (memo.state == .failed) }
    set { waterfallChoice = newValue }
  }

  /// What the Copy buttons copy.
  enum CopyTarget: Equatable {
    case transcript, reply
  }

  /// The text last copied, until ``clearCopied()``: the button shows "Copied" meanwhile.
  private(set) var copied: CopyTarget?
  /// Bumped on every copy, so a second copy restarts the view's confirmation timer.
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
  private var toastTimer: Task<Void, Never>?
  private let toastDuration: Duration
  private let sleep: @Sendable (Duration) async throws -> Void

  /// `memo` is what the list already knows; the steps arrive with the first ``load()``.
  init(
    memo: Memo, client: any APIClient, media: any MemoMediaSource, speech: SpeechPlayer,
    pasteboard: any Pasteboard = SystemPasteboard(), toastDuration: Duration = .seconds(4),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    detail = MemoDetail(memo: memo, steps: [])
    self.client = client
    self.media = media
    self.speech = speech
    self.pasteboard = pasteboard
    self.toastDuration = toastDuration
    self.sleep = sleep
  }

  var memo: Memo { detail.memo }
  var audioRequest: MediaRequest? { media.audio(for: memo) }
  var speechRequest: MediaRequest? { media.speech(for: memo) }

  /// Reply speech exists once the memo is done and has something to say.
  var canPlayReply: Bool { memo.state == .notified && speechRequest != nil }

  /// Reply is I3's composer; the button is live for a finished memo so the hook has a place to land. A transcript-only
  /// memo has no answer to reply to.
  var canReply: Bool { memo.state == .notified && memo.mode != .transcribe }

  // MARK: Waterfall

  func rows(now: Date) -> [StepWaterfallRow] {
    WaterfallBuilder.rows(for: detail, baselines: baselines, now: now)
  }

  /// The footer of the waterfall: the run's wall-clock time and summed cost.
  func totalValue(now: Date) -> String? {
    guard let totals = WaterfallBuilder.totals(for: detail, now: now) else { return nil }
    return StepText.metric(milliseconds: totals.milliseconds, costUsd: totals.costUsd)
  }

  // MARK: Copy

  /// Puts the transcript or the reply on the pasteboard as plain text (a string, no markup, no style).
  func copy(_ target: CopyTarget) {
    let text =
      switch target {
      case .transcript: memo.plainTranscript
      case .reply: memo.plainReply
      }
    guard let text else { return }
    pasteboard.copy(text)
    copied = target
    copyCount += 1
  }

  func clearCopied() { copied = nil }

  // MARK: Loading

  /// Fetches the memo with its steps, and the stats baselines the first time. A failure keeps what is on screen.
  func load() async {
    do {
      let fresh = try await client.memo(id: memo.id)
      guard !Task.isCancelled else { return }
      detail = fresh
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
    let steps = PipelineSteps.applicable(to: memo)
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

  /// The server accepted a route for the memo: the screen shows the answer at once and reloads the timeline.
  func didRoute(_ routed: Memo) async {
    detail.memo = routed
    await load()
  }

  func dismissFailure() {
    toastTimer?.cancel()
    toastTimer = nil
    failure = nil
  }

  /// Shows `message` as the toast and starts its timer; the previous toast's timer is cancelled first.
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
