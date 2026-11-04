import Foundation
import IrisCore
import IrisUI
import Testing

@testable import Iris

@Suite("StatsReport")
struct StatsReportTests {
  private let english = Locale(identifier: "en_US")

  /// 2026-10-27 is a Tuesday; the day view covers 10-21...10-27, the 7 days before are 10-14...10-20.
  /// Over the window: note 6, answer 5, task 3, github issue 1, research 1 (folds into Other: the tie goes by name), one
  /// memo without a kind.
  private let stats = Stats(
    days: 56, from: "2026-09-02", to: "2026-10-27",
    perDay: [
      StatsDayCount(date: "2026-10-14", kind: "task", count: 2),
      StatsDayCount(date: "2026-10-20", kind: "note", count: 2),
      StatsDayCount(date: "2026-10-21", kind: "answer", count: 3),
      StatsDayCount(date: "2026-10-21", kind: "task", count: 1),
      StatsDayCount(date: "2026-10-21", kind: "github issue", count: 1),
      StatsDayCount(date: "2026-10-26", kind: "note", count: 4),
      StatsDayCount(date: "2026-10-26", kind: "research", count: 1),
      StatsDayCount(date: "2026-10-27", kind: "Answer", count: 2),
      StatsDayCount(date: "2026-10-27", kind: nil, count: 1),
    ],
    perWeek: [
      StatsWeekCount(weekStart: "2026-10-12", count: 4), StatsWeekCount(weekStart: "2026-10-19", count: 11),
      StatsWeekCount(weekStart: "2026-10-26", count: 7),
    ],
    costPerKind: [
      StatsKindCost(kind: "answer", costUsd: 1.2, memos: 8), StatsKindCost(kind: "note", costUsd: 0.4, memos: 8),
    ])

  private let note = VolumeSeries.kind("note", slot: 0)
  private let answer = VolumeSeries.kind("answer", slot: 1)
  private let task = VolumeSeries.kind("task", slot: 2)
  private let issue = VolumeSeries.kind("github issue", slot: 3)

  @Test("kinds are ranked by their count over the window: the top four get a slot in rank order")
  func ranking() {
    let report = StatsReport(stats: stats, granularity: .days, locale: english)
    #expect(report.series == [note, answer, task, issue, .other, .transcript])
  }

  @Test("fewer than five kinds have no Other series")
  func noOtherWithFourKinds() {
    var four = stats
    four.perDay.removeAll { $0.kind == "research" }
    let report = StatsReport(stats: four, granularity: .days, locale: english)
    #expect(report.series == [note, answer, task, issue, .transcript])
  }

  @Test("names: a kind as Hermes wrote it, capitalised; Other and Transcript are the stats' own words")
  func names() {
    let report = StatsReport(stats: stats, granularity: .days, locale: english)
    #expect(report.names[note] == "Note")
    #expect(report.names[issue] == "Github issue")
    #expect(report.names[.other] == "Other")
    #expect(report.names[.transcript] == "Transcript")
  }

  @Test("the day view shows the last seven days, zero-filled, with kinds folded into series")
  func dayBars() {
    let report = StatsReport(stats: stats, granularity: .days, locale: english)
    #expect(report.bars.map(\.id).first == "2026-10-21")
    #expect(report.bars.map(\.id).last == "2026-10-27")
    #expect(report.bars.count == 7)
    #expect(report.bars[0].counts == [answer: 3, task: 1, issue: 1])
    #expect(report.bars[1].total == 0)
    #expect(report.bars[5].counts == [note: 4, .other: 1])
    #expect(
      report.bars[6].counts == [answer: 2, .transcript: 1], "a kind folds case-insensitively; none is Transcript")
    #expect(report.bars[6].name.contains("27"))
    #expect(report.bars[6].axisLabel == "T")
    #expect(!report.isEmpty)
  }

  @Test("the tiles carry the total, the change against the 7 days before, the busiest day and the window's cost")
  func dayTiles() {
    let report = StatsReport(stats: stats, granularity: .days, locale: english)
    // 13 memos now against 4 before: +225 %. Wed 21 is the busiest day with 5. Cost is the window's, 16 memos.
    #expect(report.tiles.map(\.value) == ["13", report.bars[0].name, StepText.dollars(1.6, locale: english)])
    #expect(report.tiles[0].caption?.contains("225") == true)
    #expect(report.tiles[1].caption?.contains("5") == true)
    #expect(report.tiles[2].caption?.contains(StepText.dollars(0.1, locale: english)) == true)
  }

  @Test("a kind's trend is its day counts, its total and the change against the 7 days before")
  func dayTrends() throws {
    let report = StatsReport(stats: stats, granularity: .days, locale: english)
    let answers = try #require(report.trends.first { $0.series == answer })
    #expect(answers.points == [3, 0, 0, 0, 0, 0, 2])
    #expect(answers.total == 5)
    #expect(answers.direction == .up)
    let tasks = try #require(report.trends.first { $0.series == task })
    #expect(tasks.total == 1)
    #expect(tasks.direction == .down, "two the week before, one now")
    #expect(try #require(report.trends.first { $0.series == .transcript }).total == 1)
  }

  @Test("the week view sums each server week from the day rows and marks the running week partial")
  func weekBars() {
    let report = StatsReport(stats: stats, granularity: .weeks, locale: english)
    #expect(report.bars.map(\.id) == ["2026-10-12", "2026-10-19", "2026-10-26"])
    #expect(report.bars[0].counts == [task: 2])
    #expect(report.bars[1].counts == [note: 2, answer: 3, task: 1, issue: 1])
    #expect(report.bars[2].counts == [note: 4, .other: 1, answer: 2, .transcript: 1])
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
