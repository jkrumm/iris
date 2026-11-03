import AppKit
import SwiftUI

@main
struct IrisMacApp: App {
  @State private var root: MacCompositionRoot

  init() {
    let root = MacCompositionRoot()
    _root = State(initialValue: root)
    root.installNotificationClicks()
    root.installHotkey()
    root.startTelemetry()
    // The list and the event stream run from launch, popover open or not: a notification per finished memo needs them.
    root.begin()
    if root.mode == .fake, let snapshot = MacSnapshotRun(arguments: ProcessInfo.processInfo.arguments, root: root) {
      Task { await snapshot.run() }
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MacMenuPanel(root: root)
    } label: {
      MenuBarLabel(root: root)
    }
    .menuBarExtraStyle(.window)

    // The memo detail: one window, reused by the next memo that is opened.
    Window(String(localized: "Memo", comment: "Window title of the memo detail"), id: MenuBarLabel.detailWindowID) {
      MacMemoDetailPanel(root: root)
    }
    .defaultSize(width: 560, height: 700)
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(.suppressed)

    // The panel as a regular window, only for screenshots: a menu-bar popover cannot be opened without a click.
    Window(String(localized: "Iris panel", comment: "Window title of the verification panel"), id: "panel") {
      MacMenuPanel(root: root)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(
      ProcessInfo.processInfo.arguments.contains(MacCompositionRoot.panelWindowArgument) ? .presented : .suppressed)
  }
}

/// The menu-bar icon. It is the one view that always exists, so it opens the detail window when a row or a clicked
/// notification asks for a memo.
private struct MenuBarLabel: View {
  static let detailWindowID = "memo"
  let root: MacCompositionRoot
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

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
      .onChange(of: root.detailRequest) {
        openWindow(id: Self.detailWindowID)
        NSApp.activate()
      }
      .onChange(of: root.detailDismissals) { dismissWindow(id: Self.detailWindowID) }
  }
}
