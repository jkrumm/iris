import Foundation

/// How a step's duration and cost read on its metric chip: "12 ms", "8.5 s", "1 min 4 s" and "$0.04".
/// Money (``dollars(_:locale:)``) follows the user's locale and no fixed symbol: "$1.62" in en_US, "1,62 $" in de_DE.
/// From a cent up it has two decimals; below that four, so a real cost never reads "$0.00" ("$0.0002"), and below
/// a hundredth of a cent it reads "<$0.0001". Zero is "$0".
nonisolated enum StepText {
  static func duration(milliseconds: Int) -> String {
    let ms = max(milliseconds, 0)
    if ms < 1_000 { return "\(ms) ms" }
    if ms < 60_000 { return "\(Self.tenths(Double(ms) / 1_000)) s" }
    let seconds = (ms + 500) / 1_000
    return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
  }

  /// US dollars as the locale writes money: the step chip, the waterfall total and the Stats tiles.
  static func dollars(_ usd: Double, locale: Locale = .current) -> String {
    func money(_ value: Double, fraction: Int) -> String {
      value.formatted(.currency(code: "USD").precision(.fractionLength(fraction)).locale(locale))
    }
    let amount = max(usd, 0)
    if amount == 0 { return money(0, fraction: 0) }
    if amount >= smallestCent { return money(amount, fraction: 2) }
    if amount < smallestShown { return "<" + money(smallestShown, fraction: 4) }
    return money(amount, fraction: 4)
  }

  /// A cent: from here on two decimals say enough.
  private static let smallestCent = 0.01
  /// A hundredth of a cent: below it the amount is only "less than".
  private static let smallestShown = 0.0001

  /// `duration · cost`, the cost left out when the step has none (route and notify cost nothing).
  static func metric(milliseconds: Int, costUsd: Double?, locale: Locale = .current) -> String {
    guard let costUsd else { return duration(milliseconds: milliseconds) }
    return "\(duration(milliseconds: milliseconds)) · \(dollars(costUsd, locale: locale))"
  }

  private static func tenths(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
  }
}
