#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct StepWaterfallSnapshotTests {
    private func frame(_ view: some View) -> some View {
      view.padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.md)
    }

    @Test("a finished run: faster and slower tags only where there is a baseline", .tags(.snapshot))
    func done() {
      let rows = [
        StepWaterfallRow(
          id: "transcribe", title: "Transcribe", phase: .done, metric: "8.5 s · $0.0038", start: 0, length: 0.309),
        StepWaterfallRow(id: "route", title: "Route", phase: .done, metric: "12 ms", start: 0.309, length: 0.001),
        StepWaterfallRow(
          id: "act", title: "Act · Hermes", phase: .done, metric: "11.4 s · $0.0412",
          badge: .init(text: "+39 % slower", tone: .slower), start: 0.31, length: 0.415),
        StepWaterfallRow(
          id: "summarize", title: "Summarize", phase: .done, metric: "5.7 s · $0.0021",
          badge: .init(text: "−17 % faster", tone: .faster), start: 0.725, length: 0.208),
        StepWaterfallRow(id: "notify", title: "Notify", phase: .done, metric: "1.9 s", start: 0.933, length: 0.067),
      ]
      SnapshotSupport.assertLightAndDark(
        frame(StepWaterfall(rows: rows, totalTitle: "Total", totalValue: "27.5 s · $0.0471")),
        width: 390, height: 420)
    }

    @Test("a failed run: the attempts, the error, retry from the step, and a waiting step", .tags(.snapshot))
    func failed() {
      let rows = [
        StepWaterfallRow(
          id: "transcribe", title: "Transcribe", phase: .done, metric: "3.1 s · $0.0012", start: 0, length: 0.252),
        StepWaterfallRow(id: "route", title: "Route", phase: .done, metric: "9 ms", start: 0.252, length: 0.001),
        StepWaterfallRow(
          id: "act", title: "Act · dotfiles", phase: .done, metric: "2.2 s", start: 0.253, length: 0.179),
        StepWaterfallRow(
          id: "summarize", title: "Summarize", phase: .failed, metric: "7.0 s", attempts: "3 attempts",
          error: "agw job failed: upstream 503", retryTitle: "Retry from Summarize", start: 0.432, length: 0.568),
        StepWaterfallRow(id: "notify", title: "Notify", phase: .waiting, metric: "waiting"),
      ]
      SnapshotSupport.assertLightAndDark(
        frame(StepWaterfall(rows: rows, totalTitle: "Total", totalValue: "12.3 s · $0.0012")),
        width: 390, height: 520)
    }

    @Test("a running step has a half-strength bar", .tags(.snapshot))
    func running() {
      let rows = [
        StepWaterfallRow(
          id: "transcribe", title: "Transcribe", phase: .done, metric: "3.2 s · $0.0012", start: 0, length: 0.06),
        StepWaterfallRow(id: "act", title: "Act · Hermes", phase: .done, metric: "40.0 s", start: 0.06, length: 0.77),
        StepWaterfallRow(
          id: "summarize", title: "Summarize", phase: .running, metric: "8.0 s", start: 0.83, length: 0.17),
        StepWaterfallRow(id: "notify", title: "Notify", phase: .waiting, metric: "waiting"),
      ]
      SnapshotSupport.assertLightAndDark(
        frame(StepWaterfall(rows: rows, totalTitle: "Total so far", totalValue: "52.0 s · $0.0313")),
        width: 390, height: 380)
    }
  }
#endif
