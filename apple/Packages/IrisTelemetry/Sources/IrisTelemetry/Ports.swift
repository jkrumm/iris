import Foundation
import os

extension Logger {
  /// Never log payload contents (names, bodies, attributes): counts and error types only.
  static let telemetry = Logger(subsystem: "com.jkrumm.iris", category: "telemetry")
}

/// Wall clock and sleeper. Injected so flush cadence and span timing are deterministic in tests.
public protocol TelemetryClock: Sendable {
  func now() -> Date
  func sleep(for duration: Duration) async throws
}

public struct SystemTelemetryClock: TelemetryClock {
  public init() {}

  public func now() -> Date { Date() }

  public func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

/// Delivers one batch to the server. Throwing means "keep the data and retry later". A send must honour task cancellation:
/// the exporter ends a send that outlives its time bound by cancelling it.
public protocol TelemetryTransport: Sendable {
  func send(_ batch: TelemetryBatch) async throws
}

/// A buffered span or log.
public enum TelemetryEntry: Hashable, Sendable, Codable {
  case span(SpanRecord)
  case log(LogRecord)

  private enum CodingKeys: String, CodingKey {
    case kind
    case span
    case log
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "span": self = .span(try container.decode(SpanRecord.self, forKey: .span))
    case "log": self = .log(try container.decode(LogRecord.self, forKey: .log))
    default:
      throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown entry kind")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .span(let span):
      try container.encode("span", forKey: .kind)
      try container.encode(span, forKey: .span)
    case .log(let log):
      try container.encode("log", forKey: .kind)
      try container.encode(log, forKey: .log)
    }
  }
}

/// An entry with its buffer-assigned, monotonically increasing sequence number.
public struct StoredEntry: Hashable, Sendable, Codable {
  public var sequence: UInt64
  public var entry: TelemetryEntry

  public init(sequence: UInt64, entry: TelemetryEntry) {
    self.sequence = sequence
    self.entry = entry
  }
}

/// Crash-survival persistence behind the buffer. Appends happen on every record; entries leave the store only through
/// `removeThrough`, once the server has accepted them (or the buffer discarded them on overflow). Removal by sequence
/// is idempotent and independent of append order, so the buffer can interleave calls freely.
public protocol TelemetryStore: Sendable {
  func append(_ entries: [StoredEntry]) async throws
  /// Every readable entry, ordered by sequence. Corrupt lines (a torn write) are skipped.
  func load() async throws -> [StoredEntry]
  /// Removes every entry whose sequence is `<= sequence`.
  func removeThrough(sequence: UInt64) async throws
  func clear() async throws
}

/// Test and fallback adapter; not crash-safe.
public actor InMemoryTelemetryStore: TelemetryStore {
  private var entries: [StoredEntry] = []

  public init() {}

  /// What is currently stored, for assertions.
  public var stored: [StoredEntry] { entries }

  public func append(_ newEntries: [StoredEntry]) {
    entries.append(contentsOf: newEntries)
  }

  public func load() -> [StoredEntry] {
    entries.sorted { $0.sequence < $1.sequence }
  }

  public func removeThrough(sequence: UInt64) {
    entries.removeAll { $0.sequence <= sequence }
  }

  public func clear() {
    entries.removeAll()
  }
}
