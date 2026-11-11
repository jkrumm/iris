import Foundation

/// The body of an `iris-show` fence as the asset route serves it (`application/json`, contract `artifacts.show-spec`): one typed
/// spec, discriminated by `type`. The renderer is the web page in IrisUI's bundle; this type is the Swift side of the contract.
public enum ShowSpec: Hashable, Sendable {
  case table(Table)
  case chart(Chart)
  case stat(Stat)
  case list(List)
  case callout(Callout)

  /// A table cell or a chart's x value: a string, a number, a boolean or `null` (a chart's x is never a boolean or `null`).
  public enum Scalar: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
  }

  public struct Table: Codable, Hashable, Sendable {
    public var title: String?
    public var columns: [String]
    /// One cell per column.
    public var rows: [[Scalar]]

    public init(title: String? = nil, columns: [String], rows: [[Scalar]]) {
      self.title = title
      self.columns = columns
      self.rows = rows
    }
  }

  public struct Chart: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
      case bar, line, area, pie
    }

    public struct Series: Codable, Hashable, Sendable {
      public var name: String
      /// One per x value; `nil` is a gap.
      public var values: [Double?]

      public init(name: String, values: [Double?]) {
        self.name = name
        self.values = values
      }
    }

    public var title: String?
    public var kind: Kind
    public var x: [Scalar]
    public var series: [Series]
    public var unit: String?

    public init(title: String? = nil, kind: Kind, x: [Scalar], series: [Series], unit: String? = nil) {
      self.title = title
      self.kind = kind
      self.x = x
      self.series = series
      self.unit = unit
    }
  }

  public struct Stat: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
      public var label: String
      /// A number or a string.
      public var value: Scalar
      public var unit: String?
      public var delta: Double?
      public var hint: String?

      public init(label: String, value: Scalar, unit: String? = nil, delta: Double? = nil, hint: String? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
        self.delta = delta
        self.hint = hint
      }
    }

    public var title: String?
    public var items: [Item]

    public init(title: String? = nil, items: [Item]) {
      self.title = title
      self.items = items
    }
  }

  public struct List: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
      public var text: String
      public var detail: String?

      public init(text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail
      }
    }

    public var title: String?
    public var ordered: Bool?
    public var items: [Item]

    public init(title: String? = nil, ordered: Bool? = nil, items: [Item]) {
      self.title = title
      self.ordered = ordered
      self.items = items
    }
  }

  public struct Callout: Codable, Hashable, Sendable {
    public enum Tone: String, Codable, Hashable, Sendable {
      case info, success, warning, danger
    }

    public var tone: Tone
    public var title: String?
    public var body: String

    public init(tone: Tone, title: String? = nil, body: String) {
      self.tone = tone
      self.title = title
      self.body = body
    }
  }

  /// The spec's own title, if it has one.
  public var title: String? {
    switch self {
    case .table(let spec): spec.title
    case .chart(let spec): spec.title
    case .stat(let spec): spec.title
    case .list(let spec): spec.title
    case .callout(let spec): spec.title
    }
  }
}

extension ShowSpec: Codable {
  private enum TypeKey: String, CodingKey {
    case type
  }

  private enum Discriminator: String, Codable {
    case table, chart, stat, list, callout
  }

  public init(from decoder: any Decoder) throws {
    let type = try decoder.container(keyedBy: TypeKey.self).decode(Discriminator.self, forKey: .type)
    switch type {
    case .table: self = .table(try Table(from: decoder))
    case .chart: self = .chart(try Chart(from: decoder))
    case .stat: self = .stat(try Stat(from: decoder))
    case .list: self = .list(try List(from: decoder))
    case .callout: self = .callout(try Callout(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: TypeKey.self)
    switch self {
    case .table(let spec):
      try container.encode(Discriminator.table, forKey: .type)
      try spec.encode(to: encoder)
    case .chart(let spec):
      try container.encode(Discriminator.chart, forKey: .type)
      try spec.encode(to: encoder)
    case .stat(let spec):
      try container.encode(Discriminator.stat, forKey: .type)
      try spec.encode(to: encoder)
    case .list(let spec):
      try container.encode(Discriminator.list, forKey: .type)
      try spec.encode(to: encoder)
    case .callout(let spec):
      try container.encode(Discriminator.callout, forKey: .type)
      try spec.encode(to: encoder)
    }
  }
}

extension ShowSpec.Scalar: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    }
  }
}
