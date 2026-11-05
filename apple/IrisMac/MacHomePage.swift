import AppKit
import IrisCore
import IrisUI
import SwiftUI

/// The popover's home (`mac.html` `.menu`): the title with the Hermes and Transcribe buttons, the newest memos, the two menu lines and the
/// connection line.
struct MacHomePage: View {
  let root: MacCompositionRoot
  /// The mockup shows four rows; the newest five fit a popover.
  private static let recentCount = 5
  /// The symbol of the Hermes button.
  private static let hermesSymbol = "sparkles"

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.menuGap) {
      header
      MacOutboxStrip(model: root.outbox)
      recent
      MacMenuDivider()
      MacMenuLine(
        title: String(localized: "Open Iris", comment: "Menu line: opens the main window"),
        id: "mac.menu.open",
        hint: "⌘O"  // l10n:ignore key hint
      ) { root.showMainWindow() }
      .keyboardShortcut("o")
      MacMenuLine(
        title: String(localized: "Settings…", comment: "Menu line: opens the settings window"),
        id: "mac.menu.settings",
        hint: "⌘,"  // l10n:ignore key hint
      ) { root.showSettings() }
      .keyboardShortcut(",")
      // Absent under `-IrisFakeData` (the root has no updater): snapshots and tests never show it.
      if let updater = root.updater {
        MacMenuLine(
          title: String(localized: "Check for Updates…", comment: "Menu line: looks for a new version of Iris"),
          id: "mac.menu.update",
          hint: ""
        ) { updater.checkForUpdates() }
        .disabled(!updater.canCheckForUpdates)
      }
      MacMenuLine(
        title: String(localized: "Quit Iris", comment: "Quits the menu-bar app"),
        id: "mac.menu.quit",
        hint: "⌘Q"  // l10n:ignore key hint
      ) { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
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
      takeButtons
    }
    .padding(.top, Theme.Spacing.menuHeaderTop)
    .padding(.bottom, Theme.Spacing.menuHeaderBottom)
    .padding(.horizontal, Theme.Spacing.menuHeaderSide)
  }

  /// Hermes (primary, with the global key's shortcut) and Transcribe start a take in their mode; while a take runs one Stop
  /// button ends it, whichever mode it is in.
  @ViewBuilder private var takeButtons: some View {
    if root.recording.isRecording {
      Button {
        root.recording.toggle(mode: .hermes)
      } label: {
        HStack(spacing: Theme.Spacing.xs) {
          Image(systemName: "stop.fill")
          Text(String(localized: "Stop", comment: "Stops the take"))
        }
        .modifier(TakeButtonStyle(prominent: true))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("mac.record")
    } else {
      HStack(spacing: Theme.Spacing.xs) {
        Button {
          root.recording.toggle(mode: .transcribe)
        } label: {
          HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "text.alignleft")
            Text(String(localized: "Transcribe", comment: "Starts a transcript-only take from the menu-bar panel"))
          }
          .modifier(TakeButtonStyle(prominent: false))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mac.record.transcribe")
        Button {
          root.recording.toggle(mode: .hermes)
        } label: {
          HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: Self.hermesSymbol)
            Text(String(localized: "Hermes", comment: "Starts a take Hermes acts on, from the menu-bar panel"))
            if let shortcut = root.hotkey.shortcutDescription {
              Text(verbatim: shortcut).fontWeight(.medium).opacity(0.7)
            }
          }
          .modifier(TakeButtonStyle(prominent: true))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mac.record")
      }
    }
  }

  @ViewBuilder private var recent: some View {
    if !root.isConfigured {
      VStack(spacing: Theme.Spacing.sm) {
        Text("Add your server URL and device token to see your memos.", comment: "History prompt without a connection")
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
          .multilineTextAlignment(.center)
        Button(String(localized: "Set Up Iris", comment: "Opens the onboarding window")) { root.showOnboarding() }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("mac.menu.connect")
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

/// A capsule button face of the popover's header: the accent one is the primary take, the muted one the secondary.
private struct TakeButtonStyle: ViewModifier {
  let prominent: Bool

  func body(content: Content) -> some View {
    let color = prominent ? Theme.Accent.tint : Theme.Ink.secondary
    content
      .themeFont(.footnote, weight: .semibold)
      .foregroundStyle(color)
      .padding(.horizontal, Theme.Spacing.menuButtonHorizontal)
      .padding(.vertical, Theme.Spacing.menuButtonVertical)
      .background(color.opacity(prominent ? 0.18 : 0.12), in: .capsule)
      .contentShape(.capsule)
  }
}
