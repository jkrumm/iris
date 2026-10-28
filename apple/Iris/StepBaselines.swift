import IrisCore

/// "Faster / slower than usual" for one step against the stats medians (`GET /v1/stats`), and only where the
/// comparison means something: the same step and route with enough samples, a median long enough not to be noise,
/// and a deviation large enough to call. Everywhere else the answer is `nil` and the UI says nothing.
nonisolated struct StepBaselines: Equatable {
  /// Samples a (step, route) median needs before the client compares against it.
  static let minimumSamples = 5
  /// A step within this share of its median is "typical" and gets no tag.
  static let significantDeviation = 0.15
  /// Medians below this are scheduler noise (a 3 ms route step is not "50 % slower" at 5 ms).
  static let minimumMedianMs = 250

  enum Comparison: Equatable {
    case faster(percent: Int)
    case slower(percent: Int)
  }

  private struct Key: Hashable {
    let step: MemoStep
    let route: String
  }

  private let medians: [Key: StatsStepMedian]

  init(_ stats: Stats? = nil) {
    var medians: [Key: StatsStepMedian] = [:]
    for median in stats?.stepMedians ?? [] {
      medians[Key(step: median.step, route: median.route)] = median
    }
    self.medians = medians
  }

  /// `route` is the memo's route, `"unrouted"` for a memo that has none (the stats' name for `null`).
  func comparison(step: MemoStep, route: String, durationMs: Int) -> Comparison? {
    guard let median = medians[Key(step: step, route: route)], median.samples >= Self.minimumSamples,
      median.medianMs >= Self.minimumMedianMs
    else { return nil }
    let delta = Double(durationMs - median.medianMs) / Double(median.medianMs)
    guard abs(delta) >= Self.significantDeviation else { return nil }
    let percent = Int((abs(delta) * 100).rounded())
    return delta > 0 ? .slower(percent: percent) : .faster(percent: percent)
  }
}
