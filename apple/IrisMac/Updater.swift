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
  /// A user-initiated check: Sparkle shows its own window (no update, an update, an error).
  func checkForUpdates()
}

/// The Mac app's update state, owned by `MacCompositionRoot`. The menu items ("Check for Updates…" in the popover and in
/// Settings > General) read ``canCheckForUpdates`` and call ``checkForUpdates()``; Sparkle's own windows do everything else
/// (the scheduled background check, the release notes, the download and the swap of the bundle).
@MainActor
@Observable
final class Updater {
  private(set) var canCheckForUpdates: Bool
  @ObservationIgnored private let engine: any UpdateEngine

  init(engine: any UpdateEngine) {
    self.engine = engine
    canCheckForUpdates = engine.canCheckForUpdates
    engine.onAvailabilityChange = { [weak self, weak engine] in
      guard let self, let engine else { return }
      canCheckForUpdates = engine.canCheckForUpdates
    }
  }

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
  private(set) var checks = 0

  init(canCheckForUpdates: Bool = true) {
    self.canCheckForUpdates = canCheckForUpdates
  }

  func checkForUpdates() {
    checks += 1
  }
}
