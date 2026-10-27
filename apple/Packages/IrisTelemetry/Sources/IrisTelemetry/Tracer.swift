import Foundation

/// A span that has started and not yet ended. Hand it back to `Tracer.end`.
public struct ActiveSpan: Hashable, Sendable {
  public let traceID: TraceID
  public let spanID: SpanID
  public let parentSpanID: SpanID?
  public let name: String
  public let startTime: Date
  public let attributes: [String: AttributeValue]
}

/// Creates spans and logs and writes them into the buffer, stamping times from the clock and ids from the generator.
public actor Tracer {
  private let buffer: TelemetryBuffer
  private let clock: any TelemetryClock
  private var ids: any SpanIDGenerator

  public init(
    buffer: TelemetryBuffer,
    clock: any TelemetryClock = SystemTelemetryClock(),
    ids: any SpanIDGenerator = RandomSpanIDGenerator()
  ) {
    self.buffer = buffer
    self.clock = clock
    self.ids = ids
  }

  public func startSpan(
    _ name: String,
    traceID: TraceID,
    parent: SpanID? = nil,
    attributes: [String: AttributeValue] = [:]
  ) -> ActiveSpan {
    ActiveSpan(
      traceID: traceID,
      spanID: ids.nextSpanID(),
      parentSpanID: parent,
      name: name,
      startTime: clock.now(),
      attributes: attributes
    )
  }

  /// Ends the span now; `attributes` are merged over the ones it started with.
  public func end(
    _ span: ActiveSpan,
    status: SpanStatus = .ok,
    attributes: [String: AttributeValue] = [:]
  ) async {
    await buffer.record(
      span: SpanRecord(
        traceID: span.traceID,
        spanID: span.spanID,
        parentSpanID: span.parentSpanID,
        name: span.name,
        start: span.startTime,
        end: clock.now(),
        status: status,
        attributes: span.attributes.merging(attributes) { _, new in new }
      ))
  }

  /// Runs `operation` inside a span. A throw ends the span with `.error` and the error's type (never its message) as
  /// `error.type`, then rethrows.
  public func withSpan<T: Sendable>(
    _ name: String,
    traceID: TraceID,
    parent: SpanID? = nil,
    attributes: [String: AttributeValue] = [:],
    operation: @Sendable (ActiveSpan) async throws -> T
  ) async rethrows -> T {
    let span = startSpan(name, traceID: traceID, parent: parent, attributes: attributes)
    do {
      let result = try await operation(span)
      await end(span)
      return result
    } catch {
      await end(span, status: .error, attributes: ["error.type": .string(String(describing: type(of: error)))])
      throw error
    }
  }

  public func log(
    _ body: String,
    severity: LogSeverity = .info,
    traceID: TraceID? = nil,
    attributes: [String: AttributeValue] = [:]
  ) async {
    await buffer.record(
      log: LogRecord(
        timestamp: clock.now(),
        severity: severity,
        body: body,
        traceID: traceID,
        attributes: attributes
      ))
  }
}
