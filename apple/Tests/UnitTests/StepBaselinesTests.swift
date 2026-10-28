import IrisCore
import Testing

@testable import Iris

@Suite("StepBaselines")
struct StepBaselinesTests {
  private func baselines(median: Int = 8_000, samples: Int, route: String = "hermes") -> StepBaselines {
    StepBaselines(
      Stats(
        days: 30, from: "2026-09-28", to: "2026-10-27",
        stepMedians: [StatsStepMedian(step: .act, route: route, medianMs: median, samples: samples)]))
  }

  @Test("the threshold is named, and a median below it compares nothing")
  func thresholdSamples() {
    #expect(StepBaselines.minimumSamples == 5)
    let slow = 12_000
    #expect(
      baselines(samples: StepBaselines.minimumSamples - 1).comparison(step: .act, route: "hermes", durationMs: slow)
        == nil)
    #expect(
      baselines(samples: StepBaselines.minimumSamples).comparison(step: .act, route: "hermes", durationMs: slow)
        == .slower(percent: 50))
  }

  @Test("slower, faster and typical against the median")
  func deviation() {
    let stats = baselines(samples: 30)
    #expect(stats.comparison(step: .act, route: "hermes", durationMs: 11_360) == .slower(percent: 42))
    #expect(stats.comparison(step: .act, route: "hermes", durationMs: 6_000) == .faster(percent: 25))
    // 14 % off is inside the band, exactly 15 % is outside it.
    #expect(stats.comparison(step: .act, route: "hermes", durationMs: 9_120) == nil)
    #expect(stats.comparison(step: .act, route: "hermes", durationMs: 9_200) == .slower(percent: 15))
  }

  @Test("another step or route has no baseline of its own")
  func keyedByStepAndRoute() {
    let stats = baselines(samples: 30)
    #expect(stats.comparison(step: .summarize, route: "hermes", durationMs: 99_000) == nil)
    #expect(stats.comparison(step: .act, route: "journal", durationMs: 99_000) == nil)
    #expect(StepBaselines().comparison(step: .act, route: "hermes", durationMs: 99_000) == nil)
  }

  @Test("a sub-second median is noise, not a baseline")
  func tinyMedians() {
    let stats = baselines(median: StepBaselines.minimumMedianMs - 1, samples: 30)
    #expect(stats.comparison(step: .act, route: "hermes", durationMs: 2_000) == nil)
  }
}
