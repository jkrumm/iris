import Foundation

/// Lowercase hex validation shared by the id types.
private func isLowercaseHex(_ value: String, length: Int) -> Bool {
  value.utf8.count == length && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
}

/// A 128-bit trace id as 32 lowercase hex characters.
///
/// For a memo the trace id is the memo UUID lowercased with the dashes stripped (TDD D8), so the phone, the server
/// and usage rows join without an extra column.
public struct TraceID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let hex: String

  public init(memoID: UUID) {
    hex = memoID.uuidString.lowercased().filter { $0 != "-" }
  }

  /// Fails unless `hex` is exactly 32 lowercase hex characters.
  public init?(hex: String) {
    guard isLowercaseHex(hex, length: 32) else { return nil }
    self.hex = hex
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let id = TraceID(hex: value) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Trace id must be 32 lowercase hex")
    }
    self = id
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(hex)
  }

  public var description: String { hex }
}

/// A 64-bit span id as 16 lowercase hex characters.
public struct SpanID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let hex: String

  /// Formats `value` as zero-padded hex.
  public init(_ value: UInt64) {
    let digits = String(value, radix: 16)
    hex = String(repeating: "0", count: 16 - digits.count) + digits
  }

  /// Fails unless `hex` is exactly 16 lowercase hex characters.
  public init?(hex: String) {
    guard isLowercaseHex(hex, length: 16) else { return nil }
    self.hex = hex
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let id = SpanID(hex: value) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Span id must be 16 lowercase hex")
    }
    self = id
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(hex)
  }

  public var description: String { hex }
}

/// Source of span ids. Mutating so deterministic fakes need no shared state; `Tracer` owns the only instance.
public protocol SpanIDGenerator: Sendable {
  mutating func nextSpanID() -> SpanID
}

/// Production generator: random non-zero ids from the system generator.
public struct RandomSpanIDGenerator: SpanIDGenerator {
  public init() {}

  public mutating func nextSpanID() -> SpanID {
    SpanID(UInt64.random(in: 1...UInt64.max))
  }
}
