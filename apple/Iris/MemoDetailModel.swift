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
  /// The words of the last failed action, shown as a toast and cleared by ``dismissFailure()``.
  private(set) var failure: String?

  private let client: any APIClient
  private let media: any MemoMediaSource
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "detail")
  private var baselinesLoaded = false

  /// `memo` is what the list already knows; the steps arrive with the first ``load()``.
  init(memo: Memo, client: any APIClient, media: any MemoMediaSource) {
    detail = MemoDetail(memo: memo, steps: [])
    self.client = client
    self.media = media
  }

  var memo: Memo { detail.memo }
  var audioRequest: MediaRequest? { media.audio(for: memo) }
  var speechRequest: MediaRequest? { media.speech(for: memo) }

  /// Reply speech exists once the memo is done and has something to say.
  var canPlayReply: Bool { memo.state == .notified && speechRequest != nil }

  /// Reply is I3's composer; the button is live for a finished memo so the hook has a place to land.
  var canReply: Bool { memo.state == .notified }

  // MARK: Waterfall

  func rows(now: Date) -> [StepWaterfallRow] {
    WaterfallBuilder.rows(for: detail, baselines: baselines, now: now)
  }

  /// The footer of the waterfall: the run's wall-clock time and summed cost.
  func totalValue(now: Date) -> String? {
    guard let totals = WaterfallBuilder.totals(for: detail, now: now) else { return nil }
    return StepText.metric(milliseconds: totals.milliseconds, costUsd: totals.costUsd)
  }

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

  /// The steps a retry can restart from: every step of the memo's pipeline up to the one that failed. Empty unless
  /// the memo failed: the server refuses a retry in any other state.
  var retrySteps: [MemoStep] {
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
      failure = String(localized: "Could not retry the memo", comment: "Toast when a retry failed")
    }
  }

  func dismissFailure() {
    failure = nil
  }
}
