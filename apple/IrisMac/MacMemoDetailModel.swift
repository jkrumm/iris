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

/// One memo open in the detail panel: its steps, the stats baselines the step durations are judged against, Copy and
/// retry. The iOS `MemoDetailModel` also owns the recording and spoken-reply players, which wait on a macOS-safe
/// `MemoPlayer` (it configures an `AVAudioSession`), so playback is not part of this panel yet.
@Observable
final class MacMemoDetailModel {
  enum CopyTarget: Equatable {
    case transcript, reply
  }

  /// `nil` until the memo is known: the list had it when the panel opened, else the first ``load()`` brings it.
  private(set) var detail: MemoDetail?
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
  }

  var memo: Memo? { detail?.memo }

  /// The step rows show under the waterfall's total line: collapsed until the owner opens them, except for a failed memo,
  /// whose failed step (and its retry) is what the owner came for.
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
    do {
      let fresh = try await client.memo(id: memoID)
      guard !Task.isCancelled else { return }
      detail = fresh
      loadFailed = false
    } catch is CancellationError {
      return
    } catch {
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
      detail?.memo = try await client.retryMemo(id: memoID, request: RetryMemoRequest(from: step))
      await load()
    } catch is CancellationError {
      return
    } catch {
      logger.error("retry failed: \(String(describing: error), privacy: .public)")
      failure = String(localized: "Could not retry the memo", comment: "Detail: a retry failed")
    }
  }
}
