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
  /// Median duration of done step records per step and memo kind, in pipeline order then kind; a pair without samples is absent.
  public var stepMedians: [StatsStepMedian]
  /// Cost per memo kind; `kind` is `nil` for memos without one (transcribe, or not classified).
  public var costPerKind: [StatsKindCost]

  public init(
    days: Int, from: String, to: String, perDay: [StatsDayCount] = [], perWeek: [StatsWeekCount] = [],
    stepMedians: [StatsStepMedian] = [], costPerKind: [StatsKindCost] = []
  ) {
    self.days = days
    self.from = from
    self.to = to
    self.perDay = perDay
    self.perWeek = perWeek
    self.stepMedians = stepMedians
    self.costPerKind = costPerKind
  }
}

public struct StatsDayCount: Codable, Hashable, Sendable {
  public var date: String
  /// The memo kind, `nil` for a memo without one (not classified yet or failed early).
  public var kind: String?
  public var count: Int

  public init(date: String, kind: String?, count: Int) {
    self.date = date
    self.kind = kind
    self.count = count
  }

  private enum CodingKeys: String, CodingKey {
    case date, kind, count
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    date = try container.decode(String.self, forKey: .date)
    kind = try container.decodeIfPresent(String.self, forKey: .kind)
    count = try container.decode(Int.self, forKey: .count)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(date, forKey: .date)
    try container.encode(kind, forKey: .kind)
    try container.encode(count, forKey: .count)
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

/// The median duration of one step for memos of one kind: the baseline the memo detail waterfall compares
/// against. `samples` is the n behind it; the client decides how many are enough to show a faster/slower hint.
public struct StatsStepMedian: Codable, Hashable, Sendable {
  public var step: MemoStep
  /// The memo kind, `nil` for memos without one.
  public var kind: String?
  public var medianMs: Int
  public var samples: Int

  public init(step: MemoStep, kind: String?, medianMs: Int, samples: Int) {
    self.step = step
    self.kind = kind
    self.medianMs = medianMs
    self.samples = samples
  }

  private enum CodingKeys: String, CodingKey {
    case step, kind, medianMs, samples
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    step = try container.decode(MemoStep.self, forKey: .step)
    kind = try container.decodeIfPresent(String.self, forKey: .kind)
    medianMs = try container.decode(Int.self, forKey: .medianMs)
    samples = try container.decode(Int.self, forKey: .samples)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(step, forKey: .step)
    try container.encode(kind, forKey: .kind)
    try container.encode(medianMs, forKey: .medianMs)
    try container.encode(samples, forKey: .samples)
  }
}

/// Cost and memo count of one memo kind (`nil`: none, shown as "Transcript").
public struct StatsKindCost: Codable, Hashable, Sendable {
  public var kind: String?
  public var costUsd: Double
  public var memos: Int

  public init(kind: String?, costUsd: Double, memos: Int) {
    self.kind = kind
    self.costUsd = costUsd
    self.memos = memos
  }

  private enum CodingKeys: String, CodingKey {
    case kind, costUsd, memos
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decodeIfPresent(String.self, forKey: .kind)
    costUsd = try container.decode(Double.self, forKey: .costUsd)
    memos = try container.decode(Int.self, forKey: .memos)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(costUsd, forKey: .costUsd)
    try container.encode(memos, forKey: .memos)
  }
}
