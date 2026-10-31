import Foundation
import Synchronization

/// A value on a capture event. Plain scalars, so the app maps them one to one onto a telemetry attribute.
public enum CaptureEventValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)

  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Where capture reports what happened to the device log: session errors, route and configuration changes, interruptions,
/// the tap, segments, gaps. The app maps it onto `os.Logger` plus a relayed telemetry record (`DeviceLog`); IrisCapture
/// does not know about telemetry. Never pass a transcript, a token or a port uid (hash it): the app adds nothing to hide them.
public protocol CaptureEvents: Sendable {
  /// `name` is `area.thing` (`capture.gap`, `audio.route_change`); `memoID` joins the record to the take's trace.
  func event(_ name: String, memoID: MemoID?, error: Bool, _ attributes: [String: CaptureEventValue])
}

extension CaptureEvents {
  public func event(_ name: String, memoID: MemoID? = nil, _ attributes: [String: CaptureEventValue] = [:]) {
    event(name, memoID: memoID, error: false, attributes)
  }
}

/// The default: capture says nothing (tests, the Mac app).
public struct NoCaptureEvents: CaptureEvents {
  public init() {}
  public func event(_ name: String, memoID: MemoID?, error: Bool, _ attributes: [String: CaptureEventValue]) {}
}

/// Keeps every event in order, for tests and fakes.
public final class RecordingCaptureEvents: CaptureEvents {
  public struct Entry: Sendable, Equatable {
    public let name: String
    public let memoID: MemoID?
    public let error: Bool
    public let attributes: [String: CaptureEventValue]
  }

  private let recorded = Mutex<[Entry]>([])

  public init() {}

  public func event(_ name: String, memoID: MemoID?, error: Bool, _ attributes: [String: CaptureEventValue]) {
    recorded.withLock { $0.append(Entry(name: name, memoID: memoID, error: error, attributes: attributes)) }
  }

  public var entries: [Entry] { recorded.withLock { $0 } }
  public func entries(named name: String) -> [Entry] { entries.filter { $0.name == name } }
}
