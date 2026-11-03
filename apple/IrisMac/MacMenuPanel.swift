import IrisUI
import SwiftUI

/// The menu-bar popover (`mac.html`, variant `menu`): the home page, and History and Settings as pages inside it with a back
/// chevron. Every page is ``Theme/Spacing/menuWidth`` wide; the home page is as tall as its content.
struct MacMenuPanel: View {
  @Bindable var root: MacCompositionRoot

  var body: some View {
    Group {
      switch root.page {
      case .home: MacHomePage(root: root)
      case .history: MacHistoryPage(root: root, model: root.history)
      case .settings: MacSettingsView(root: root, model: root.connectionForm, hotkey: root.hotkey)
      }
    }
    .frame(width: Theme.Spacing.menuWidth)
    .background(Theme.Surface.background)
    .overlay(alignment: .bottom) { toastBanner }
    // On every page: a delete from the home page's context menu has its undo here too.
    .task(id: root.history.toast?.id) {
      guard let id = root.history.toast?.id, (try? await Task.sleep(for: .seconds(5))) != nil else { return }
      root.history.dismissToast(id: id)
    }
    .accessibilityIdentifier("mac.panel")
  }
}

extension MacMenuPanel {
  @ViewBuilder fileprivate var toastBanner: some View {
    if let toast = root.history.toast {
      ToastBanner(
        message: toast.message,
        actionTitle: toast.kind.isUndo ? String(localized: "Undo", comment: "Undoes a delete") : nil,
        action: { root.perform(on: root.history) { await $0.undoDelete() } }
      )
      .padding(Theme.Spacing.sm)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .accessibilityIdentifier("mac.history.toast")
    }
  }
}

/// The header of History and Settings: a back chevron to the home page and the page title.
struct MacPageHeader: View {
  let title: String
  let back: () -> Void

  var body: some View {
    HStack(spacing: Theme.Spacing.snug) {
      Button(action: back) {
        Image(systemName: "chevron.left")
          .themeFont(.footnote, weight: .semibold)
          .foregroundStyle(Theme.Accent.tint)
          .frame(width: Theme.Spacing.xl, height: Theme.Spacing.xl)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .accessibilityLabel(String(localized: "Back", comment: "Returns to the panel's home page"))
      .accessibilityIdentifier("mac.back")
      Text(verbatim: title)
        .themeFont(.callout, weight: .semibold)
        .foregroundStyle(Theme.Ink.primary)
      Spacer(minLength: 0)
    }
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
