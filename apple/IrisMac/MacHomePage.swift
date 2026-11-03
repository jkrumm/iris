import IrisCore
import IrisUI
import SwiftUI

/// The popover's home (`mac.html` `.menu`): the title with the Record button, the newest memos, the two menu lines and the
/// connection line.
struct MacHomePage: View {
  let root: MacCompositionRoot
  /// The mockup shows four rows; the newest five fit a popover.
  private static let recentCount = 5

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.menuGap) {
      header
      MacOutboxStrip(model: root.outbox)
      recent
      MacMenuDivider()
      MacMenuLine(
        title: String(localized: "Open history", comment: "Menu line: opens the history page"),
        id: "mac.menu.history",
        hint: "⌘H"  // l10n:ignore key hint
      ) { root.page = .history }
      .keyboardShortcut("h")
      MacMenuLine(
        title: String(localized: "Settings…", comment: "Menu line: opens the settings page"),
        id: "mac.menu.settings",
        hint: "⌘,"  // l10n:ignore key hint
      ) { root.page = .settings }
      .keyboardShortcut(",")
      MacConnectionLine(root: root)
    }
    .padding(Theme.Spacing.menuInset)
    .accessibilityIdentifier("mac.home")
  }

  private var header: some View {
    HStack {
      Text(String(localized: "Iris", comment: "Menu bar panel title"))
        .themeFont(.callout, weight: .semibold)
        .foregroundStyle(Theme.Ink.primary)
      Spacer()
      recordButton
    }
    .padding(.top, Theme.Spacing.menuHeaderTop)
    .padding(.bottom, Theme.Spacing.menuHeaderBottom)
    .padding(.horizontal, Theme.Spacing.menuHeaderSide)
  }

  /// Toggles a take like the global key does.
  private var recordButton: some View {
    Button {
      root.recording.toggle()
    } label: {
      HStack(spacing: Theme.Spacing.xs) {
        Image(systemName: root.recording.isRecording ? "stop.fill" : "mic")
        Text(
          root.recording.isRecording
            ? String(localized: "Stop", comment: "Stops the take")
            : String(localized: "Record", comment: "Starts a take from the menu-bar panel")
        )
        if !root.recording.isRecording, let shortcut = root.hotkey.shortcutDescription {
          Text(verbatim: shortcut).fontWeight(.medium).opacity(0.7)
        }
      }
      .themeFont(.footnote, weight: .semibold)
      .foregroundStyle(Theme.Accent.tint)
      .padding(.horizontal, Theme.Spacing.menuButtonHorizontal)
      .padding(.vertical, Theme.Spacing.menuButtonVertical)
      .background(Theme.Accent.tint.opacity(0.18), in: .capsule)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("mac.record")
  }

  @ViewBuilder private var recent: some View {
    if !root.isConfigured {
      VStack(spacing: Theme.Spacing.sm) {
        Text("Add your server URL and device token to see your memos.", comment: "History prompt without a connection")
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
          .multilineTextAlignment(.center)
        Button(String(localized: "Open Settings", comment: "Opens Settings → Connection")) { root.page = .settings }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("mac.history.connect")
      }
      .frame(maxWidth: .infinity)
      .padding(Theme.Spacing.menuInset)
    } else {
      let memos = root.history.memos.prefix(Self.recentCount)
      if memos.isEmpty {
        Text(
          root.history.loadFailed
            ? String(localized: "Could not load memos", comment: "History error title")
            : String(localized: "No memos", comment: "History empty title")
        )
        .themeFont(.footnote)
        .foregroundStyle(Theme.Ink.faint)
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.menuInset)
      }
      ForEach(memos) { memo in
        MacMemoRow(root: root, model: root.history, memo: memo)
      }
    }
  }
}

/// A line of the menu (`.menu .ln`): the title, its shortcut hint right in faint text, a hover highlight.
struct MacMenuLine: View {
  let title: String
  let id: String
  let hint: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack {
        Text(verbatim: title).themeFont(.footnote).foregroundStyle(Theme.Ink.primary)
        Spacer()
        Text(verbatim: hint).themeFont(.caption).foregroundStyle(Theme.Ink.faint)
      }
      .padding(.horizontal, Theme.Spacing.menuRowHorizontal)
      .padding(.vertical, Theme.Spacing.menuLineVertical)
      .background(hovering ? Theme.Surface.subtle : .clear, in: .rect(cornerRadius: Theme.Spacing.menuLineRadius))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityIdentifier(id)
  }
}
