import Foundation

/// Body of `GET /v1/factory`: what waits for the owner (`asks`) and what needs a look (`health`), already worded for display.
/// `kind` and `source` stay strings, so a value the server adds later still decodes.
public struct FactoryBoard: Codable, Hashable, Sendable {
  public var asks: [FactoryAsk]
  public var health: [FactoryHealthItem]
  public var counts: FactoryCounts
  public var builtAt: Date

  public init(asks: [FactoryAsk] = [], health: [FactoryHealthItem] = [], counts: FactoryCounts? = nil, builtAt: Date) {
    self.asks = asks
    self.health = health
    self.counts = counts ?? FactoryCounts(asks: asks.count, health: health.count)
    self.builtAt = builtAt
  }
}

public struct FactoryCounts: Codable, Hashable, Sendable {
  public var asks: Int
  public var health: Int

  public init(asks: Int, health: Int) {
    self.asks = asks
    self.health = health
  }
}

/// One thing the factory waits on. `short` and `summary` are the display text; `id` and `issue` are never shown.
public struct FactoryAsk: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var issue: Int?
  public var short: String
  public var summary: String
  /// `hc`, `wait`, `factory`, `decision`, `queue`, `reply` or `other`.
  public var source: String
  /// `blocker`, `question`, `human`, `note`, `permission` or `other`.
  public var kind: String
  public var at: Date
  public var stale: Bool
  /// Only an answerable ask takes `POST /v1/factory/answer`.
  public var answerable: Bool
  public var options: [String]

  public init(
    id: String, issue: Int? = nil, short: String, summary: String, source: String = "decision",
    kind: String = "question", at: Date, stale: Bool = false, answerable: Bool = true, options: [String] = []
  ) {
    self.id = id
    self.issue = issue
    self.short = short
    self.summary = summary
    self.source = source
    self.kind = kind
    self.at = at
    self.stale = stale
    self.answerable = answerable
    self.options = options
  }

  private enum CodingKeys: String, CodingKey {
    case id, issue, short, summary, source, kind, at, stale, answerable, options
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    issue = try container.decodeIfPresent(Int.self, forKey: .issue)
    short = try container.decode(String.self, forKey: .short)
    summary = try container.decode(String.self, forKey: .summary)
    source = try container.decode(String.self, forKey: .source)
    kind = try container.decode(String.self, forKey: .kind)
    at = try container.decode(Date.self, forKey: .at)
    stale = try container.decode(Bool.self, forKey: .stale)
    answerable = try container.decode(Bool.self, forKey: .answerable)
    options = try container.decode([String].self, forKey: .options)
  }

  /// `issue` is `null` on the wire, not absent, when the ask belongs to no Issue.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(issue, forKey: .issue)
    try container.encode(short, forKey: .short)
    try container.encode(summary, forKey: .summary)
    try container.encode(source, forKey: .source)
    try container.encode(kind, forKey: .kind)
    try container.encode(at, forKey: .at)
    try container.encode(stale, forKey: .stale)
    try container.encode(answerable, forKey: .answerable)
    try container.encode(options, forKey: .options)
  }
}

/// Something that needs a look but no answer (a parked Issue, a silent lead, a budget).
public struct FactoryHealthItem: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  /// `park`, `silent`, `over_budget`, `regressions`, `machine` or `other`.
  public var kind: String
  public var short: String
  public var summary: String
  public var since: Date

  public init(id: String, kind: String, short: String, summary: String, since: Date) {
    self.id = id
    self.kind = kind
    self.short = short
    self.summary = summary
    self.since = since
  }
}

/// Body of `POST /v1/factory/answer`. `callId` is one string per answer attempt, reused on a retry, so a retry is one factory event.
public struct FactoryAnswerRequest: Codable, Hashable, Sendable {
  public var askId: String
  public var text: String
  public var callId: String

  public init(askId: String, text: String, callId: String) {
    self.askId = askId
    self.text = text
    self.callId = callId
  }
}

/// `duplicate` is true when the factory had already taken this `callId`.
public struct FactoryAnswerResponse: Codable, Hashable, Sendable {
  public var issue: Int
  public var state: String
  public var duplicate: Bool

  public init(issue: Int, state: String, duplicate: Bool) {
    self.issue = issue
    self.state = state
    self.duplicate = duplicate
  }
}

/// The alert push of an ask: `factory` names the ask the app opens on tap.
public struct FactoryAlertPush: Codable, Hashable, Sendable {
  public struct Aps: Codable, Hashable, Sendable {
    public var alert: PushAlert.Aps.Alert
    public var threadID: String
    public var sound: String

    public init(alert: PushAlert.Aps.Alert, threadID: String = "factory", sound: String = "default") {
      self.alert = alert
      self.threadID = threadID
      self.sound = sound
    }

    private enum CodingKeys: String, CodingKey {
      case alert
      case threadID = "thread-id"
      case sound
    }
  }

  public struct Target: Codable, Hashable, Sendable {
    public var askId: String
    public var issue: Int?

    public init(askId: String, issue: Int?) {
      self.askId = askId
      self.issue = issue
    }

    private enum CodingKeys: String, CodingKey { case askId, issue }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      askId = try container.decode(String.self, forKey: .askId)
      issue = try container.decodeIfPresent(Int.self, forKey: .issue)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(askId, forKey: .askId)
      try container.encode(issue, forKey: .issue)
    }
  }

  public var aps: Aps
  public var factory: Target

  public init(aps: Aps, factory: Target) {
    self.aps = aps
    self.factory = factory
  }
}
