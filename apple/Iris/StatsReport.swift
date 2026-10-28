import Foundation
import IrisCore
import IrisUI

/// What the Stats tab shows for one granularity, computed from a `GET /v1/stats` body: the bars, the three tiles and
/// the per-route trends. Pure, so it is tested without a view. Days are the server's `YYYY-MM-DD` strings; they are
/// read and written in UTC so no device time zone can move a day.
nonisolated struct StatsReport: Equatable {
  enum Granularity: String, CaseIterable, Identifiable {
    case days
    case weeks

    var id: String { rawValue }

    /// How many bars the chart shows.
    var barCount: Int { self == .days ? 7 : 8 }
  }

  struct Tile: Equatable {
    var title: String
    var value: String
    var caption: String?
  }

  struct Trend: Equatable, Identifiable {
    var series: VolumeSeries
    var points: [Int]
    var total: Int
    var change: String
    var direction: TrendRow.Direction
    var id: VolumeSeries { series }
  }

  /// How many days the report needs from the server: eight weeks, which also holds the 7 + 7 days of the day view.
  static let windowDays = 56

  let granularity: Granularity
  let bars: [VolumeBar]
  let rangeText: String
  let tiles: [Tile]
  let trends: [Trend]

  var isEmpty: Bool { bars.allSatisfy { $0.total == 0 } }

  init(stats: Stats, granularity: Granularity, locale: Locale = .current) {
    self.granularity = granularity
    let grid = Grid(stats: stats, locale: locale)
    let barList: [VolumeBar]
    switch granularity {
    case .days:
      let dates = grid.lastDays(Granularity.days.barCount, endingAt: stats.to)
      let previous = grid.lastDays(Granularity.days.barCount, endingAt: grid.shift(dates[0], by: -1))
      barList = dates.map { grid.dayBar($0) }
      let before = previous.map { grid.dayBar($0) }
      rangeText = String(localized: "Last 7 days · \(grid.rangeText(dates.first, dates.last))", comment: "Stats range")
      tiles = Self.tiles(
        bars: barList,
        change: Self.percentChange(barList.map(\.total).reduce(0, +), before.map(\.total).reduce(0, +)),
        stats: stats)
      trends = VolumeSeries.allCases.compactMap { series in
        let points = barList.map { $0.counts[series, default: 0] }
        let prior = before.map { $0.counts[series, default: 0] }.reduce(0, +)
        return StatsReport.trend(series, points: points, change: points.reduce(0, +) - prior)
      }
    case .weeks:
      let weeks = Array(stats.perWeek.suffix(Granularity.weeks.barCount))
      barList = weeks.enumerated().map { index, week in grid.weekBar(week, isLast: index == weeks.count - 1) }
      let first = weeks.first.map { grid.rangeText($0.weekStart, stats.to) } ?? ""
      rangeText = String(localized: "Last \(weeks.count) weeks · \(first)", comment: "Stats range")
      let total = barList.map(\.total).reduce(0, +)
      let average = weeks.isEmpty ? 0 : Double(total) / Double(weeks.count)
      tiles = Self.tiles(
        bars: barList,
        change: String(localized: "avg \(average.formatted(.number.precision(.fractionLength(0...1)))) / wk"),
        stats: stats)
      trends = VolumeSeries.allCases.compactMap { series in
        StatsReport.weekTrend(series, points: barList.map { $0.counts[series, default: 0] })
      }
    }
    bars = barList
  }

  // MARK: Tiles and trends

  private static func tiles(bars: [VolumeBar], change: String?, stats: Stats) -> [Tile] {
    let total = bars.map(\.total).reduce(0, +)
    let busiest = bars.max { $0.total < $1.total }
    let memos = stats.costPerRoute.map(\.memos).reduce(0, +)
    let cost = stats.costPerRoute.map(\.costUsd).reduce(0, +)
    return [
      Tile(title: String(localized: "Memos", comment: "Stats tile"), value: String(total), caption: change),
      Tile(
        title: String(localized: "Busiest", comment: "Stats tile"),
        value: busiest.flatMap { $0.total > 0 ? $0.name : nil } ?? "–",
        caption: busiest.flatMap {
          $0.total > 0 ? String(localized: "\($0.total) memos", comment: "Stats tile caption") : nil
        }),
      Tile(
        title: String(localized: "Cost · \(stats.days) d", comment: "Stats tile: spend over the whole window"),
        value: StepText.dollars(cost),
        caption: memos > 0
          ? String(localized: "\(StepText.cost(cost / Double(memos))) / memo", comment: "Stats tile caption") : nil),
    ]
  }

  private static func percentChange(_ now: Int, _ before: Int) -> String? {
    guard before > 0 else { return nil }
    let percent = Int((Double(now - before) / Double(before) * 100).rounded())
    let sign = percent > 0 ? "+" : percent < 0 ? "−" : ""
    return String(localized: "\(sign)\(abs(percent)) % vs prior", comment: "Stats tile caption")
  }

  private static func trend(_ series: VolumeSeries, points: [Int], change: Int) -> Trend? {
    let total = points.reduce(0, +)
    guard total > 0 || change != 0 else { return nil }
    let direction: TrendRow.Direction = change > 0 ? .up : change < 0 ? .down : .flat
    let text =
      switch direction {
      case .up: "▲ +\(change)"
      case .down: "▼ −\(-change)"
      case .flat: "▬ 0"
      }
    return Trend(series: series, points: points, total: total, change: text, direction: direction)
  }

  private static func weekTrend(_ series: VolumeSeries, points: [Int]) -> Trend? {
    let total = points.reduce(0, +)
    guard total > 0 else { return nil }
    let average = Double(total) / Double(points.count)
    return Trend(
      series: series, points: points, total: total,
      change: String(localized: "\(average.formatted(.number.precision(.fractionLength(1)))) / wk"),
      direction: .flat)
  }

  /// The route names the server stores, folded into the chart's series.
  static func series(of route: String) -> VolumeSeries {
    switch route {
    case "hermes": .hermes
    case "journal": .journal
    case "tab", "herdr": .tabs
    default: .unrouted
    }
  }

  // MARK: Day grid

  /// Lookups over the server's day rows, and the day arithmetic.
  private struct Grid {
    let countsByDay: [String: [VolumeSeries: Int]]
    let weekStarts: [String]
    let locale: Locale

    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    private static var calendar: Calendar {
      var calendar = Calendar(identifier: .iso8601)
      calendar.timeZone = utc
      return calendar
    }

    init(stats: Stats, locale: Locale) {
      var counts: [String: [VolumeSeries: Int]] = [:]
      for row in stats.perDay {
        counts[row.date, default: [:]][StatsReport.series(of: row.route), default: 0] += row.count
      }
      countsByDay = counts
      weekStarts = stats.perWeek.map(\.weekStart)
      self.locale = locale
    }

    private func date(_ day: String) -> Date? {
      try? Date(day, strategy: .iso8601.year().month().day().dateSeparator(.dash))
    }

    private func key(_ date: Date) -> String {
      date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    func shift(_ day: String, by days: Int) -> String {
      guard let start = date(day), let moved = Self.calendar.date(byAdding: .day, value: days, to: start) else {
        return day
      }
      return key(moved)
    }

    /// `count` days oldest first, ending at `last`.
    func lastDays(_ count: Int, endingAt last: String) -> [String] {
      (0..<count).reversed().map { shift(last, by: -$0) }
    }

    private func style(_ build: (Date.FormatStyle) -> Date.FormatStyle) -> Date.FormatStyle {
      build(Date.FormatStyle(timeZone: Self.utc).locale(locale))
    }

    func dayBar(_ day: String) -> VolumeBar {
      let moment = date(day) ?? .distantPast
      return VolumeBar(
        id: day, axisLabel: moment.formatted(style { $0.weekday(.narrow) }),
        name: moment.formatted(style { $0.weekday(.abbreviated).day() }), counts: countsByDay[day] ?? [:])
    }

    func weekBar(_ week: StatsWeekCount, isLast: Bool) -> VolumeBar {
      var counts: [VolumeSeries: Int] = [:]
      let end = shift(week.weekStart, by: 6)
      for (day, perSeries) in countsByDay where day >= week.weekStart && day <= end {
        for (series, count) in perSeries { counts[series, default: 0] += count }
      }
      let number = date(week.weekStart).map { Self.calendar.component(.weekOfYear, from: $0) } ?? 0
      let label = String(localized: "W\(number)", comment: "Calendar week, W44")
      return VolumeBar(
        id: week.weekStart, axisLabel: number == 0 ? "" : String(number),
        name: isLast ? String(localized: "\(label) (partial)", comment: "The running calendar week") : label,
        counts: counts)
    }

    func rangeText(_ from: String?, _ to: String?) -> String {
      guard let from = from.flatMap(date), let to = to.flatMap(date) else { return "" }
      let interval = Date.IntervalFormatStyle(timeZone: Self.utc).locale(locale).day().month(.abbreviated)
      return (from..<max(from, to)).formatted(interval)
    }
  }
}
