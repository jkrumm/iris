import Foundation
import IrisCore
import IrisUI
import Testing

@testable import Iris

@MainActor
@Suite("WaterfallBuilder")
struct WaterfallBuilderTests {
  private let now = MemoFactory.now.addingTimeInterval(1_000)

  /// A 20 s run up to summarize: transcribe 0-8 s, route 8-8.01 s, act 8.1-18.1 s, summarize 18.2-20 s.
  private func finished(_ memo: Memo = MemoFactory.memo("m", state: .summarized, route: "hermes")) -> MemoDetail {
    MemoFactory.detail(
      memo,
      steps: [
        MemoFactory.step(.transcribe, at: 0, for: 8, cost: 0.004),
        MemoFactory.step(.route, at: 8, for: 0.01),
        MemoFactory.step(.act, at: 8.1, for: 10, cost: 0.04),
        MemoFactory.step(.summarize, at: 18.2, for: 1.8, cost: 0.002),
      ])
  }

  @Test("each bar starts where its step started and is as wide as it ran, as fractions of the whole run")
  func scaling() {
    let rows = WaterfallBuilder.rows(for: finished(), baselines: StepBaselines(), now: now)
    #expect(rows.prefix(4).map(\.id) == ["transcribe", "route", "act", "summarize"])
    #expect(rows[0].start == 0)
    #expect(abs(rows[0].length - 0.4) < 1e-6)
    #expect(abs(rows[2].start - 0.405) < 1e-6)
    #expect(abs(rows[2].length - 0.5) < 1e-6)
    #expect(abs(rows[3].start + rows[3].length - 1) < 1e-6)
  }

  @Test("the metric chip joins duration and cost; a free step shows the duration alone")
  func metrics() {
    let rows = WaterfallBuilder.rows(for: finished(), baselines: StepBaselines(), now: now)
    #expect(rows[0].metric == "\(StepText.duration(milliseconds: 8_000)) · \(StepText.dollars(0.004))")
    #expect(rows[1].metric == "10 ms")
  }

  @Test("steps still to come follow as waiting rows; a finished memo has none")
  func waiting() {
    let rows = WaterfallBuilder.rows(for: finished(), baselines: StepBaselines(), now: now)
    #expect(rows.map(\.phase) == [.done, .done, .done, .done, .waiting])
    #expect(rows.last?.id == "notify")

    var done = finished(MemoFactory.memo("m", state: .notified, route: "hermes"))
    done.steps.append(MemoFactory.step(.notify, at: 20, for: 0.5))
    #expect(WaterfallBuilder.rows(for: done, baselines: StepBaselines(), now: now).allSatisfy { $0.phase == .done })
  }

  @Test("a typed memo never waits for a transcribe step")
  func typedSkipsTranscribe() {
    let memo = MemoFactory.memo("t", state: .transcribed, typed: true)
    let rows = WaterfallBuilder.rows(for: MemoFactory.detail(memo), baselines: StepBaselines(), now: now)
    #expect(rows.map(\.id) == ["route", "act", "summarize", "notify"])
  }

  @Test("the act step is named for where it went")
  func actTitle() {
    let hermes = WaterfallBuilder.rows(for: finished(), baselines: StepBaselines(), now: now)
    #expect(hermes[2].title == "Act · Hermes")
  }

  @Test("faster and slower show only for a finished step with a baseline of enough samples")
  func badges() {
    let thin = Stats(
      days: 30, from: "a", to: "b",
      stepMedians: [
        StatsStepMedian(step: .act, route: "hermes", medianMs: 5_000, samples: StepBaselines.minimumSamples - 1)
      ])
    #expect(WaterfallBuilder.rows(for: finished(), baselines: StepBaselines(thin), now: now)[2].badge == nil)

    let enough = Stats(
      days: 30, from: "a", to: "b",
      stepMedians: [
        StatsStepMedian(step: .act, route: "hermes", medianMs: 5_000, samples: StepBaselines.minimumSamples),
        StatsStepMedian(step: .summarize, route: "hermes", medianMs: 3_000, samples: 30),
      ])
    let rows = WaterfallBuilder.rows(for: finished(), baselines: StepBaselines(enough), now: now)
    #expect(rows[2].badge?.tone == .slower)
    #expect(rows[2].badge?.text.contains("100") == true)
    #expect(rows[3].badge?.tone == .faster)
    #expect(rows[0].badge == nil)
  }

  @Test("attempts show only above one, the error and the retry only on the step that failed")
  func attemptsAndRetry() {
    let memo = MemoFactory.memo("f", state: .failed, route: "tab", failedStep: .summarize)
    let detail = MemoFactory.detail(
      memo,
      steps: [
        MemoFactory.step(.act, at: 0, for: 2, attempts: 2),
        MemoFactory.step(.summarize, at: 2, for: 7, status: .failed, attempts: 3, error: "upstream 503"),
      ])
    let rows = WaterfallBuilder.rows(for: detail, baselines: StepBaselines(), now: now)
    #expect(rows[0].attempts == "2 attempts")
    #expect(rows[0].retryTitle == nil)
    #expect(rows[1].attempts == "3 attempts")
    #expect(rows[1].phase == .failed)
    #expect(rows[1].error == "upstream 503")
    #expect(rows[1].retryTitle == "Retry from Summarize")
    #expect(rows[2].phase == .waiting)

    let single = WaterfallBuilder.rows(for: finished(), baselines: StepBaselines(), now: now)
    #expect(single.allSatisfy { $0.attempts == nil })
  }

  @Test("a running step's bar runs up to now")
  func running() {
    let memo = MemoFactory.memo("r", state: .acted, route: "hermes")
    let detail = MemoFactory.detail(
      memo,
      steps: [
        MemoFactory.step(.transcribe, at: 0, for: 10),
        MemoFactory.step(.summarize, at: 10, for: 0, status: .running),
      ])
    let rows = WaterfallBuilder.rows(
      for: detail, baselines: StepBaselines(), now: MemoFactory.now.addingTimeInterval(20))
    #expect(rows[1].phase == .running)
    #expect(abs(rows[1].start - 0.5) < 1e-6)
    #expect(abs(rows[1].length - 0.5) < 1e-6)
  }

  @Test("totals span the run and sum the costs; no step, no total")
  func totals() {
    let total = WaterfallBuilder.totals(for: finished(), now: now)
    #expect(total?.milliseconds == 20_000)
    #expect(abs((total?.costUsd ?? 0) - 0.046) < 1e-6)
    #expect(WaterfallBuilder.totals(for: MemoFactory.detail(MemoFactory.memo("e")), now: now) == nil)
  }

  @Test("a failed summarize on a finished memo is failed-but-optional and still offers its retry")
  func skippedSummarize() {
    let memo = MemoFactory.memo("s", state: .notified, route: "hermes")
    let detail = MemoFactory.detail(
      memo,
      steps: [
        MemoFactory.step(.transcribe, at: 0, for: 8),
        MemoFactory.step(.route, at: 8, for: 0.01),
        MemoFactory.step(.act, at: 8.1, for: 10),
        MemoFactory.step(.summarize, at: 18.2, for: 3, status: .failed, attempts: 3, error: "402"),
        MemoFactory.step(.notify, at: 21.3, for: 1),
      ])
    let rows = WaterfallBuilder.rows(for: detail, baselines: StepBaselines(), now: now)
    let summarize = rows[3]
    #expect(summarize.phase == .failed)
    #expect(summarize.isOptional)
    #expect(summarize.optionalNote != nil)
    #expect(summarize.error == "402")
    #expect(summarize.attempts == "3 attempts")
    #expect(summarize.retryTitle == "Retry from Summarize")
    #expect(rows[4].phase == .done)
    #expect(rows.filter(\.isOptional).count == 1)
  }

  @Test("a failed step of a failed memo is the memo's failure, not an optional one")
  func failedMemoIsNotOptional() {
    let memo = MemoFactory.memo("f", state: .failed, route: "hermes", failedStep: .summarize, error: "boom")
    let detail = MemoFactory.detail(
      memo, steps: [MemoFactory.step(.summarize, at: 0, for: 3, status: .failed, error: "boom")])
    let row = WaterfallBuilder.rows(for: detail, baselines: StepBaselines(), now: now)[0]
    #expect(!row.isOptional)
    #expect(row.optionalNote == nil)
    #expect(row.retryTitle == "Retry from Summarize")
  }
}
