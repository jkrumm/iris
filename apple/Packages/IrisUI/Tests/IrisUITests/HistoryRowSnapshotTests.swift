#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct HistoryRowSnapshotTests {
    private func row(
      state: String, color: Color, headline: String, needsAttention: Bool = false, done: Bool = false,
      favorite: Bool = false
    ) -> some View {
      HistoryRow(
        routeLabel: "Hermes", stateLabel: state, stateColor: color, headline: headline, timeText: "2 hours ago",
        isDone: done, isFavorite: favorite
      )
      .padding(.horizontal, Theme.Spacing.lg)
      .padding(.vertical, Theme.Spacing.sm)
      .background { HistoryRowBackground(needsAttention: needsAttention) }
    }

    @Test("a settled row", .tags(.snapshot))
    func plain() {
      SnapshotSupport.assertLightAndDark(
        row(state: "Done", color: Theme.Status.good, headline: "Wochenplan abgestimmt, Release am Donnerstag"),
        width: 390, height: 140)
    }

    @Test("a parked row is tinted", .tags(.snapshot))
    func needsRoute() {
      SnapshotSupport.assertLightAndDark(
        row(
          state: "Needs a route", color: Theme.Status.warn,
          headline: "Schreib das bitte in mein Journal und gib mir morgen früh eine Zusammenfassung.",
          needsAttention: true),
        width: 390, height: 150)
    }

    @Test("a done favorite is dimmed with a check and a star", .tags(.snapshot))
    func doneFavorite() {
      SnapshotSupport.assertLightAndDark(
        row(
          state: "Done", color: Theme.Status.good,
          headline: "Docs tab adds a troubleshooting section for upload retries",
          done: true, favorite: true),
        width: 390, height: 150)
    }
  }
#endif
