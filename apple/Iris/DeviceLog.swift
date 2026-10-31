import Foundation
import IrisTelemetry
import Synchronization
import os

#if canImport(UIKit)
  import UIKit
#endif

/// Every device event goes through here: one `os.Logger` line (subsystem `com.jkrumm.iris`, category = the area before the
/// first dot of the event name) **and** one telemetry record, relayed to `POST /v1/telemetry` (TDD §8) so a device run can
/// be read in HyperDX without the owner narrating it. `docs/TDD.md` §8 lists the records and their attributes.
///
/// Records are buffered through the crash file (``TelemetryBootstrap``), flushed at launch, every 10 s, and when the app
/// goes to the background. A singleton on purpose: intents, notification handlers and the audio adapters have no
/// composition root to be handed one by, and the first event can come before the app's scene exists.
nonisolated final class DeviceLog: Sendable {
  static let shared = TelemetryBootstrap.makeDeviceLog()

  let events: DeviceEventLog
  private let exporter: RelayExporter
  /// `nil`: the standard defaults. A name keeps a simulator run away from the real install's markers.
  private let suiteName: String?
  /// `UserDefaults` is thread-safe but not `Sendable`: opened per use instead of stored.
  private var defaults: UserDefaults { Self.defaults(suiteName) }

  private static func defaults(_ suiteName: String?) -> UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }
  /// The scene phase the last run reported last (`active`, `inactive`, `background`), read before this run writes its own.
  let previousPhase: String
  private let source = Mutex("app")

  private static let phaseKey = "com.jkrumm.iris.telemetry.lastPhase"

  init(events: DeviceEventLog, exporter: RelayExporter, suiteName: String? = nil) {
    self.events = events
    self.exporter = exporter
    self.suiteName = suiteName
    let defaults = Self.defaults(suiteName)
    previousPhase = defaults.string(forKey: Self.phaseKey) ?? "first"
    events.setAmbient("process", .string("app"))
  }

  /// Records one event of the memo `memoID` (the trace id is the id without dashes).
  func event(
    _ name: String, memoID: UUID? = nil, severity: LogSeverity = .info, _ attributes: [String: AttributeValue] = [:]
  ) {
    events.event(name, memoID: memoID, severity: severity, attributes)
  }

  /// The same for a memo id as the wire carries it (lowercase UUID); an id that is not a UUID records no memo.
  func event(
    _ name: String, memoWireID: String?, severity: LogSeverity = .info, _ attributes: [String: AttributeValue] = [:]
  ) {
    events.event(name, memoID: memoWireID.flatMap(UUID.init(uuidString:)), severity: severity, attributes)
  }

  /// Which control the next take command came from (`app`, `banner`, `island`, `intent`, `thread`): `take.phase` carries it.
  var commandSource: String {
    get { source.withLock { $0 } }
    set { source.withLock { $0 = newValue } }
  }

  /// Starts the relay: sends what a killed run left in the crash file, then flushes every 10 s for the life of the process.
  func start() {
    // Owned by the process: the relay loop ends with it.
    Task {
      await exporter.flushOnLaunch()
      await exporter.run()
    }
  }

  /// Every event recorded so far reaches the relay (or stays in the crash file when the server is not reachable).
  func flush() async {
    await events.settle()
    await exporter.flush()
  }

  /// The scene moved: `app.lifecycle`, the ambient `app.state` for every record after it, and a flush when it left the screen.
  @MainActor
  func sceneChanged(to phase: String) {
    events.setAmbient("app.state", .string(phase))
    defaults.set(phase, forKey: Self.phaseKey)
    event("app.lifecycle", ["scene.phase": .string(phase), "reason": "scene_phase"])
    if phase == "background" { flushInBackgroundTask() }
  }

  #if canImport(UIKit)
    /// The flush holds a background-task assertion, so the process is not suspended with the batch half sent.
    @MainActor
    func flushInBackgroundTask() {
      let application = UIApplication.shared
      let flushing = Task { await flush() }
      let assertion = application.beginBackgroundTask(withName: "iris.telemetry.flush") { flushing.cancel() }
      // Ends with the flush (or with the cancellation the expiry handler asks for).
      Task {
        await flushing.value
        application.endBackgroundTask(assertion)
      }
    }
  #else
    @MainActor
    func flushInBackgroundTask() {
      Task { await flush() }
    }
  #endif
}

/// The console half: an `os.Logger` per area.
nonisolated enum DeviceConsole {
  static let subsystem = "com.jkrumm.iris"

  static let write: DeviceEventLog.Console = { category, severity, line in
    let logger = Logger(subsystem: subsystem, category: category)
    switch severity {
    case .info: logger.notice("\(line, privacy: .public)")
    case .warn: logger.warning("\(line, privacy: .public)")
    case .error: logger.error("\(line, privacy: .public)")
    }
  }
}
