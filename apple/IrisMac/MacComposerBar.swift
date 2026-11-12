import IrisCore
import IrisUI
import SwiftUI

/// The bar pinned to the foot of the detail column where the owner types: a field that grows from one line to eight, a Send
/// button, and a microphone that starts a Hermes take (in a conversation, a take that continues it). Return sends, Shift-Return
/// starts a new line at the caret, Command-Return always sends, Command-L focuses the field and Escape leaves it. A conversation
/// opens with the field focused. A new memo can go to Hermes or be only transcribed (the send is a menu); a reply into a conversation
/// goes to Hermes. What the outbox says (a refusal, "queued") and the length near the server's limit show above the field.
struct MacComposerBar: View {
  let root: MacCompositionRoot
  @Bindable var model: ComposerModel
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
      notes
      HStack(alignment: .bottom, spacing: Theme.Spacing.macComposerGap) {
        microphone
        field
        send
      }
    }
    .frame(maxWidth: Theme.Spacing.macReadableWidth)
    .padding(.horizontal, Theme.Spacing.macDetailMargin)
    .padding(.vertical, Theme.Spacing.macComposerInsetVertical)
    .frame(maxWidth: .infinity)
    .background(Theme.Surface.background)
    .overlay(alignment: .top) { Divider().overlay(Theme.Surface.hairline) }
    .task { focused = true }
    .background {
      // Command-L: the keyboard goes to the field from anywhere in the window.
      Button(action: { focused = true }) { Color.clear }
        .keyboardShortcut("l")
        .opacity(0)
        .accessibilityHidden(true)
    }
    .accessibilityIdentifier("mac.composer")
  }

  // MARK: Field

  private var placeholder: String {
    guard root.isConfigured else {
      return String(localized: "Connect Iris in Settings first.", comment: "Composer placeholder without a connection")
    }
    return model.threadId == nil
      ? String(localized: "What should Iris do?", comment: "Composer placeholder")
      : String(localized: "Reply to Hermes…", comment: "Composer placeholder when continuing a conversation")
  }

  private var field: some View {
    MacPromptField(
      model: model, placeholder: placeholder, isEnabled: root.isConfigured, identifier: "mac.composer.field",
      leavesOnEscape: true, focus: $focused
    ) {
      submit(.hermes)
    }
  }

  // MARK: Buttons

  private var microphone: some View {
    Button {
      root.talk(in: model.threadId)
    } label: {
      Image(systemName: "mic")
        .foregroundStyle(Theme.Accent.tint)
        .frame(width: Theme.Spacing.macComposerButtonSize, height: Theme.Spacing.macComposerButtonSize)
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .disabled(!root.isConfigured)
    .help(
      model.threadId == nil
        ? String(localized: "Talk to Hermes", comment: "Composer: starts a voice memo for Hermes")
        : String(localized: "Reply by voice", comment: "Composer: records a spoken reply in the conversation")
    )
    .accessibilityLabel(
      model.threadId == nil
        ? Text("Talk to Hermes", comment: "Composer: starts a voice memo for Hermes")
        : Text("Reply by voice", comment: "Composer: records a spoken reply in the conversation")
    )
    .accessibilityIdentifier("mac.composer.mic")
  }

  /// A new memo offers Transcribe only beside Hermes (the send is a menu); a reply goes to Hermes.
  @ViewBuilder private var send: some View {
    Group {
      if model.offersTranscribe {
        Menu {
          Button(String(localized: "Send to Hermes", comment: "Composer: sends the text to Hermes")) {
            submit(.hermes)
          }
          Button(
            String(localized: "Transcribe only", comment: "Composer: sends the text as a memo that is only transcribed")
          ) {
            submit(.transcribe)
          }
          .accessibilityIdentifier("mac.composer.transcribe")
        } label: {
          sendFace
        } primaryAction: {
          submit(.hermes)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
      } else {
        Button {
          submit(.hermes)
        } label: {
          sendFace
        }
        .buttonStyle(.plain)
      }
    }
    .disabled(!model.canSend || !root.isConfigured)
    .help(String(localized: "Send to Hermes", comment: "Composer: sends the text to Hermes"))
    .accessibilityLabel(Text("Send to Hermes", comment: "Composer: sends the text to Hermes"))
    .accessibilityIdentifier("mac.composer.send")
    .background {
      // The guaranteed key: a multi-line field may keep Return for itself.
      Button(action: { if model.canSend { submit(.hermes) } }) { Color.clear }
        .keyboardShortcut(.return, modifiers: .command)
        .opacity(0)
        .accessibilityHidden(true)
    }
  }

  private var sendFace: some View {
    let ready = model.canSend && root.isConfigured
    return Group {
      if model.isSending {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: "arrow.up").fontWeight(.semibold)
      }
    }
    .foregroundStyle(ready ? Theme.Accent.onFill : Theme.Ink.muted)
    .frame(width: Theme.Spacing.macComposerButtonSize, height: Theme.Spacing.macComposerButtonSize)
    .background(ready ? Theme.Accent.fill : Theme.Surface.elevated, in: .circle)
    .contentShape(.circle)
  }

  private func submit(_ mode: MemoMode) {
    Task { await root.sendTyped(model, mode: mode) }
  }

  // MARK: Notes

  @ViewBuilder private var notes: some View {
    if let failure = model.failure {
      Text(verbatim: failure)
        .macFont(.caption)
        .foregroundStyle(Theme.Status.bad)
        .accessibilityIdentifier("mac.composer.error")
    }
    if root.queuedNote == ObjectIdentifier(model) {
      Text(
        "Queued. It is sent as soon as the server answers.",
        comment: "Note under the composer after a memo went to the outbox"
      )
      .macFont(.caption)
      .foregroundStyle(Theme.Ink.muted)
      .accessibilityIdentifier("mac.composer.queued")
    }
    if showsCounter {
      Text(verbatim: counter)
        .macFont(.caption)
        .foregroundStyle(model.isOverLimit ? Theme.Status.bad : Theme.Ink.muted)
        .accessibilityIdentifier("mac.composer.counter")
    }
  }

  /// The length shows once it nears the server's limit (80 %), and in red past it.
  private var showsCounter: Bool {
    model.characterCount * 5 > CreateTextMemoRequest.maxTextCharacters * 4
  }

  private var counter: String {
    let count = model.characterCount
    let limit = CreateTextMemoRequest.maxTextCharacters
    return String(localized: "\(count) of \(limit) characters", comment: "Composer counter near the limit")
  }
}
