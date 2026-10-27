import Foundation

/// Query of `GET /v1/stats`. `days` is 1...365; the server answers 30 when it is absent.
public struct StatsQuery: Codable, Hashable, Sendable {
  public var days: Int?

  public init(days: Int? = nil) {
    self.days = days
  }

  public var queryItems: [URLQueryItem] {
    guard let days else { return [] }
    return [URLQueryItem(name: "days", value: String(days))]
  }
}

/// Body of `GET /v1/stats`: aggregates over the last `days` local days of the server, today included.
/// Days are `YYYY-MM-DD` strings in the server's time zone, not instants.
public struct Stats: Codable, Hashable, Sendable {
  public var days: Int
  public var from: String
  public var to: String
  public var perDay: [StatsDayCount]
  /// Weeks start on Monday; the first week only counts the days inside the window.
  public var perWeek: [StatsWeekCount]
  /// Median duration of done step records per step and route, in pipeline order then route; a pair without samples is absent.
  public var stepMedians: [StatsStepMedian]
  public var costPerRoute: [StatsRouteCost]

  public init(
    days: Int, from: String, to: String, perDay: [StatsDayCount] = [], perWeek: [StatsWeekCount] = [],
    stepMedians: [StatsStepMedian] = [], costPerRoute: [StatsRouteCost] = []
  ) {
    self.days = days
    self.from = from
    self.to = to
    self.perDay = perDay
    self.perWeek = perWeek
    self.stepMedians = stepMedians
    self.costPerRoute = costPerRoute
  }
}

public struct StatsDayCount: Codable, Hashable, Sendable {
  public var date: String
  /// A destination name, or `"unrouted"` for a memo that has no route yet or failed early.
  public var route: String
  public var count: Int

  public init(date: String, route: String, count: Int) {
    self.date = date
    self.route = route
    self.count = count
  }
}

public struct StatsWeekCount: Codable, Hashable, Sendable {
  public var weekStart: String
  public var count: Int

  public init(weekStart: String, count: Int) {
    self.weekStart = weekStart
    self.count = count
  }
}

/// The median duration of one step for memos of one route: the baseline the memo detail waterfall compares
/// against. `samples` is the n behind it; the client decides how many are enough to show a faster/slower hint.
public struct StatsStepMedian: Codable, Hashable, Sendable {
  public var step: MemoStep
  /// A destination name, or `"unrouted"`.
  public var route: String
  public var medianMs: Int
  public var samples: Int

  public init(step: MemoStep, route: String, medianMs: Int, samples: Int) {
    self.step = step
    self.route = route
    self.medianMs = medianMs
    self.samples = samples
  }
}

public struct StatsRouteCost: Codable, Hashable, Sendable {
  public var route: String
  public var costUsd: Double
  public var memos: Int

  public init(route: String, costUsd: Double, memos: Int) {
    self.route = route
    self.costUsd = costUsd
    self.memos = memos
  }
}
