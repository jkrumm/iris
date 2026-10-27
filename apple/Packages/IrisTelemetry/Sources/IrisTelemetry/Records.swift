import Foundation

/// A span or log attribute value. Encodes as a plain JSON scalar (string, number or boolean); a whole-number double
/// may therefore decode back as an int, which OTLP consumers treat as the same numeric.
public enum AttributeValue: Hashable, Sendable, Codable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Attribute must be a JSON scalar")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    }
  }
}

extension AttributeValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public enum SpanStatus: String, Hashable, Sendable, Codable {
  case unset
  case ok
  case error
}

public enum LogSeverity: String, Hashable, Sendable, Codable {
  case info
  case warn
  case error
}

/// A finished span. JSON keys are camelCase; `parentSpanId` is omitted for a root span.
public struct SpanRecord: Hashable, Sendable, Codable {
  public var traceID: TraceID
  public var spanID: SpanID
  public var parentSpanID: SpanID?
  public var name: String
  public var start: Date
  public var end: Date
  public var status: SpanStatus
  public var attributes: [String: AttributeValue]

  public init(
    traceID: TraceID,
    spanID: SpanID,
    parentSpanID: SpanID? = nil,
    name: String,
    start: Date,
    end: Date,
    status: SpanStatus = .ok,
    attributes: [String: AttributeValue] = [:]
  ) {
    self.traceID = traceID
    self.spanID = spanID
    self.parentSpanID = parentSpanID
    self.name = name
    self.start = start
    self.end = end
    self.status = status
    self.attributes = attributes
  }

  private enum CodingKeys: String, CodingKey {
    case traceID = "traceId"
    case spanID = "spanId"
    case parentSpanID = "parentSpanId"
    case name
    case start = "startTime"
    case end = "endTime"
    case status
    case attributes
  }
}

/// A log line. JSON keys are camelCase; `traceId` is omitted when the log belongs to no trace.
public struct LogRecord: Hashable, Sendable, Codable {
  public var timestamp: Date
  public var severity: LogSeverity
  public var body: String
  public var traceID: TraceID?
  public var attributes: [String: AttributeValue]

  public init(
    timestamp: Date,
    severity: LogSeverity = .info,
    body: String,
    traceID: TraceID? = nil,
    attributes: [String: AttributeValue] = [:]
  ) {
    self.timestamp = timestamp
    self.severity = severity
    self.body = body
    self.traceID = traceID
    self.attributes = attributes
  }

  private enum CodingKeys: String, CodingKey {
    case timestamp
    case severity
    case body
    case traceID = "traceId"
    case attributes
  }
}

/// Which client produced the batch; becomes `service.name` on the server.
public enum TelemetryService: String, Hashable, Sendable, Codable {
  case ios = "iris-ios"
  case macos = "iris-macos"
}

public struct TelemetryResource: Hashable, Sendable, Codable {
  public var serviceName: TelemetryService
  public var deviceName: String
  public var appVersion: String

  public init(serviceName: TelemetryService, deviceName: String, appVersion: String) {
    self.serviceName = serviceName
    self.deviceName = deviceName
    self.appVersion = appVersion
  }
}

/// The body of `POST /v1/telemetry`.
///
/// Proposed wire shape, server endpoint pending. Compact JSON, sorted keys, camelCase, dates as ISO 8601 UTC with
/// millisecond precision (`2026-10-27T12:00:00.250Z`), ids as lowercase hex (32 for traces, 16 for spans):
///
///     {"dropped":0,
///      "logs":[{"attributes":{},"body":"outbox.retry","severity":"warn","timestamp":"…","traceId":"…"}],
///      "resource":{"appVersion":"1.0.0","deviceName":"iPhone","serviceName":"iris-ios"},
///      "spans":[{"attributes":{"segment":2},"endTime":"…","name":"segment.upload","parentSpanId":"…",
///                "spanId":"…","startTime":"…","status":"ok","traceId":"…"}]}
///
/// `dropped` is the number of records the client discarded on buffer overflow since the previous batch.
/// Delivery is at-least-once: a batch whose response was lost, or whose records were recovered from the crash file
/// after being sent, can arrive twice. `(traceId, spanId)` identifies a span for de-duplication.
public struct TelemetryBatch: Hashable, Sendable, Codable {
  public var resource: TelemetryResource
  public var spans: [SpanRecord]
  public var logs: [LogRecord]
  public var dropped: Int

  public init(resource: TelemetryResource, spans: [SpanRecord] = [], logs: [LogRecord] = [], dropped: Int = 0) {
    self.resource = resource
    self.spans = spans
    self.logs = logs
    self.dropped = dropped
  }

  /// The stable JSON encoding sent on the wire.
  public func jsonData() throws -> Data {
    try TelemetryCoding.makeEncoder().encode(self)
  }
}

/// Shared JSON configuration for the wire and the crash file.
enum TelemetryCoding {
  private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(dateStyle))
    }
    return encoder
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      do {
        return try dateStyle.parse(value)
      } catch {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date")
      }
    }
    return decoder
  }
}
