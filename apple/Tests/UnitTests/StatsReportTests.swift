import Foundation
import IrisCore
import IrisUI
import Testing

@testable import Iris

@Suite("StatsReport")
struct StatsReportTests {
  private let english = Locale(identifier: "en_US")

  /// 2026-10-27 is a Tuesday; the day view covers 10-21...10-27, the 7 days before are 10-14...10-20.
  private let stats = Stats(
    days: 56, from: "2026-09-02", to: "2026-10-27",
    perDay: [
      StatsDayCount(date: "2026-10-14", route: "hermes", count: 2),
      StatsDayCount(date: "2026-10-20", route: "journal", count: 2),
      StatsDayCount(date: "2026-10-21", route: "hermes", count: 3),
      StatsDayCount(date: "2026-10-21", route: "tab", count: 1),
      StatsDayCount(date: "2026-10-21", route: "herdr", count: 1),
      StatsDayCount(date: "2026-10-26", route: "journal", count: 4),
      StatsDayCount(date: "2026-10-27", route: "hermes", count: 2),
      StatsDayCount(date: "2026-10-27", route: "unrouted", count: 1),
    ],
    perWeek: [
      StatsWeekCount(weekStart: "2026-10-12", count: 4), StatsWeekCount(weekStart: "2026-10-19", count: 11),
      StatsWeekCount(weekStart: "2026-10-26", count: 7),
    ],
    costPerRoute: [
      StatsRouteCost(route: "hermes", costUsd: 1.2, memos: 8), StatsRouteCost(route: "journal", costUsd: 0.4, memos: 8),
    ])

  @Test("the day view shows the last seven days, zero-filled, with routes folded into series")
  func dayBars() {
    let report = StatsReport(stats: stats, granularity: .days, locale: english)
    #expect(report.bars.map(\.id).first == "2026-10-21")
    #expect(report.bars.map(\.id).last == "2026-10-27")
    #expect(report.bars.count == 7)
    #expect(report.bars[0].counts == [.hermes: 3, .tabs: 2])
    #expect(report.bars[1].total == 0)
    #expect(report.bars[6].counts == [.hermes: 2, .unrouted: 1])
    #expect(report.bars[6].name.contains("27"))
    #expect(report.bars[6].axisLabel == "T")
    #expect(!report.isEmpty)
  }

  @Test("the tiles carry the total, the change against the 7 days before, the busiest day and the window's cost")
  func dayTiles() {
    let report = StatsReport(stats: stats, granularity: .days, locale: english)
    // 12 memos now against 4 before: +200 %. Wed 21 is the busiest day with 5. Cost is the window's, 16 memos.
    #expect(report.tiles.map(\.value) == ["12", report.bars[0].name, StepText.dollars(1.6, locale: english)])
    #expect(report.tiles[0].caption?.contains("200") == true)
    #expect(report.tiles[1].caption?.contains("5") == true)
    #expect(report.tiles[2].caption?.contains(StepText.dollars(0.1, locale: english)) == true)
  }

  @Test("a route's trend is its day counts, its total and the change against the 7 days before")
  func dayTrends() throws {
    let report = StatsReport(stats: stats, granularity: .days, locale: english)
    let hermes = try #require(report.trends.first { $0.series == .hermes })
    #expect(hermes.points == [3, 0, 0, 0, 0, 0, 2])
    #expect(hermes.total == 5)
    #expect(hermes.direction == .up)
    let journal = try #require(report.trends.first { $0.series == .journal })
    #expect(journal.total == 4)
    #expect(journal.direction == .up)
    // Folded: tab and herdr are one series.
    #expect(try #require(report.trends.first { $0.series == .tabs }).total == 2)
  }

  @Test("the week view sums each server week from the day rows and marks the running week partial")
  func weekBars() {
    let report = StatsReport(stats: stats, granularity: .weeks, locale: english)
    #expect(report.bars.map(\.id) == ["2026-10-12", "2026-10-19", "2026-10-26"])
    #expect(report.bars[0].counts == [.hermes: 2])
    #expect(report.bars[1].counts == [.journal: 2, .hermes: 3, .tabs: 2])
    #expect(report.bars[2].counts == [.journal: 4, .hermes: 2, .unrouted: 1])
    #expect(report.bars.map(\.name).last?.contains("partial") == true)
    #expect(report.bars.map(\.name).first?.contains("partial") == false)
    #expect(report.trends.allSatisfy { $0.direction == .flat })
  }

  @Test("without any memo the report is empty")
  func empty() {
    let report = StatsReport(stats: Stats(days: 56, from: "2026-09-02", to: "2026-10-27"), granularity: .days)
    #expect(report.isEmpty)
    #expect(report.trends.isEmpty)
    #expect(report.tiles[1].value == "–")
  }

  @Test("the sample stats feed both views")
  func sampleStats() {
    let sample = SampleData.stats()
    for granularity in StatsReport.Granularity.allCases {
      let report = StatsReport(stats: sample, granularity: granularity)
      #expect(!report.isEmpty)
      #expect(report.bars.count == granularity.barCount || granularity == .weeks)
      #expect(!report.trends.isEmpty)
    }
  }
}
