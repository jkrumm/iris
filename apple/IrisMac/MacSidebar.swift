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
        row(
          .favorites, String(localized: "Favorites", comment: "Sidebar item"), "star",
          badge: MacFavoritesCount.text(memos: root.history.memos, hasMore: root.history.hasMorePages))
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

  private func row(_ scope: MacLibraryScope, _ title: String, _ systemImage: String, badge: String? = nil) -> some View
  {
    Label {
      HStack {
        Text(verbatim: title).macFont(.body)
        if let badge {
          Spacer(minLength: 0)
          Text(verbatim: badge)
            .macFont(.caption)
            .foregroundStyle(Theme.Ink.muted)
            .monospacedDigit()
            .accessibilityIdentifier("mac.sidebar.favorites.count")
        }
      }
    } icon: {
      Image(systemName: systemImage)
    }
    .tag(scope)
    .accessibilityIdentifier("mac.sidebar.\(String(describing: scope))")
  }

  /// The link to the server, as in the popover's foot; absent while the link is fine.
  @ViewBuilder private var footer: some View {
    let status = MacConnectionStatus(isConfigured: root.isConfigured, link: root.history.link)
    if status.isShown { statusLine(status) }
  }

  private func statusLine(_ status: MacConnectionStatus) -> some View {
    HStack(spacing: Theme.Spacing.snug) {
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

/// The number beside Favorites: the favorites among the popover's unfiltered list (the newest 50 memos the app always holds, kept
/// current by the event stream), so no route is added. A longer list than was loaded shows "n+".
enum MacFavoritesCount {
  static func text(memos: [Memo], hasMore: Bool) -> String? {
    let count = memos.count { $0.favorite }
    guard count > 0 else { return nil }
    return hasMore ? "\(count)+" : "\(count)"
  }
}
