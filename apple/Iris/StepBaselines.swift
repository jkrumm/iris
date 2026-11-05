import IrisCore

/// "Faster / slower than usual" for one step against the stats medians (`GET /v1/stats`), and only where the
/// comparison means something: the same step and memo kind with enough samples, a median long enough not to be noise,
/// and a deviation large enough to call. Everywhere else the answer is `nil` and the UI says nothing.
nonisolated struct StepBaselines: Equatable {
  /// Samples a (step, kind) median needs before the client compares against it.
  static let minimumSamples = 5
  /// A step within this share of its median is "typical" and gets no tag.
  static let significantDeviation = 0.15
  /// Medians below this are scheduler noise (a 3 ms step is not "50 % slower" at 5 ms).
  static let minimumMedianMs = 250

  enum Comparison: Equatable {
    case faster(percent: Int)
    case slower(percent: Int)
  }

  private struct Key: Hashable {
    let step: MemoStep
    let kind: String?
  }

  private let medians: [Key: StatsStepMedian]

  /// Kinds are lower-case on the wire; compare them that way.
  private static func normalized(_ kind: String?) -> String? {
    kind?.lowercased()
  }

  init(_ stats: Stats? = nil) {
    var medians: [Key: StatsStepMedian] = [:]
    for median in stats?.stepMedians ?? [] {
      medians[Key(step: median.step, kind: Self.normalized(median.kind))] = median
    }
    self.medians = medians
  }

  /// `kind` is the memo's kind, `nil` for a memo that has none (transcribe, or not classified).
  func comparison(step: MemoStep, kind: String?, durationMs: Int) -> Comparison? {
    guard let median = medians[Key(step: step, kind: Self.normalized(kind))], median.samples >= Self.minimumSamples,
      median.medianMs >= Self.minimumMedianMs
    else { return nil }
    let delta = Double(durationMs - median.medianMs) / Double(median.medianMs)
    guard abs(delta) >= Self.significantDeviation else { return nil }
    let percent = Int((abs(delta) * 100).rounded())
    return delta > 0 ? .slower(percent: percent) : .faster(percent: percent)
  }
}
