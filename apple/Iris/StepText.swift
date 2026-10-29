import Foundation

/// How a step's duration and cost read on its metric chip: "12 ms", "8.5 s", "1 min 4 s" and "$0.04".
/// Money (``dollars(_:locale:)``) follows the user's locale with two decimals and no fixed symbol: "$1.62" in en_US,
/// "1,62 $" in de_DE.
nonisolated enum StepText {
  static func duration(milliseconds: Int) -> String {
    let ms = max(milliseconds, 0)
    if ms < 1_000 { return "\(ms) ms" }
    if ms < 60_000 { return "\(Self.tenths(Double(ms) / 1_000)) s" }
    let seconds = (ms + 500) / 1_000
    return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
  }

  /// US dollars as the locale writes money, two decimals: the step chip, the waterfall total and the Stats tiles.
  static func dollars(_ usd: Double, locale: Locale = .current) -> String {
    usd.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
  }

  /// `duration · cost`, the cost left out when the step has none (route and notify cost nothing).
  static func metric(milliseconds: Int, costUsd: Double?, locale: Locale = .current) -> String {
    guard let costUsd else { return duration(milliseconds: milliseconds) }
    return "\(duration(milliseconds: milliseconds)) · \(dollars(costUsd, locale: locale))"
  }

  private static func tenths(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
  }
}
