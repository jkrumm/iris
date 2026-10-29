import Foundation
import Testing

@testable import Iris

@Suite("StepText")
struct StepTextTests {
  @Test(
    "durations read in ms, tenths of seconds, then minutes",
    arguments: [
      (12, "12 ms"), (999, "999 ms"), (1_000, "1.0 s"), (8_500, "8.5 s"), (27_549, "27.5 s"), (64_000, "1 min 4 s"),
      (120_000, "2 min"), (-5, "0 ms"),
    ])
  func duration(ms: Int, expected: String) {
    #expect(StepText.duration(milliseconds: ms).replacingOccurrences(of: ",", with: ".") == expected)
  }

  @Test("the chip is duration · cost, and only the duration for a free step")
  func metric() {
    let english = Locale(identifier: "en_US")
    #expect(
      StepText.metric(milliseconds: 1_800, costUsd: 0.0412, locale: english).replacingOccurrences(of: ",", with: ".")
        == "1.8 s · $0.04"
    )
    #expect(StepText.metric(milliseconds: 12, costUsd: nil) == "12 ms")
  }

  @Test("the chip writes money in the user's locale, with no fixed dollar sign")
  func metricLocale() {
    let german = StepText.metric(milliseconds: 64_000, costUsd: 1.6, locale: Locale(identifier: "de_DE"))
    #expect(plain(german) == "1 min 4 s · 1,60 $")
  }

  /// The currency pattern puts a no-break space between the amount and the symbol; compare with a plain one.
  private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
  }

  @Test("a dollar total has two decimals in the user's locale, never four")
  func dollars() {
    #expect(StepText.dollars(1.62, locale: Locale(identifier: "en_US")) == "$1.62")
    #expect(plain(StepText.dollars(1.62, locale: Locale(identifier: "de_DE"))) == "1,62 $")
    #expect(StepText.dollars(1.6, locale: Locale(identifier: "en_US")) == "$1.60")
    #expect(plain(StepText.dollars(1.6, locale: Locale(identifier: "de_DE"))) == "1,60 $")
    #expect(StepText.dollars(0, locale: Locale(identifier: "en_US")) == "$0.00")
  }
}
