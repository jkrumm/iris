import IrisCore
import IrisUI
import SwiftUI

/// The typed-memo composer as a sheet: mode chips, the text field, Send. `onSent` gets the created memo before the
/// sheet closes, so History can show it at once; `onQueued` says the memo waits in the outbox instead.
struct ComposerView: View {
  @State private var model: ComposerModel
  private let onSent: (Memo) -> Void
  private let onQueued: () -> Void
  @Environment(\.dismiss) private var dismiss

  init(model: ComposerModel, onSent: @escaping (Memo) -> Void, onQueued: @escaping () -> Void = {}) {
    _model = State(initialValue: model)
    self.onSent = onSent
    self.onQueued = onQueued
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        if model.threadId == nil {
          ChoiceChips(choices: Self.choices, selection: $model.mode)
            .disabled(model.isSending)
            .accessibilityIdentifier("composer.modes")
        }
        ComposerField(
          text: $model.text,
          placeholder: String(localized: "What should Iris do?", comment: "Composer placeholder"),
          counter: counter, isOverLimit: model.isOverLimit)
        hint
        if let failure = model.failure {
          Text(verbatim: failure)
            .themeFont(.footnote)
            .foregroundStyle(Theme.Status.bad)
            .accessibilityIdentifier("composer.error")
        }
        Spacer(minLength: 0)
      }
      .padding(Theme.Spacing.lg)
      .background(Theme.Surface.background)
      .navigationTitle(
        model.threadId == nil
          ? String(localized: "New memo", comment: "Composer title")
          : String(localized: "Reply", comment: "Composer title when continuing a thread")
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "Cancel", comment: "Closes the composer")) { dismiss() }
            .disabled(!model.canCancel)
            .accessibilityIdentifier("composer.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(String(localized: "Send", comment: "Sends the typed memo"), systemImage: "arrow.up") {
            Task { await send() }
          }
          .disabled(!model.canSend)
          .accessibilityIdentifier("composer.send")
        }
      }
      .interactiveDismissDisabled(model.isSending)
    }
  }

  private static let choices = ComposerModel.modes.map { mode in
    ChipChoice(id: mode, title: mode.composerTitle, systemImage: mode.composerIcon)
  }

  private var counter: String {
    let count = model.characterCount.formatted()
    guard model.isOverLimit else { return String(localized: "\(count) characters", comment: "Composer counter") }
    let limit = CreateTextMemoRequest.maxTextCharacters.formatted()
    return String(localized: "\(count) of \(limit) characters", comment: "Composer counter past the limit")
  }

  private var hint: some View {
    Label {
      Text(
        model.threadId == nil
          ? "Typed memos take the same route as spoken ones: same history, same result."
          : "Continues this conversation.", comment: "Composer hint")
    } icon: {
      Image(systemName: model.threadId == nil ? "mic" : "bubble.left.and.bubble.right")
        .foregroundStyle(Theme.Accent.tint)
    }
    .themeFont(.footnote)
    .foregroundStyle(Theme.Ink.secondary)
    .padding(Theme.Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .detailCard()
  }

  private func send() async {
    guard let outcome = await model.send() else { return }
    switch outcome {
    case .sent(let memo): onSent(memo)
    case .queued: onQueued()
    case .refused, .stalled: return
    }
    dismiss()
  }
}

extension MemoMode {
  var composerTitle: String {
    switch self {
    case .auto, .unknown: String(localized: "Auto", comment: "Memo mode")
    case .journal: String(localized: "Journal", comment: "Memo mode")
    case .hermes: String(localized: "Hermes", comment: "Memo mode")
    case .tab: String(localized: "Tab", comment: "Memo mode")
    case .chat: String(localized: "Chat", comment: "Memo mode")
    }
  }

  fileprivate var composerIcon: String? {
    switch self {
    case .auto, .unknown: "sparkles"
    case .tab: "terminal"
    default: nil
    }
  }
}
