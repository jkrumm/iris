import Foundation
import IrisCore
import IrisUI

/// Turns a memo's step timeline into the waterfall rows: the time axis is the whole run, each bar starts where the
/// step started and is as wide as it ran. Steps still to come follow as "waiting" rows.
enum WaterfallBuilder {
  /// The total of a run: its wall-clock span and the summed cost (nil when no step has one).
  struct Totals: Equatable {
    var milliseconds: Int
    var costUsd: Double?
  }

  static func rows(for detail: MemoDetail, baselines: StepBaselines, now: Date) -> [StepWaterfallRow] {
    let memo = detail.memo
    let entries = detail.steps.filter { $0.step != .ingest }
    let span = span(of: entries, now: now)
    let route = memo.route ?? "unrouted"

    var rows = entries.map { entry -> StepWaterfallRow in
      let ms = durationMs(entry, now: now)
      let title = title(of: entry.step, memo: memo)
      return StepWaterfallRow(
        id: entry.step.rawValue,
        title: title,
        phase: phase(of: entry.status),
        metric: StepText.metric(milliseconds: ms, costUsd: entry.costUsd),
        badge: entry.status == .done
          ? baselines.comparison(step: entry.step, route: route, durationMs: ms).map(badge(for:)) : nil,
        attempts: entry.attempts > 1
          ? String(localized: "\(entry.attempts) attempts", comment: "Step row: how many tries the step used") : nil,
        error: entry.status == .failed ? entry.error : nil,
        retryTitle: memo.state == .failed && memo.failedStep == entry.step
          ? String(localized: "Retry from \(entry.step.title)", comment: "Button on the step a memo failed at") : nil,
        start: span.fraction(of: entry.startedAt),
        length: span.length == 0 ? 0 : Double(ms) / 1_000 / span.length)
    }
    rows += pending(after: entries, memo: memo).map {
      StepWaterfallRow(
        id: $0.rawValue, title: title(of: $0, memo: memo), phase: .waiting,
        metric: String(localized: "waiting", comment: "Step that has not started"))
    }
    return rows
  }

  static func totals(for detail: MemoDetail, now: Date) -> Totals? {
    let entries = detail.steps.filter { $0.step != .ingest }
    guard !entries.isEmpty else { return nil }
    let costs = entries.compactMap(\.costUsd)
    return Totals(
      milliseconds: Int((span(of: entries, now: now).length * 1_000).rounded()),
      costUsd: costs.isEmpty ? nil : costs.reduce(0, +))
  }

  // MARK: Steps

  /// "Act · Hermes": the act step is named for where it went.
  private static func title(of step: MemoStep, memo: Memo) -> String {
    guard step == .act, memo.route != nil else { return step.title }
    return "\(step.title) · \(memo.routeLabel)"
  }

  private static func phase(of status: StepStatus) -> StepWaterfallRow.Phase {
    switch status {
    case .running: .running
    case .done: .done
    case .failed: .failed
    }
  }

  private static func badge(for comparison: StepBaselines.Comparison) -> StepWaterfallRow.Badge {
    switch comparison {
    case .slower(let percent):
      .init(text: String(localized: "+\(percent) % slower", comment: "Step ran slower than its median"), tone: .slower)
    case .faster(let percent):
      .init(text: String(localized: "−\(percent) % faster", comment: "Step ran faster than its median"), tone: .faster)
    }
  }

  /// The steps after the last one the timeline holds. A typed memo skips transcribe; before anything ran the
  /// whole pipeline is ahead.
  private static func pending(after entries: [StepEntry], memo: Memo) -> [MemoStep] {
    guard memo.state != .notified else { return [] }
    var remaining = PipelineSteps.shown
    if memo.isTyped { remaining.removeAll { $0 == .transcribe } }
    guard let last = entries.map(\.step).compactMap(PipelineSteps.shown.firstIndex(of:)).max() else { return remaining }
    return PipelineSteps.shown[(last + 1)...].filter(remaining.contains)
  }

  // MARK: Time

  /// The run's axis: from the first start to the last finish (a running step counts up to `now`).
  private struct Span {
    let start: Date
    let length: TimeInterval

    func fraction(of date: Date) -> Double {
      length == 0 ? 0 : date.timeIntervalSince(start) / length
    }
  }

  private static func span(of entries: [StepEntry], now: Date) -> Span {
    guard let start = entries.map(\.startedAt).min() else { return Span(start: now, length: 0) }
    let end = entries.map { $0.finishedAt ?? ($0.status == .running ? now : $0.startedAt) }.max() ?? start
    return Span(start: start, length: max(end.timeIntervalSince(start), 0))
  }

  private static func durationMs(_ entry: StepEntry, now: Date) -> Int {
    let end = entry.finishedAt ?? (entry.status == .running ? now : entry.startedAt)
    return max(Int((end.timeIntervalSince(entry.startedAt) * 1_000).rounded()), 0)
  }
}
