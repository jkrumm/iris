import IrisUI
import SwiftUI

/// The detail column with no memo selected: a calm, empty conversation and the composer at the foot (`mac.html` variant `chat-new`).
/// What is typed here becomes a new memo, which then opens as a conversation of its own.
struct MacNewMemoPage: View {
  let root: MacCompositionRoot

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: Theme.Spacing.macEmptyGap) {
        Image(systemName: "sparkles")
          .font(.largeTitle)
          .foregroundStyle(Theme.Accent.tint)
          .accessibilityHidden(true)
        Text("What should Iris do?", comment: "Title of the New memo page")
          .macFont(.title, weight: .semibold)
          .foregroundStyle(Theme.Ink.primary)
        Text(verbatim: hint)
          .macFont(.body)
          .foregroundStyle(Theme.Ink.muted)
          .multilineTextAlignment(.center)
      }
      .padding(Theme.Spacing.macDetailMargin)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      MacComposerBar(root: root, model: root.composer(for: nil))
    }
    .background(Theme.Surface.background)
    .accessibilityIdentifier("mac.new-memo")
  }

  /// "Type here, or press the global key to talk." without the key when none is set.
  private var hint: String {
    guard let shortcut = root.hotkey.shortcutDescription else {
      return String(localized: "Type here.", comment: "New memo page: the line under the title without a global key")
    }
    return String(
      localized: "Type here, or press \(shortcut) to talk.",
      comment: "New memo page: the line under the title, the placeholder is the global key")
  }
}
