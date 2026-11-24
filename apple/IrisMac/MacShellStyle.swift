import AppKit
import IrisUI
import SwiftUI

/// The Basalt look of the main window's native lists. The platform keeps what it does better than a repaint (selection, arrow keys,
/// focus ring, the sidebar's behaviour); the surface, the row ink and the separators come from ``Theme``.
extension View {
  /// A native `List` on a ``Theme`` surface instead of the system's background, its separators in the hairline token.
  func macShellList(_ surface: Color) -> some View {
    scrollContentBackground(.hidden)
      .background(surface)
      .listRowSeparatorTint(Theme.Surface.hairline)
  }

  /// Text or an icon in a list row: `color` normally, the text-on-accent token while the row is the emphasized selection (explicit
  /// colors do not flip on the selection the way the system's semantic styles do).
  func macRowInk(_ color: Color) -> some View { modifier(MacRowInk(color: color)) }

  /// A Settings pane: a grouped form on the window surface, its grouped sections on the panel surface.
  func macSettingsPane() -> some View {
    formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .background(Theme.Surface.background)
      .foregroundStyle(Theme.Ink.primary)
      .tint(Theme.Accent.fill)
  }

  /// A section of a ``macSettingsPane`` form.
  func macSettingsRow() -> some View { listRowBackground(Theme.Surface.panel) }
}

private struct MacRowInk: ViewModifier {
  let color: Color
  @Environment(\.backgroundProminence) private var prominence

  func body(content: Content) -> some View {
    content.foregroundStyle(prominence == .increased ? Theme.Accent.onFill : color)
  }
}

/// A one-pixel separator in the hairline token (the system `Divider` draws the system's separator color).
struct MacShellDivider: View {
  var body: some View {
    Theme.Surface.hairline.frame(height: 1)
  }
}

/// A click anywhere in the main window ends a text selection: the window takes the first responder away from selectable text before
/// the click is delivered (the click then starts its own selection when it lands on text). A list, an outline or an editable field keeps
/// it, so arrow keys and typing are not lost, and the composer keeps its caret.
enum MacTextSelection {
  static func shouldResign(_ responder: NSResponder?) -> Bool {
    guard let responder, !(responder is NSWindow) else { return false }
    if responder is NSTableView || responder is NSOutlineView { return false }
    if let text = responder as? NSText, text.isEditable { return false }
    return true
  }
}

extension View {
  /// The window this view is in clears a selected text on any click that is not in a list or an editable field.
  func macClearsTextSelection() -> some View { modifier(MacClearsTextSelection()) }
}

private struct MacClearsTextSelection: ViewModifier {
  @State private var monitor = MacClickMonitor()

  func body(content: Content) -> some View {
    content
      .background(MacWindowReader { monitor.window = $0 })
      .onAppear { monitor.start() }
      .onDisappear { monitor.stop() }
  }
}

@MainActor private final class MacClickMonitor {
  weak var window: NSWindow?
  private var token: Any?

  func start() {
    guard token == nil else { return }
    token = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      MainActor.assumeIsolated { self?.handle(event) }
      return event
    }
  }

  func stop() {
    if let token { NSEvent.removeMonitor(token) }
    token = nil
  }

  private func handle(_ event: NSEvent) {
    guard let window, event.window === window, MacTextSelection.shouldResign(window.firstResponder) else { return }
    window.makeFirstResponder(nil)
  }
}

/// Reports the window its view is in (nil while it is in none).
private struct MacWindowReader: NSViewRepresentable {
  let onWindow: (NSWindow?) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = WindowView()
    view.onWindow = onWindow
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}

  private final class WindowView: NSView {
    var onWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() { onWindow?(window) }
  }
}
