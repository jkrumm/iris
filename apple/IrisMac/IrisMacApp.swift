import AppKit
import IrisUI
import SwiftUI

/// A Dock click on the running app: SwiftUI has no hook for it, AppKit sends it to the delegate.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  /// Set once by ``IrisMacApp``; returns whether it handled the reopen.
  @MainActor static var onReopen: (() -> Void)?

  @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard let onReopen = Self.onReopen else { return true }
    onReopen()
    return false
  }
}

@main
struct IrisMacApp: App {
  @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
  @State private var root: MacCompositionRoot
  /// ⌘Tab and the Dock while a real window is open.
  private let activation = MacActivationPolicy()

  init() {
    // Sparkle only on a real launch: fake runs (screenshots, tests) get no updater, no network, no window.
    let isFake = ProcessInfo.processInfo.arguments.contains(MacCompositionRoot.fakeDataArgument)
    let root = MacCompositionRoot(updateEngine: isFake ? nil : SparkleUpdateEngine())
    _root = State(initialValue: root)
    root.installNotificationClicks()
    root.installHotkey()
    root.installLaunchDetection()
    root.startTelemetry()
    // The list and the event stream run from launch, popover open or not: a notification per finished memo needs them.
    root.begin()
    activation.install()
    MacAppDelegate.onReopen = { [root] in
      let windows = NSApp.windows
      switch MacActivationPolicy.reopenAction(
        hasVisibleWindow: MacActivationPolicy.hasVisibleWindow(windows), needsOnboarding: root.needsOnboarding)
      {
      case .bringToFront:
        root.noteWindow("main", "front", source: "dock")
        NSApp.activate()
        windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
      case .openOnboarding: root.showOnboarding(source: "dock")
      case .openMain: root.showMainWindow(source: "dock")
      }
    }
    // The screenshot proof exists in Debug builds only (it reaches for a private window capture), and only on the fake composition.
    #if DEBUG
      if root.mode == .fake, let snapshot = MacSnapshotRun(arguments: ProcessInfo.processInfo.arguments, root: root) {
        Task { await snapshot.run() }
      }
    #endif
  }

  var body: some Scene {
    MenuBarExtra {
      MacMenuPanel(root: root)
    } label: {
      MenuBarLabel(root: root)
    }
    .menuBarExtraStyle(.window)

    // The main window: sidebar, memo list and the selected memo. Opened by the popover, a clicked banner and onboarding.
    Window(String(localized: "Iris", comment: "Main window title"), id: MacWindowID.main) {
      MacMainWindow(root: root)
    }
    .defaultSize(width: Theme.Spacing.windowWidth, height: Theme.Spacing.windowHeight)
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(.suppressed)

    // First launch with nothing saved, and the popover's connect prompt.
    Window(String(localized: "Welcome to Iris", comment: "Onboarding window title"), id: MacWindowID.onboarding) {
      MacOnboardingView(root: root, model: root.connectionForm, tester: root.connectionTest)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)

    // A reply's chart, table or document at reading size: one window per artifact, opened by a card's Open.
    WindowGroup(
      String(localized: "Document", comment: "Window title of an opened reply artifact"), id: MacWindowID.artifact,
      for: ArtifactViewerRequest.self
    ) { $request in
      if let request {
        ArtifactViewer(request: request)
          .navigationTitle(
            request.asset.title
              ?? String(localized: "Document", comment: "Window title of an opened reply artifact")
          )
          .environment(\.artifactStore, root.artifacts)
      }
    }
    .defaultSize(width: 640, height: 520)
    .defaultLaunchBehavior(.suppressed)

    // ⌘, : the native tabbed Settings window.
    Settings {
      MacSettingsView(root: root)
    }

    // The panel as a regular window, only for screenshots: a menu-bar popover cannot be opened without a click.
    Window(String(localized: "Iris panel", comment: "Window title of the verification panel"), id: "panel") {
      MacMenuPanel(root: root)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(
      ProcessInfo.processInfo.arguments.contains(MacCompositionRoot.panelWindowArgument) ? .presented : .suppressed)
  }
}

/// The menu-bar icon. It is the one view that always exists, so it opens the windows when the popover, a clicked notification
/// or the onboarding asks for one, and the onboarding window at launch while nothing is saved.
private struct MenuBarLabel: View {
  let root: MacCompositionRoot
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  /// The waveform; while a take runs, white on a red rounded square (`.extra.rec` in the mockup). A coloured image, not a
  /// template, because the menu bar tints templates itself.
  @ViewBuilder private var icon: some View {
    if root.recording.isRecording {
      Image(nsImage: Self.recordingIcon)
    } else {
      Image(systemName: "waveform")
    }
  }

  private static let recordingIcon: NSImage = {
    let size = NSSize(width: 26, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
      NSColor.systemRed.setFill()
      NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
      let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.white])))
      guard let symbol else { return true }
      let origin = NSPoint(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2)
      symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
      return true
    }
    image.isTemplate = false
    return image
  }()

  var body: some View {
    icon
      .accessibilityLabel(String(localized: "Iris", comment: "Menu bar item title"))
      .task {
        guard root.needsOnboarding else { return }
        root.showOnboarding(source: "launch")
      }
      // A launch by the user opens the window (a launch at login stays in the menu bar); `initial` catches a decision made before this view existed.
      .onChange(of: root.launchWindowPending, initial: true) {
        if root.takeLaunchWindow() { open(MacWindowID.main) }
      }
      .onChange(of: root.windowRequest) { open(MacWindowID.main) }
      .onChange(of: root.onboardingRequest) { open(MacWindowID.onboarding) }
      .onChange(of: root.settingsRequest) {
        // An accessory app has no active window to host the scene: activate first.
        NSApp.activate()
        openSettings()
      }
  }

  private func open(_ id: String) {
    openWindow(id: id)
    NSApp.activate()
  }
}
