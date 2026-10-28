#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct StatsSnapshotTests {
    static let names: [VolumeSeries: String] = [
      .hermes: "Hermes", .journal: "Journal", .tabs: "Tabs", .unrouted: "Unrouted",
    ]

    static let week: [VolumeBar] = {
      let days: [(String, String, String, [Int])] = [
        ("2026-10-21", "W", "Wed 21", [3, 2, 1, 0]), ("2026-10-22", "T", "Thu 22", [2, 3, 2, 0]),
        ("2026-10-23", "F", "Fri 23", [1, 1, 0, 0]), ("2026-10-24", "S", "Sat 24", [0, 2, 0, 0]),
        ("2026-10-25", "S", "Sun 25", [1, 0, 0, 1]), ("2026-10-26", "M", "Mon 26", [4, 2, 1, 0]),
        ("2026-10-27", "T", "Tue 27", [3, 1, 1, 0]),
      ]
      return days.map { id, axis, name, counts in
        VolumeBar(
          id: id, axisLabel: axis, name: name,
          counts: Dictionary(uniqueKeysWithValues: zip(VolumeSeries.allCases, counts)))
      }
    }()

    @Test("the stacked volume chart with its readout and legend", .tags(.snapshot))
    func chart() {
      let chart = VolumeChart(bars: Self.week, names: Self.names, summary: "Memos per route, last 7 days")
        .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(chart, width: 390, height: 300)
    }

    @Test("stat tiles side by side", .tags(.snapshot))
    func tiles() {
      let row = HStack(spacing: Theme.Spacing.sm) {
        StatTile(title: "Memos", value: "38", caption: "▲ +27 % vs prior")
        StatTile(title: "Busiest", value: "Mon 26", caption: "9 memos")
        StatTile(title: "Cost · 56 d", value: "$1.62", caption: "$0.03 / memo")
      }
      .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(row, width: 390, height: 120)
    }

    @Test("trend rows with a rise, a fall and no change", .tags(.snapshot))
    func trends() {
      let rows = VStack(spacing: 0) {
        TrendRow(
          series: .hermes, name: "Hermes", points: [3, 2, 1, 0, 1, 4, 3], total: 14, changeText: "▲ +4",
          direction: .up)
        TrendRow(
          series: .journal, name: "Journal", points: [2, 3, 1, 2, 0, 2, 1], total: 11, changeText: "▼ −2",
          direction: .down)
        TrendRow(
          series: .tabs, name: "Tabs", points: [1, 2, 0, 0, 0, 1, 1], total: 5, changeText: "▬ 0", direction: .flat)
      }
      .detailCard()
      .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(rows, width: 390, height: 190)
    }
  }
#endif
