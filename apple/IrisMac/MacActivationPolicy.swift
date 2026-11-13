import AppKit

/// Iris is a menu-bar app (`LSUIElement`: no Dock icon, not in ⌘Tab). While a real window is open (the main window, Settings,
/// onboarding) it is a regular app so ⌘Tab and the Dock find it, and goes back to accessory when the last one closes.
@MainActor
final class MacActivationPolicy {
  /// The facts about a window that decide it; a plain value so the rule is testable without windows.
  struct WindowFacts: Equatable {
    var isVisible: Bool
    var isTitled: Bool
    var canBecomeMain: Bool
  }

  /// A document-style window is visible, titled and can be main. The popover and the floating recording panel are panels:
  /// they cannot become main, so they never make the app regular.
  static func policy(for windows: [WindowFacts]) -> NSApplication.ActivationPolicy {
    windows.contains { $0.isVisible && $0.isTitled && $0.canBecomeMain } ? .regular : .accessory
  }

  /// What a Dock click (or a Finder or Spotlight launch of the running app) should do.
  enum ReopenAction: Equatable {
    case openOnboarding, openMain, bringToFront
  }

  /// Nothing saved: the onboarding is the only useful window. Otherwise the main window, raised if one is already visible.
  static func reopenAction(hasVisibleWindow: Bool, needsOnboarding: Bool) -> ReopenAction {
    if hasVisibleWindow { return .bringToFront }
    return needsOnboarding ? .openOnboarding : .openMain
  }

  /// A visible titled window that can be main, the same test as ``policy(for:)``.
  static func hasVisibleWindow(_ windows: [NSWindow]) -> Bool {
    windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0.canBecomeMain }
  }

  private var observers: [any NSObjectProtocol] = []

  /// Starts following windows. Called once at launch.
  func install() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
          let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
          MainActor.assumeIsolated { self?.update(excluding: closing) }
        })
    }
  }

  private func update(excluding closing: NSWindow?) {
    let facts = NSApp.windows.filter { $0 !== closing }.map {
      WindowFacts(isVisible: $0.isVisible, isTitled: $0.styleMask.contains(.titled), canBecomeMain: $0.canBecomeMain)
    }
    let wanted = Self.policy(for: facts)
    guard NSApp.activationPolicy() != wanted else { return }
    NSApp.setActivationPolicy(wanted)
    if wanted == .regular { NSApp.activate() }
  }
}
