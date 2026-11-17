#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  /// The Details of one memo, as the iPhone's sheet and the Mac's popover draw them.
  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct MemoDetailsContentSnapshotTests {
    private var rows: [StepWaterfallRow] {
      [
        StepWaterfallRow(
          id: "transcribe", title: "Transcribe", phase: .done, metric: "8.5 s · $0.0038", start: 0, length: 0.309),
        StepWaterfallRow(
          id: "act", title: "Act · Hermes", phase: .done, metric: "11.4 s · $0.04",
          badge: .init(text: "+39 % slower", tone: .slower), start: 0.31, length: 0.415),
        StepWaterfallRow(
          id: "summarize", title: "Summarize", phase: .failed, metric: "5.7 s", attempts: "2 attempts",
          error: "agw triage failed: 402 payment required", isOptional: true,
          optionalNote: "The memo is done without it", retryTitle: "Retry from Summarize", start: 0.725, length: 0.208),
        StepWaterfallRow(id: "notify", title: "Notify", phase: .done, metric: "1.9 s", start: 0.933, length: 0.067),
      ]
    }

    private func content(tools: [String], segmentCount: Int?) -> some View {
      MemoDetailsContent(
        rows: rows, totalValue: "27.5 s · $0.05",
        copyRows: [
          .init(id: "transcript", title: "Copy transcript", isCopied: false, action: {}),
          .init(id: "reply", title: "Copy reply", isCopied: true, action: {}),
        ], tools: tools, memoID: "c1a0b7d2-4e61-4f38-9a15-3d8e6b2f7c41",
        threadID: "c1a0b7d2-4e61-4f38-9a15-3d8e6b2f7c40",
        device: "iphone", segmentCount: segmentCount, onRetry: { _ in }
      )
      .padding(.horizontal, Theme.Spacing.screenMargin)
      .padding(.vertical, Theme.Spacing.md)
      // The texts come from the catalog: the references are English whatever language the recording machine runs in.
      .environment(\.locale, Locale(identifier: "en_US"))
    }

    @Test("open by default: every step, the copy rows, what Hermes used, the ids and the device", .tags(.snapshot))
    func open() {
      SnapshotSupport.assertLightAndDark(
        content(tools: ["terminal", "github"], segmentCount: 2), width: 390, height: 760)
    }

    @Test("an answer without tools and a typed memo: no tools line, no segments", .tags(.snapshot))
    func withoutTools() {
      SnapshotSupport.assertLightAndDark(content(tools: [], segmentCount: nil), width: 390, height: 740)
    }
  }
#endif
