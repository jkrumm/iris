import Foundation
import IrisCapture
import IrisTelemetry
import Synchronization
import SwiftUI
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
  private let source = CommandSourceBox()
  private let take = Mutex<UUID?>(nil)

  private static let phaseKey = "com.jkrumm.iris.telemetry.lastPhase"
  private static let runIDKey = "com.jkrumm.iris.telemetry.runID"

  init(events: DeviceEventLog, exporter: RelayExporter, suiteName: String? = nil) {
    self.events = events
    self.exporter = exporter
    self.suiteName = suiteName
    let defaults = Self.defaults(suiteName)
    previousPhase = defaults.string(forKey: Self.phaseKey) ?? "first"
    events.setAmbient("process", .string("app"))
    events.setRunID(defaults.string(forKey: Self.runIDKey))
  }

  /// The run id saved by Settings > Diagnostics (empty when none).
  var runID: String { events.runID ?? "" }

  /// Every record after this carries `run.id`; saved, so it survives a relaunch. Blank clears it.
  func setRunID(_ id: String) {
    events.setRunID(id)
    defaults.set(events.runID, forKey: Self.runIDKey)
  }

  /// Records one event of the memo `memoID` (the trace id is the id without dashes).
  func event(
    _ name: String, memoID: UUID? = nil, severity: LogSeverity = .info, _ attributes: [String: AttributeValue] = [:]
  ) {
    events.event(name, memoID: memoID, severity: severity, attributes)
  }

  /// An event that is in the crash file when this returns (``DeviceEventLog/durableEvent(_:memoID:timeout:_:)``).
  func durableEvent(_ name: String, memoID: UUID? = nil, _ attributes: [String: AttributeValue] = [:]) {
    events.durableEvent(name, memoID: memoID, attributes)
  }

  /// The same for a memo id as the wire carries it (lowercase UUID); an id that is not a UUID records no memo.
  func event(
    _ name: String, memoWireID: String?, severity: LogSeverity = .info, _ attributes: [String: AttributeValue] = [:]
  ) {
    events.event(name, memoID: memoWireID.flatMap(UUID.init(uuidString:)), severity: severity, attributes)
  }

  /// Which control the last take command came from (`app`, `banner`, `island`, `intent`, `thread`): `take.phase` carries it. A
  /// phase change no command asked for (an interruption, a failure) reports ``CommandSource/system`` once the command is
  /// ``CommandSource/freshness`` old, instead of crediting an old press.
  var commandSource: String {
    get { source.current() }
    set { source.set(newValue) }
  }

  /// The take in progress, so an event from below the take (the audio session, the tap) joins its trace.
  var currentTake: UUID? { take.withLock { $0 } }

  /// Follows `take.phase`: a take starts with `starting` and ends with `stopped`.
  func trackTake(_ memoID: UUID?, phase: CaptureEventValue?) {
    guard case .string(let name)? = phase else { return }
    take.withLock { $0 = name == "stopped" ? nil : (memoID ?? $0) }
  }

  /// The server the saved connection points at, or none. Every record from here on is bound to it (`server.id`), and the transport
  /// delivers a record only to that server: a queue written for one server is never handed to another after a switch.
  func serverChanged(_ url: URL?) {
    events.setAmbient("server.id", url.map { .string(TelemetryBootstrap.serverID($0)) })
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

  /// ``flush()`` that gives up after `budget`: what is not sent stays in the crash file for the next launch or the next 10 s tick.
  /// The background-task assertion rides on this, so a send that never answers cannot hold it.
  func flush(within budget: Duration) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.flush() }
      group.addTask { try? await Task.sleep(for: budget) }
      await group.next()
      group.cancelAll()
    }
  }

  /// How long the flush on backgrounding may hold the assertion. The system allows about 30 s and kills the app after it.
  static let backgroundFlushBudget = Duration.seconds(20)

  /// The scene moved: `app.lifecycle`, the ambient `app.state` for every record after it, and a flush when it left the screen.
  @MainActor
  func sceneChanged(to phase: String) {
    events.setAmbient("app.state", .string(phase))
    defaults.set(phase, forKey: Self.phaseKey)
    event("app.lifecycle", ["scene.phase": .string(phase), "reason": "scene_phase"])
    if phase == "background" { flushInBackgroundTask() }
  }

  #if canImport(UIKit)
    /// The flush holds a background-task assertion, so the process is not suspended with the batch half sent. The assertion
    /// ends with the flush, at ``backgroundFlushBudget``, or when the system's expiry handler runs, whichever is first.
    @MainActor
    func flushInBackgroundTask() {
      let assertion = BackgroundAssertion()
      let flushing = Task { await flush(within: Self.backgroundFlushBudget) }
      assertion.begin(name: "iris.telemetry.flush") { flushing.cancel() }
      // Ends with the flush; owned by nobody else because the flush is bounded.
      Task {
        await flushing.value
        assertion.end()
      }
    }
  #else
    @MainActor
    func flushInBackgroundTask() {
      Task { await flush(within: Self.backgroundFlushBudget) }
    }
  #endif
}

#if canImport(UIKit)
  /// One `UIApplication` background task that is ended exactly once, whether the work finished or the system ran out of time.
  @MainActor
  private final class BackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin(name: String, onExpiry: @escaping @MainActor @Sendable () -> Void) {
      identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
        onExpiry()
        end()
      }
    }

    func end() {
      guard identifier != .invalid else { return }
      UIApplication.shared.endBackgroundTask(identifier)
      identifier = .invalid
    }
  }
#endif

/// What the launch reports about each file the capture stack set aside (`capture.quarantine`). The files are read, so this is
/// off the main actor: a recording can be megabytes, and the launch path must not wait for a disk.
nonisolated enum QuarantineInspector {
  /// A finalised m4a has a `moov` atom; one the process died while writing has none and no tool reads it.
  static func hasMovieAtom(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
    return data.range(of: Data("moov".utf8)) != nil
  }

  static func attributes(of file: SetAsideFile) -> [String: AttributeValue] {
    [
      "file": .string(file.url.lastPathComponent), "bytes": .int(file.byteCount),
      "has_moov": .bool(file.url.pathExtension == "m4a" ? hasMovieAtom(file.url) : false),
    ]
  }
}

extension DeviceLog {
  /// One `capture.quarantine` record per set-aside file: the server never hears of a file in that folder, so the data-loss case
  /// is visible at once. The files are inspected on the cooperative pool, never the caller's actor.
  @concurrent
  func recordQuarantine(_ files: [SetAsideFile]) async {
    for file in files {
      event("capture.quarantine", severity: .warn, QuarantineInspector.attributes(of: file))
    }
  }
}

/// The control behind the latest take command, with the moment it was given.
nonisolated enum CommandSource {
  /// A phase change no recent command asked for: an interruption, a failure, the system ending a take.
  static let system = "system"
  /// How long a command stays the explanation of the phases that follow (a start waits for the microphone prompt).
  static let freshness = Duration.seconds(60)
}

nonisolated final class CommandSourceBox: Sendable {
  private struct Command {
    let source: String
    let at: ContinuousClock.Instant
  }

  private let latest = Mutex<Command?>(nil)
  private let now: @Sendable () -> ContinuousClock.Instant

  init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
    self.now = now
  }

  func set(_ source: String) {
    let command = Command(source: source, at: now())
    latest.withLock { $0 = command }
  }

  func current() -> String {
    let instant = now()
    return latest.withLock { command in
      guard let command, instant - command.at <= CommandSource.freshness else { return CommandSource.system }
      return command.source
    }
  }
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

/// The app's end of ``IntentEvents``: `intent.perform` and `intent.result` as device records.
@MainActor
final class DeviceLogIntentSink: IntentEventSink {
  private let log: DeviceLog
  /// The memo each intent was for when it started, so its result joins the same trace after the take is gone (a Stop).
  private var memoAtPerform: [String: String] = [:]

  init(log: DeviceLog = .shared) {
    self.log = log
  }

  func intentPerformed(_ run: IntentRun) {
    var attributes: [String: AttributeValue] = [
      "intent": .string(run.intent), "process": .string(run.process), "handler.present": .bool(run.handlerPresent),
      "mode": .string(run.mode), "can_continue_in_foreground": .bool(run.canContinueInForeground),
    ]
    if let lag = run.pressLagMilliseconds { attributes["press_lag_ms"] = .int(lag) }
    // The take's memo, so Stop, Pause and Switch join the take's trace; a Start has none yet.
    let memo = run.memoID ?? log.currentTake?.uuidString.lowercased()
    memoAtPerform[run.intent] = memo
    log.event("intent.perform", memoWireID: memo, attributes)
  }

  func intentFinished(intent: String, error: String?) {
    var attributes: [String: AttributeValue] = ["intent": .string(intent), "ok": .bool(error == nil)]
    if let error { attributes["error"] = .string(error) }
    // A Start has its memo now; the others keep the one they started with.
    let memo = memoAtPerform.removeValue(forKey: intent)
    log.event(
      "intent.result", memoWireID: log.currentTake?.uuidString.lowercased() ?? memo,
      severity: error == nil ? .info : .error, attributes)
  }
}

/// `ui.screen` for a view that appears and disappears: a pushed detail, a thread, a composer.
struct ReportsScreen: ViewModifier {
  let name: String

  func body(content: Content) -> some View {
    content
      .onAppear { DeviceLog.shared.event("ui.screen", ["screen": .string(name), "shown": true]) }
      .onDisappear { DeviceLog.shared.event("ui.screen", ["screen": .string(name), "shown": false]) }
  }
}

extension View {
  /// Reports this view's name to the device log when it appears and when it goes (`ui.screen`).
  func reportsScreen(_ name: String) -> some View {
    modifier(ReportsScreen(name: name))
  }
}
