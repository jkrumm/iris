import SwiftUI

/// The multi-line field of the typed-memo composer: a panel with a placeholder, focused on appear, and a counter
/// line underneath that turns to the warning color past the limit.
public struct ComposerField: View {
  @Binding private var text: String
  @FocusState private var isFocused: Bool
  private let placeholder: String
  private let counter: String
  private let isOverLimit: Bool

  public init(text: Binding<String>, placeholder: String, counter: String, isOverLimit: Bool = false) {
    _text = text
    self.placeholder = placeholder
    self.counter = counter
    self.isOverLimit = isOverLimit
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      TextEditor(text: $text)
        .focused($isFocused)
        .scrollContentBackground(.hidden)
        .font(.system(size: 19))
        .foregroundStyle(Theme.Ink.primary)
        .frame(minHeight: 160)
        .overlay(alignment: .topLeading) {
          if text.isEmpty {
            Text(verbatim: placeholder)
              .font(.system(size: 19))
              .foregroundStyle(Theme.Ink.faint)
              .padding(.top, Theme.Spacing.sm)
              .padding(.leading, 5)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .padding(Theme.Spacing.md)
        .detailCard()
        .accessibilityLabel(Text(verbatim: placeholder))
        .accessibilityIdentifier("composer.field")
      Text(verbatim: counter)
        .themeFont(.caption)
        .foregroundStyle(isOverLimit ? Theme.Status.bad : Theme.Ink.faint)
        .monospacedDigit()
        .padding(.horizontal, Theme.Spacing.xs)
    }
    .task { isFocused = true }
  }
}
