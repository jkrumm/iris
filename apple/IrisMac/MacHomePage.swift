import AppKit
import IrisCore
import IrisUI
import SwiftUI

/// The popover's home (`mac.html` `.menu`): the title with the Hermes and Transcribe buttons, the quick-ask line (focused when the
/// popover opens; its answer streams in below it), the newest memos, the menu lines and the connection line.
struct MacHomePage: View {
  let root: MacCompositionRoot
  /// The mockup shows four rows; the newest five fit a popover.
  private static let recentCount = 5
  /// The symbol of the Hermes button.
  private static let hermesSymbol = "sparkles"

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.menuGap) {
      header
      if root.isConfigured { MacQuickAsk(root: root) }
      MacOutboxStrip(model: root.outbox)
      if root.quickAnswer == nil { recent }
      MacMenuDivider()
      MacMenuLine(
        title: String(localized: "New memo…", comment: "Menu line: opens the main window on the New memo page"),
        id: "mac.menu.new",
        hint: "⌘N"  // l10n:ignore key hint
      ) { root.newMemo() }
      .keyboardShortcut("n")
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

/// The popover's quick-ask line: Return sends the text to Hermes as a new memo, and the answer streams in under the line (the
/// tools Hermes uses, then the text) until it is dismissed or opened in the window to continue. While an answer shows, the newest
/// memos make room for it.
private struct MacQuickAsk: View {
  let root: MacCompositionRoot
  @FocusState private var focused: Bool

  var body: some View {
    let composer = root.quickAskComposer
    VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
      HStack(alignment: .bottom, spacing: Theme.Spacing.macComposerGap) {
        MacPromptField(
          model: composer,
          placeholder: String(localized: "Ask Hermes…", comment: "Popover quick-ask placeholder"),
          isEnabled: true, identifier: "mac.menu.ask.field", leavesOnEscape: false, focus: $focused
        ) {
          send(composer)
        }
        Button {
          send(composer)
        } label: {
          Image(systemName: "arrow.up")
            .fontWeight(.semibold)
            .foregroundStyle(composer.canSend ? Theme.Accent.onFill : Theme.Ink.muted)
            .frame(width: Theme.Spacing.macComposerButtonSize, height: Theme.Spacing.macComposerButtonSize)
            .background(composer.canSend ? Theme.Accent.fill : Theme.Surface.elevated, in: .circle)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!composer.canSend)
        .accessibilityLabel(Text("Send to Hermes", comment: "Composer: sends the text to Hermes"))
        .accessibilityIdentifier("mac.menu.ask.send")
      }
      if let failure = composer.failure {
        Text(verbatim: failure)
          .themeFont(.caption)
          .foregroundStyle(Theme.Status.bad)
          .accessibilityIdentifier("mac.menu.ask.error")
      }
      if root.queuedNote == ObjectIdentifier(composer) {
        Text(
          "Queued. It is sent as soon as the server answers.",
          comment: "Note under the composer after a memo went to the outbox"
        )
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.muted)
        .accessibilityIdentifier("mac.menu.ask.queued")
      }
      if let answer = root.quickAnswer {
        MacQuickAnswer(root: root, answer: answer)
      }
    }
    .padding(.horizontal, Theme.Spacing.menuRowHorizontal)
    .padding(.bottom, Theme.Spacing.snug)
    // The popover keeps its content between openings, so a first appearance is not the only moment the line takes the keyboard.
    .task { focused = true }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
  }

  private func send(_ composer: ComposerModel) {
    guard composer.canSend else { return }
    Task { await root.sendTyped(composer, mode: .hermes) }
  }
}

/// The question just asked and its answer as they stream: the conversation component the window uses, over the popover's own
/// model of the memo. It reloads when the popover's list hears the memo change, which is when the stored answer replaces the stream.
private struct MacQuickAnswer: View {
  let root: MacCompositionRoot
  let answer: MacMemoDetailModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
      ScrollView {
        MacConversationView(turns: answer.turns, onCopy: { answer.copyTurn($0) }, onOpenImage: { _ in })
      }
      .frame(maxHeight: Theme.Spacing.menuAnswerMaxHeight)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(String(localized: "Open in window", comment: "Popover: continues the quick answer in the main window")) {
          root.openQuickAnswerInWindow()
        }
        .accessibilityIdentifier("mac.menu.ask.open")
        Spacer()
        Button(String(localized: "Done", comment: "Popover: dismisses the quick answer")) { root.dismissQuickAnswer() }
          .accessibilityIdentifier("mac.menu.ask.dismiss")
      }
      .buttonStyle(.plain)
      .themeFont(.footnote, weight: .semibold)
      .foregroundStyle(Theme.Accent.tint)
    }
    .task(id: root.history.revision(of: answer.memoID) + root.reconnects) { await answer.load() }
    .accessibilityIdentifier("mac.menu.ask.answer")
  }
}
