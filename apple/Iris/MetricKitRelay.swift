import Foundation
import IrisTelemetry
import MetricKit

/// Crash, hang and CPU-exception diagnostics from MetricKit become `metrickit.crash|hang|cpu_exception` records. The system
/// delivers them on the launch after the event (a payload is up to a day behind), so they ride the relay of that launch. This is
/// where a watchdog kill (`0x8BADF00D`) or a crash the process could not log announces itself, with no `.ips` pulled by hand.
///
/// Uses the subscriber API, which iOS 26 and 27 both deliver; iOS 27's `MetricManager.diagnosticReports` is its replacement and
/// is not needed until the subscriber goes.
nonisolated final class MetricKitRelay: NSObject, MXMetricManagerSubscriber, Sendable {
  static let shared = MetricKitRelay()

  private let log: DeviceLog

  init(log: DeviceLog = .shared) {
    self.log = log
  }

  func start() {
    MXMetricManager.shared.add(self)
  }

  // MetricKit calls this on a background queue.
  nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      let window = ISO8601DateFormatter().string(from: payload.timeStampEnd)
      for crash in payload.crashDiagnostics ?? [] {
        log.event("metrickit.crash", severity: .error, MetricKitRecords.crash(crash, windowEnd: window))
      }
      for hang in payload.hangDiagnostics ?? [] {
        log.event("metrickit.hang", severity: .warn, MetricKitRecords.hang(hang, windowEnd: window))
      }
      for exception in payload.cpuExceptionDiagnostics ?? [] {
        log.event(
          "metrickit.cpu_exception", severity: .warn, MetricKitRecords.cpuException(exception, windowEnd: window))
      }
    }
  }
}

/// MetricKit diagnostics as event attributes. Nothing here is user content: exception codes, a termination reason, binary names
/// and offsets.
nonisolated enum MetricKitRecords {
  static func crash(_ diagnostic: MXCrashDiagnostic, windowEnd: String) -> [String: AttributeValue] {
    var attributes: [String: AttributeValue] = [
      "app.version": .string(diagnostic.applicationVersion), "window.end": .string(windowEnd),
      "call_stack": .string(MetricKitFrames.top(from: diagnostic.callStackTree.jsonRepresentation())),
    ]
    if let type = diagnostic.exceptionType { attributes["exception.type"] = .int(type.intValue) }
    if let code = diagnostic.exceptionCode { attributes["exception.code"] = .int(code.intValue) }
    if let signal = diagnostic.signal { attributes["signal"] = .int(signal.intValue) }
    if let reason = diagnostic.terminationReason { attributes["termination.reason"] = .string(reason) }
    return attributes
  }

  static func hang(_ diagnostic: MXHangDiagnostic, windowEnd: String) -> [String: AttributeValue] {
    [
      "app.version": .string(diagnostic.applicationVersion), "window.end": .string(windowEnd),
      "hang_ms": .int(Int(diagnostic.hangDuration.converted(to: .milliseconds).value)),
      "call_stack": .string(MetricKitFrames.top(from: diagnostic.callStackTree.jsonRepresentation())),
    ]
  }

  static func cpuException(_ diagnostic: MXCPUExceptionDiagnostic, windowEnd: String) -> [String: AttributeValue] {
    [
      "app.version": .string(diagnostic.applicationVersion), "window.end": .string(windowEnd),
      "cpu_ms": .int(Int(diagnostic.totalCPUTime.converted(to: .milliseconds).value)),
      "sampled_ms": .int(Int(diagnostic.totalSampledTime.converted(to: .milliseconds).value)),
      "call_stack": .string(MetricKitFrames.top(from: diagnostic.callStackTree.jsonRepresentation())),
    ]
  }
}

/// The frames nearest the fault from a MetricKit call-stack tree, as one short string: `Iris+0x1a2b < libswiftCore+0x3c4d`.
/// Frames are binary name and offset into its text segment, the form a dSYM symbolicates (`atos`); the tree JSON is
/// `{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryName":…,"offsetIntoBinaryTextSegment":…,
/// "sampleCount":…,"subFrames":[…]}]}]}`. The shape follows MetricKit's documentation and is not verified on a device payload.
nonisolated enum MetricKitFrames {
  static func top(from json: Data, limit: Int = 6) -> String {
    guard let tree = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
      let stacks = tree["callStacks"] as? [[String: Any]]
    else { return "" }
    let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
    var chain: [String] = []
    var level = stack?["callStackRootFrames"] as? [[String: Any]]
    while let frame = level?.max(by: { count(of: $0) < count(of: $1) }) {
      let name = frame["binaryName"] as? String ?? "?"
      let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber).map { String($0.uint64Value, radix: 16) } ?? "?"
      chain.append("\(name)+0x\(offset)")
      level = frame["subFrames"] as? [[String: Any]]
    }
    return chain.suffix(limit).reversed().joined(separator: " < ")
  }

  private static func count(of frame: [String: Any]) -> Int { frame["sampleCount"] as? Int ?? 0 }
}
