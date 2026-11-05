import AppKit
import Foundation
import Sparkle

/// The production ``UpdateEngine``: Sparkle's standard updater (TDD §5 "Updates"). Sparkle reads `SUFeedURL`,
/// `SUPublicEDKey` and `SUEnableAutomaticChecks` from the Info.plist; the app is not sandboxed, so there is no installer XPC
/// service in play and no custom `NSUpdateSecurityPolicy` (Sparkle #2591). Never created under `-IrisFakeData`.
@MainActor
final class SparkleUpdateEngine: UpdateEngine {
  private let controller: SPUStandardUpdaterController
  private var observation: NSKeyValueObservation?
  var onAvailabilityChange: (() -> Void)?

  var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

  init() {
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    // KVO fires on the thread that changed the value; Sparkle changes it on the main thread, and the hop keeps it so either way.
    observation = controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
      Task { @MainActor in self?.onAvailabilityChange?() }
    }
  }

  func checkForUpdates() {
    // A menu-bar (LSUIElement) app has no active window: bring Sparkle's alert in front.
    NSApp.activate()
    controller.updater.checkForUpdates()
  }
}
