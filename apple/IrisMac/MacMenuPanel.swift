import IrisUI
import SwiftUI

/// The menu-bar popover (`mac.html`, variant `menu`): the quick-access surface. Record, the newest memos, Open Iris, Settings, Quit and
/// the connection line. History and Settings are the main window and the Settings scene. It is ``Theme/Spacing/menuWidth`` wide and as
/// tall as its content.
struct MacMenuPanel: View {
  @Bindable var root: MacCompositionRoot
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    MacHomePage(root: root)
      .frame(width: Theme.Spacing.menuWidth)
      // The quick answer is the window's conversation component: its diagrams and documents load the same way.
      .environment(\.replyImageStore, root.replyImages)
      .environment(\.artifactStore, root.artifacts)
      .environment(\.openArtifact, OpenArtifactAction { openWindow(id: MacWindowID.artifact, value: $0) })
      .background(Theme.Surface.background)
      // A delete from a row's context menu has its undo here.
      .macToast(root: root, model: root.history)
      .accessibilityIdentifier("mac.panel")
  }
}

/// The popover's divider line (`.menu hr`).
struct MacMenuDivider: View {
  var body: some View {
    Theme.divider
      .frame(height: 0.5)
      .padding(Theme.Spacing.menuDivider)
  }
}

/// The connection line at the foot of the popover (`.menu .st`): a status dot and what the link says.
struct MacConnectionLine: View {
  let root: MacCompositionRoot

  var body: some View {
    let status = MacConnectionStatus(isConfigured: root.isConfigured, link: root.history.link)
    HStack(spacing: Theme.Spacing.snug) {
      Circle()
        .fill(color(status.tone))
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(verbatim: status.title)
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.faint)
        .help(status.hint ?? "")
        .accessibilityIdentifier("mac.status")
    }
    .padding(.horizontal, Theme.Spacing.menuRowHorizontal)
    .padding(.top, Theme.Spacing.menuFooterTop)
    .padding(.bottom, Theme.Spacing.menuFooterBottom)
  }

  private func color(_ tone: MacConnectionStatus.Tone) -> Color {
    switch tone {
    case .good: Theme.Status.good
    case .warn: Theme.Status.warn
    case .bad: Theme.Status.bad
    case .muted: Theme.Ink.faint
    }
  }
}
