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
    #expect(
      StepText.metric(milliseconds: 1_800, costUsd: 0.004).replacingOccurrences(of: ",", with: ".") == "1.8 s · $0.0040"
    )
    #expect(StepText.metric(milliseconds: 12, costUsd: nil) == "12 ms")
  }
}
