import Foundation
import IrisCapture
import IrisTelemetry

/// IrisCapture's `CaptureEvents` port over ``DeviceLog``. Capture does not know about telemetry: this maps its scalars onto
/// telemetry attributes, names the control behind a `take.phase` (`source`), and fills in the memo for events that happen below
/// the take (the audio session, the tap) and so cannot name it themselves.
nonisolated struct DeviceLogCaptureEvents: CaptureEvents {
  let log: DeviceLog

  init(log: DeviceLog = .shared) {
    self.log = log
  }

  func event(_ name: String, memoID: MemoID?, error: Bool, _ attributes: [String: CaptureEventValue]) {
    var mapped = attributes.mapValues(AttributeValue.init)
    if name == "take.phase" {
      mapped["source"] = .string(log.commandSource)
      log.trackTake(memoID, phase: attributes["phase"])
    }
    log.event(name, memoID: memoID ?? log.currentTake, severity: error ? .error : .info, mapped)
  }
}

extension DeviceLogCaptureEvents {
  /// Durable before it returns: the breadcrumb before the call that can abort the process (`capture.tap.install`).
  func preflight(_ name: String, memoID: MemoID?, _ attributes: [String: CaptureEventValue]) {
    log.durableEvent(name, memoID: memoID ?? log.currentTake, attributes.mapValues(AttributeValue.init))
  }
}

extension AttributeValue {
  nonisolated init(_ value: CaptureEventValue) {
    switch value {
    case .string(let text): self = .string(text)
    case .int(let number): self = .int(number)
    case .double(let number): self = .double(number)
    case .bool(let flag): self = .bool(flag)
    }
  }
}
