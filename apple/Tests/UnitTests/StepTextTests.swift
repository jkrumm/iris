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

  @Test("from a cent up money has two decimals in the user's locale")
  func dollars() {
    #expect(StepText.dollars(1.62, locale: Locale(identifier: "en_US")) == "$1.62")
    #expect(plain(StepText.dollars(1.62, locale: Locale(identifier: "de_DE"))) == "1,62 $")
    #expect(StepText.dollars(1.6, locale: Locale(identifier: "en_US")) == "$1.60")
    #expect(plain(StepText.dollars(1.6, locale: Locale(identifier: "de_DE"))) == "1,60 $")
    #expect(StepText.dollars(0.0412, locale: Locale(identifier: "en_US")) == "$0.04")
    #expect(StepText.dollars(0.01, locale: Locale(identifier: "en_US")) == "$0.01")
  }

  @Test(
    "a real cost never reads $0.00: four decimals below a cent, less-than below a hundredth of a cent, zero is $0",
    arguments: [
      (0.0002, "$0.0002"), (0.0038, "$0.0038"), (0.00999, "$0.0100"), (0.0001, "$0.0001"), (0.00004, "<$0.0001"),
      (1e-9, "<$0.0001"), (0, "$0"), (-0.5, "$0"),
    ])
  func smallDollars(usd: Double, expected: String) {
    #expect(StepText.dollars(usd, locale: Locale(identifier: "en_US")) == expected)
  }

  @Test("small amounts follow the locale too")
  func smallDollarsLocale() {
    let german = Locale(identifier: "de_DE")
    #expect(plain(StepText.dollars(0.0002, locale: german)) == "0,0002 $")
    #expect(plain(StepText.dollars(0.00001, locale: german)) == "<0,0001 $")
  }

  @Test("the chip never shows a free-looking cost for a real one")
  func metricSmallCost() {
    #expect(
      StepText.metric(milliseconds: 8_500, costUsd: 0.0002, locale: Locale(identifier: "en_US"))
        .replacingOccurrences(of: ",", with: ".") == "8.5 s · $0.0002")
  }

  /// The IrisUI snapshot fixtures hold finished strings (the package cannot reach `StepText`); these are the costs they
  /// show, so a change to the formatter fails here instead of leaving the references showing a cost the app never writes.
  @Test(
    "the waterfall snapshot fixtures show costs as the formatter writes them",
    arguments: [
      (0.0002, "$0.0002"), (0.0004, "$0.0004"), (0.0012, "$0.0012"), (0.0021, "$0.0021"), (0.0038, "$0.0038"),
      (0.0412, "$0.04"), (0.0414, "$0.04"), (0.0416, "$0.04"), (0.0471, "$0.05"), (0.0313, "$0.03"),
    ])
  func snapshotFixtureCosts(usd: Double, shown: String) {
    #expect(StepText.dollars(usd, locale: Locale(identifier: "en_US")) == shown)
  }
}
