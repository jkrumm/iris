import Foundation
import Observation

/// What the Mac app needs from an update engine: whether a check may start now, and starting one. Production is Sparkle
/// (``SparkleUpdateEngine``); tests and the fake composition use ``ScriptedUpdateEngine``.
@MainActor
protocol UpdateEngine: AnyObject {
  /// False while a check or an install is already running, or before the engine has started.
  var canCheckForUpdates: Bool { get }
  /// Set by the owner; the engine calls it on the main actor whenever ``canCheckForUpdates`` may have changed.
  var onAvailabilityChange: (() -> Void)? { get set }
  /// What the last check found. Set by the engine's own scheduled and user-initiated checks.
  var status: UpdateStatus { get }
  /// Set by the owner; the engine calls it on the main actor whenever ``status`` changes.
  var onStatusChange: (() -> Void)? { get set }
  /// A user-initiated check: Sparkle shows its own window (no update, an update, an error).
  func checkForUpdates()
}

/// What the app knows about its own version: nothing before the first check ends, then either current or behind.
enum UpdateStatus: Equatable {
  case unknown
  case upToDate
  /// `version` is the marketing version of the update (what Sparkle's alert shows), `build` its `CFBundleVersion`.
  case available(version: String, build: String)

  var availableVersion: String? {
    guard case .available(let version, _) = self else { return nil }
    return version
  }
}

/// The running app's own version, read from its bundle: "0.3.1" and "816".
struct AppVersion: Equatable {
  let marketing: String
  let build: String

  init(marketing: String, build: String) {
    self.marketing = marketing
    self.build = build
  }

  init(bundle: Bundle = .main) {
    let info = bundle.infoDictionary
    self.init(
      marketing: info?["CFBundleShortVersionString"] as? String ?? "?",
      build: info?["CFBundleVersion"] as? String ?? "?")
  }

  /// "0.3.1 (816)", as Settings shows it.
  var display: String { "\(marketing) (\(build))" }
}

/// The Mac app's update state, owned by `MacCompositionRoot`. The menu items ("Check for Updates…" in the popover and in
/// Settings > General) read ``canCheckForUpdates`` and call ``checkForUpdates()``; Sparkle's own windows do everything else
/// (the scheduled background check, the release notes, the download and the swap of the bundle).
@MainActor
@Observable
final class Updater {
  private(set) var canCheckForUpdates: Bool
  /// Whether the last check found a newer version; the main window and the popover show a quiet badge only while it is one.
  private(set) var status: UpdateStatus
  @ObservationIgnored private let engine: any UpdateEngine

  init(engine: any UpdateEngine) {
    self.engine = engine
    canCheckForUpdates = engine.canCheckForUpdates
    status = engine.status
    engine.onStatusChange = { [weak self, weak engine] in
      guard let self, let engine else { return }
      status = engine.status
    }
    engine.onAvailabilityChange = { [weak self, weak engine] in
      guard let self, let engine else { return }
      canCheckForUpdates = engine.canCheckForUpdates
    }
  }

  /// The version Sparkle offers, nil while the app is current or has not heard yet.
  var availableVersion: String? { status.availableVersion }

  /// Starts a check when the engine allows one; a second request while one runs does nothing.
  func checkForUpdates() {
    guard canCheckForUpdates else { return }
    engine.checkForUpdates()
  }
}

/// The engine of `-IrisFakeData` and snapshot runs and of the tests: no Sparkle, no network, no window. It records the checks
/// it was asked for, and the owner of a test flips ``canCheckForUpdates`` to script a check in flight.
@MainActor
final class ScriptedUpdateEngine: UpdateEngine {
  var canCheckForUpdates: Bool {
    didSet { onAvailabilityChange?() }
  }
  var onAvailabilityChange: (() -> Void)?
  var status: UpdateStatus {
    didSet { onStatusChange?() }
  }
  var onStatusChange: (() -> Void)?
  private(set) var checks = 0

  init(canCheckForUpdates: Bool = true, status: UpdateStatus = .unknown) {
    self.canCheckForUpdates = canCheckForUpdates
    self.status = status
  }

  func checkForUpdates() {
    checks += 1
  }
}
