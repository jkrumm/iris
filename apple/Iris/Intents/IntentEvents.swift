import AppIntents
import Foundation
import os

/// How an intent reports that it ran and how it ended (`intent.perform`, `intent.result`). The file is compiled into the app and
/// into the widget extension, which have different reach:
///
/// - **App process** (a `LiveActivityIntent` is performed here, by design): the app registers ``sink`` at launch and every call
///   becomes a console line and a relayed telemetry record.
/// - **Widget extension:** console line only. The extension has no way to the server: the URL is in the app's `UserDefaults`
///   (a Personal Team has no App Group to share it) and posting would need the token from a Keychain group the free team may not
///   grant. So a press of the Record control that never reaches the app leaves no relayed record: `intent.perform` missing next to a
///   console line from `com.jkrumm.iris.widgets` (`log stream --predicate 'subsystem == "com.jkrumm.iris"'` on a Mac with the
///   phone attached) is the answer, and `handler.present=false` in the app's record is the old `appNotReady`.
struct IntentRun: Sendable {
  let intent: String
  /// `Bundle.main.bundleIdentifier`: the app or the widgets extension.
  let process: String
  let handlerPresent: Bool
  /// The memo the intent is for (the Play intent); `nil` for the intents of the running take.
  let memoID: String?
  /// `systemContext.currentMode` (iOS 26): `background` or `foreground`.
  let mode: String
  let canContinueInForeground: Bool
  /// Milliseconds from the system's timestamp of the press to `perform()`, when the system gives one.
  let pressLagMilliseconds: Int?
}

@MainActor
protocol IntentEventSink: AnyObject {
  func intentPerformed(_ run: IntentRun)
  func intentFinished(intent: String, error: String?)
}

@MainActor
enum IntentEvents {
  private static let logger = Logger(subsystem: "com.jkrumm.iris", category: "intent")
  /// Set by the app at launch. An intent that runs before that (the process was started for it) is held and delivered then.
  static var sink: (any IntentEventSink)? {
    didSet { if let sink { drain(into: sink) } }
  }
  private static var held: [(run: IntentRun?, finished: (intent: String, error: String?)?)] = []
  private static let heldLimit = 20

  /// Runs `body` as the named intent, reporting its entry and exit. A throw is reported and rethrown.
  static func run<Result>(
    _ intent: some AppIntent, named name: String, handlerPresent: Bool, memoID: String? = nil,
    _ body: () async throws -> Result
  ) async throws -> Result {
    let mode = intent.systemContext.currentMode
    let lag = intent.systemContext.preciseTimestamp.map { Int(Date().timeIntervalSince($0) * 1000) }
    let run = IntentRun(
      intent: name, process: Bundle.main.bundleIdentifier ?? "?", handlerPresent: handlerPresent, memoID: memoID,
      mode: mode.debugDescription, canContinueInForeground: mode.canContinueInForeground, pressLagMilliseconds: lag)
    logger.notice(
      "intent.perform \(name, privacy: .public) process=\(run.process, privacy: .public) handler=\(handlerPresent, privacy: .public) mode=\(run.mode, privacy: .public)"
    )
    deliver(run: run)
    do {
      let result = try await body()
      logger.notice("intent.result \(name, privacy: .public) ok")
      deliver(finished: (name, nil))
      return result
    } catch {
      let description = summary(of: error)
      logger.error("intent.result \(name, privacy: .public) error=\(description, privacy: .public)")
      deliver(finished: (name, description))
      throw error
    }
  }

  /// The error's type and, for an enum, its case: never the payload, which can carry a server's words or a path.
  static func summary(of error: any Error) -> String {
    let text = String(describing: error)
    let caseName = text.prefix { $0 != "(" && $0 != " " }
    return "\(type(of: error)).\(caseName)"
  }

  private static func deliver(run: IntentRun) {
    guard let sink else { return hold((run, nil)) }
    sink.intentPerformed(run)
  }

  private static func deliver(finished: (intent: String, error: String?)) {
    guard let sink else { return hold((nil, finished)) }
    sink.intentFinished(intent: finished.intent, error: finished.error)
  }

  private static func hold(_ entry: (run: IntentRun?, finished: (intent: String, error: String?)?)) {
    if held.count < heldLimit { held.append(entry) }
  }

  private static func drain(into sink: any IntentEventSink) {
    let entries = held
    held = []
    for entry in entries {
      if let run = entry.run { sink.intentPerformed(run) }
      if let finished = entry.finished { sink.intentFinished(intent: finished.intent, error: finished.error) }
    }
  }
}
