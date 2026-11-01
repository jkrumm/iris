import IrisUI
import SwiftUI

/// The menu-bar popover: a header with the connection state and the History / Settings switch, and the page under it.
struct MacMenuPanel: View {
  @Bindable var root: MacCompositionRoot

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      MacOutboxStrip(model: root.outbox)
      switch root.page {
      case .history: MacHistoryList(root: root, model: root.history)
      case .settings: MacSettingsView(model: root.connectionForm, hotkey: root.hotkey)
      }
    }
    .frame(width: 460, height: 560)
    .background(Theme.Surface.background)
    .accessibilityIdentifier("mac.panel")
  }

  private var header: some View {
    let status = MacConnectionStatus(isConfigured: root.isConfigured, link: root.history.link)
    return HStack(spacing: Theme.Spacing.sm) {
      Text(String(localized: "Iris", comment: "Menu bar panel title"))
        .themeFont(.body, weight: .semibold)
        .foregroundStyle(Theme.Ink.primary)
      Circle()
        .fill(color(status.tone))
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(verbatim: status.title)
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.muted)
        .help(status.hint ?? "")
        .accessibilityIdentifier("mac.status")
      Spacer()
      Picker(String(localized: "Page", comment: "Switches the panel page"), selection: $root.page) {
        Image(systemName: "clock").tag(MacPanelPage.history)
          .accessibilityLabel(String(localized: "History", comment: "Panel page"))
        Image(systemName: "gearshape").tag(MacPanelPage.settings)
          .accessibilityLabel(String(localized: "Settings", comment: "Panel page"))
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 84)
      .accessibilityIdentifier("mac.page")
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.vertical, Theme.Spacing.md)
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
