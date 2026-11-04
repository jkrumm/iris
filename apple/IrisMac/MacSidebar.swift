import IrisCore
import IrisUI
import SwiftUI

/// The main window's sidebar: the library (everything, favorites, the archive) and the conversations (threads). A selection narrows
/// the list column through the root's scope.
struct MacSidebar: View {
  @Bindable var root: MacCompositionRoot

  var body: some View {
    List(selection: $root.scope) {
      Section(String(localized: "Library", comment: "Sidebar section")) {
        row(.all, String(localized: "All memos", comment: "Sidebar item"), "tray.full")
        row(.favorites, String(localized: "Favorites", comment: "Sidebar item"), "star")
        row(.archive, String(localized: "Archive", comment: "Sidebar item"), "archivebox")
      }
      Section(String(localized: "Conversations", comment: "Sidebar section")) {
        row(.threads, String(localized: "Threads", comment: "Sidebar item"), "bubble.left.and.bubble.right")
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    .accessibilityIdentifier("mac.sidebar")
  }

  private func row(_ scope: MacLibraryScope, _ title: String, _ systemImage: String) -> some View {
    Label {
      Text(verbatim: title).macFont(.body)
    } icon: {
      Image(systemName: systemImage)
    }
    .tag(scope)
    .accessibilityIdentifier("mac.sidebar.\(String(describing: scope))")
  }

  /// The link to the server, as in the popover's foot.
  private var footer: some View {
    let status = MacConnectionStatus(isConfigured: root.isConfigured, link: root.history.link)
    return HStack(spacing: Theme.Spacing.snug) {
      Circle()
        .fill(status.tone.color)
        .frame(width: Theme.Spacing.macDot, height: Theme.Spacing.macDot)
        .accessibilityHidden(true)
      Text(verbatim: status.title)
        .macFont(.caption)
        .foregroundStyle(Theme.Ink.muted)
        .help(status.hint ?? "")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Spacing.cozy)
    .padding(.vertical, Theme.Spacing.sm)
    .accessibilityIdentifier("mac.sidebar.status")
  }
}

extension MacConnectionStatus.Tone {
  var color: Color {
    switch self {
    case .good: Theme.Status.good
    case .warn: Theme.Status.warn
    case .bad: Theme.Status.bad
    case .muted: Theme.Ink.faint
    }
  }
}
