#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct FilterChipSnapshotTests {
    @Test("the quick-filter row, one chip on", .tags(.snapshot))
    func quickRow() {
      let row = HStack(spacing: Theme.Spacing.sm) {
        FilterChip(title: "Favorites", systemImage: "star", isOn: true, size: .compact) {}
        FilterChip(title: "Chats", systemImage: "bubble.left", isOn: false, size: .compact) {}
        FilterChip(title: "Needs route", systemImage: "arrow.triangle.branch", isOn: false, size: .compact) {}
      }
      .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(row, width: 390, height: 64)
    }

    @Test("sheet chips wrap onto the next line", .tags(.snapshot))
    func wrapped() {
      let flow = ChipFlowLayout(
        lineSpacing: Theme.Spacing.sm - (Theme.Spacing.tapTarget - Theme.Spacing.chipHeightLarge)
      ) {
        FilterChip(title: "Hermes", isOn: true, size: .regular) {}
        FilterChip(title: "Journal", isOn: false, size: .regular) {}
        FilterChip(title: "Tabs", isOn: false, size: .regular) {}
        FilterChip(title: "Needs route", isOn: false, size: .regular) {}
        FilterChip(title: "Failed", isOn: true, size: .regular) {}
        FilterChip(title: "Done", isOn: false, size: .regular) {}
      }
      .padding(Theme.Spacing.xl)
      SnapshotSupport.assertLightAndDark(flow, width: 300, height: 140)
    }
  }
#endif
