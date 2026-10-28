import Foundation

/// How a step's duration and cost read on its metric chip: "12 ms", "8.5 s", "1 min 4 s" and "$0.0038".
/// A total (``dollars(_:locale:)``) follows the user's locale: "$1.62" in en_US, "1,62 $" in de_DE.
nonisolated enum StepText {
  static func duration(milliseconds: Int) -> String {
    let ms = max(milliseconds, 0)
    if ms < 1_000 { return "\(ms) ms" }
    if ms < 60_000 { return "\(Self.tenths(Double(ms) / 1_000)) s" }
    let seconds = (ms + 500) / 1_000
    return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
  }

  /// Four decimals: a step costs fractions of a cent, and rounding to cents would hide all of it.
  static func cost(_ usd: Double) -> String {
    "$" + usd.formatted(.number.precision(.fractionLength(4)))
  }

  /// Two decimals, for a total that is worth cents (the Stats cost tile).
  static func dollars(_ usd: Double, locale: Locale = .current) -> String {
    usd.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
  }

  /// `duration · cost`, the cost left out when the step has none (route and notify cost nothing).
  static func metric(milliseconds: Int, costUsd: Double?) -> String {
    guard let costUsd else { return duration(milliseconds: milliseconds) }
    return "\(duration(milliseconds: milliseconds)) · \(cost(costUsd))"
  }

  private static func tenths(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
  }
}
