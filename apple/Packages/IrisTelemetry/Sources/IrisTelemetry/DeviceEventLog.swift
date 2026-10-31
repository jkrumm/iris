import CryptoKit
import Foundation
import Synchronization

/// The one door for every device event: a capture error, a route change, an intent, a Live Activity call.
///
/// A call does three things, synchronously and in this order, so the numbers on a record mean what they say:
///   1. takes the next `seq`, reads `uptime_ms` and queues the record under one lock (a higher `seq` is never an earlier
///      uptime or a later queue position; a lock because callers are notification handlers and audio-adjacent code
///      that cannot await),
///   2. writes one console line (`os.Logger` in the app, category = the part of the name before the first dot),
///   3. hands one `LogRecord` to the buffer, in `seq` order, through a single consumer. The buffer mirrors every record
///      to its store before it is acknowledged, so a record that reached the buffer survives a kill.
///
/// Record shape: `Body` is the event name; `event.name`, `seq` (per process), `uptime_ms` (monotonic, since this log was
/// created), `app.pid`, `memo.id` (the trace id, 32 hex, when the event belongs to a memo) and `run.id` (when set) are
/// reserved and always win over a caller's attribute of the same name. Ambient attributes (`app.state`, `process`, ...)
/// ride on every record unless the caller sets the key itself.
///
/// Privacy: an attribute whose key names a token, transcript, reply, secret, password or authorization is dropped, and a
/// string value is cut at ``maxValueLength``. Callers still must not pass such data; this is the net under them.
public final class DeviceEventLog: Sendable {
  public typealias Console = @Sendable (_ category: String, _ severity: LogSeverity, _ line: String) -> Void

  /// A string attribute longer than this is cut (an error description, a call stack).
  public static let maxValueLength = 240

  private static let forbiddenKeyParts = ["token", "transcript", "reply", "secret", "password", "authorization"]

  private enum Item: Sendable {
    case log(LogRecord)
    case barrier(CheckedContinuation<Void, Never>)
  }

  private struct State {
    var sequence: UInt64 = 0
    var runID: String?
    var ambient: [String: AttributeValue] = [:]
  }

  private let state = Mutex(State())
  private let clock: any TelemetryClock
  private let uptimeMilliseconds: @Sendable () -> Int
  private let processID: Int
  private let console: Console
  private let intake: AsyncStream<Item>.Continuation

  /// - Parameters:
  ///   - uptimeMilliseconds: milliseconds on a monotonic clock since the process started; injected for tests.
  public init(
    buffer: TelemetryBuffer,
    clock: any TelemetryClock = SystemTelemetryClock(),
    processID: Int = Int(ProcessInfo.processInfo.processIdentifier),
    uptimeMilliseconds: (@Sendable () -> Int)? = nil,
    console: @escaping Console = { _, _, _ in }
  ) {
    self.clock = clock
    self.processID = processID
    self.console = console
    if let uptimeMilliseconds {
      self.uptimeMilliseconds = uptimeMilliseconds
    } else {
      let origin = ContinuousClock.now
      self.uptimeMilliseconds = {
        let elapsed = ContinuousClock.now - origin
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
      }
    }
    let (items, intake) = AsyncStream.makeStream(of: Item.self)
    self.intake = intake
    // The single consumer: records reach the buffer in call order. Ends when `deinit` finishes the stream.
    Task {
      for await item in items {
        switch item {
        case .log(let record): await buffer.record(log: record)
        case .barrier(let continuation): continuation.resume()
        }
      }
    }
  }

  deinit {
    intake.finish()
  }

  /// Records one event. `name` is `area.thing` (`capture.session.error`); the area becomes the console category.
  public func event(
    _ name: String, memoID: UUID? = nil, severity: LogSeverity = .info, _ attributes: [String: AttributeValue] = [:]
  ) {
    let traceID = memoID.map(TraceID.init(memoID:))
    let cleaned = Self.sanitized(attributes)
    let record = state.withLock { state -> LogRecord in
      state.sequence += 1
      var merged = state.ambient.merging(cleaned) { _, caller in caller }
      merged["event.name"] = .string(name)
      merged["seq"] = .int(Int(state.sequence))
      merged["uptime_ms"] = .int(uptimeMilliseconds())
      merged["app.pid"] = .int(processID)
      merged["memo.id"] = traceID.map { .string($0.hex) }
      merged["run.id"] = state.runID.map { .string($0) }
      let record = LogRecord(
        timestamp: clock.now(), severity: severity, body: name, traceID: traceID, attributes: merged)
      // Handed over under the same lock that numbered it: the buffer sees records in `seq` order whoever calls.
      intake.yield(.log(record))
      return record
    }
    console(Self.category(of: name), severity, Self.consoleLine(of: record))
  }

  /// Sets (or, with `nil`, removes) an attribute that rides on every following record: `app.state`, `process`.
  public func setAmbient(_ key: String, _ value: AttributeValue?) {
    state.withLock { $0.ambient[key] = value }
  }

  /// The word the owner types once in Settings > Diagnostics, so one round of takes is one filter. Blank clears it.
  public func setRunID(_ id: String?) {
    let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    state.withLock { $0.runID = trimmed.isEmpty ? nil : String(trimmed.prefix(64)) }
  }

  public var runID: String? { state.withLock(\.runID) }

  /// Returns once every event recorded before the call has reached the buffer: call before a flush that must carry them.
  public func settle() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      if case .terminated = intake.yield(.barrier(continuation)) { continuation.resume() }
    }
  }

  // MARK: Pure helpers

  /// A short stable digest for an identifier that must not travel as it is (an audio port uid): 12 hex characters.
  public static func hashed(_ identifier: String) -> String {
    SHA256.hash(data: Data(identifier.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  public static func category(of name: String) -> String {
    name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
  }

  /// `name memo=<8 hex> key=value ...`, keys sorted, for the console line.
  public static func consoleLine(of record: LogRecord) -> String {
    let skipped: Set<String> = ["event.name", "memo.id", "app.pid"]
    let pairs = record.attributes.filter { !skipped.contains($0.key) }.sorted { $0.key < $1.key }
      .map { "\($0.key)=\(describe($0.value))" }
    let memo = record.traceID.map { "memo=\($0.hex.prefix(8))" }
    return ([record.body, memo].compactMap { $0 } + pairs).joined(separator: " ")
  }

  static func sanitized(_ attributes: [String: AttributeValue]) -> [String: AttributeValue] {
    var result: [String: AttributeValue] = [:]
    for (key, value) in attributes {
      let lowered = key.lowercased()
      if forbiddenKeyParts.contains(where: lowered.contains) { continue }
      if case .string(let text) = value, text.count > maxValueLength {
        result[key] = .string(String(text.prefix(maxValueLength)))
      } else {
        result[key] = value
      }
    }
    return result
  }

  private static func describe(_ value: AttributeValue) -> String {
    switch value {
    case .string(let text): text
    case .int(let number): String(number)
    case .double(let number): String(format: "%.1f", number)
    case .bool(let flag): String(flag)
    }
  }
}
