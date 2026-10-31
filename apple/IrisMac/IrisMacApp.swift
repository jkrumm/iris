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

  var body: some View {
    Image(systemName: "waveform")
      .accessibilityLabel(String(localized: "Iris", comment: "Menu bar item title"))
      .onChange(of: root.detailRequest) {
        openWindow(id: Self.detailWindowID)
        NSApp.activate()
      }
      .onChange(of: root.detailDismissals) { dismissWindow(id: Self.detailWindowID) }
  }
}
