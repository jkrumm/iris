#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct HistoryRowSnapshotTests {
    private func row(
      _ status: HistoryRowStatus, headline: String, secondary: String? = nil, time: String = "9:21",
      needsAttention: Bool = false, done: Bool = false, favorite: Bool = false, thread: Bool = false
    ) -> some View {
      HistoryRow(
        status: status, headline: headline, secondary: secondary, timeText: time, isDone: done, isFavorite: favorite,
        isThread: thread
      )
      // The list's row insets (`HistoryView.rowInsets`): the row itself carries no padding.
      .padding(.horizontal, Theme.Spacing.screenMargin)
      .padding(.vertical, Theme.Spacing.rowVertical)
      .background { HistoryRowBackground(needsAttention: needsAttention) }
    }

    @Test("a settled row: kind, audio length, summary line", .tags(.snapshot))
    func settled() {
      SnapshotSupport.assertLightAndDark(
        row(
          .settled(kind: "Answer", dot: KindPalette.color(forKind: "Answer"), duration: "38 s"),
          headline: "Wochenplan abgestimmt, Release am Donnerstag",
          secondary: "Montag PR-Review, Mittwoch Feature-Freeze, Donnerstag Release"),
        width: 390, height: 120)
    }

    @Test("a chat row carries a speech bubble next to the time", .tags(.snapshot))
    func chatThread() {
      SnapshotSupport.assertLightAndDark(
        row(
          .settled(kind: "Chat", dot: KindPalette.color(forKind: "Chat"), duration: "14 s"),
          headline: "Which Postgres index fits the herd snapshot query?", time: "9:46", favorite: true, thread: true),
        width: 390, height: 100)
    }

    @Test("a failed row names the step and the retry", .tags(.snapshot))
    func failed() {
      SnapshotSupport.assertLightAndDark(
        row(
          .alert(label: "Failed · summarize", color: Theme.Status.bad),
          headline: "Prompt an Tab dotfiles: Brewfile um xcodegen ergänzen",
          secondary: "agw job failed (upstream 503) — retry from summarize", time: "9:31"),
        width: 390, height: 120)
    }

    @Test("a row in flight says Acting", .tags(.snapshot))
    func inFlight() {
      SnapshotSupport.assertLightAndDark(
        row(
          .inFlight(kind: "Task", dot: KindPalette.color(forKind: "Task"), label: "Acting"),
          headline: "Which Postgres index fits the herd snapshot query?", time: "9:46"),
        width: 390, height: 100)
    }

    @Test("an in-flight row shows one dash per step, filled as steps finish", .tags(.snapshot))
    func inFlightProgress() {
      SnapshotSupport.assertLightAndDark(
        row(
          .inFlight(
            kind: "Task", dot: KindPalette.color(forKind: "Task"), label: "Acting",
            progress: StepProgress(completed: 3, total: 5)),
          headline: "Which Postgres index fits the herd snapshot query?", time: "9:46"),
        width: 390, height: 100)
    }

    @Test("a done favorite is dimmed with a check and a star", .tags(.snapshot))
    func doneFavorite() {
      SnapshotSupport.assertLightAndDark(
        row(
          .settled(kind: "Github issue", dot: KindPalette.color(forKind: "Github issue"), duration: "21 s"),
          headline: "Docs tab adds a troubleshooting section for upload retries", done: true, favorite: true),
        width: 390, height: 100)
    }
  }
#endif
