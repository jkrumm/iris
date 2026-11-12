import IrisCore
import IrisUI
import SwiftUI

/// Where Shift-Return puts its new line: at the caret, not at the end of the text.
enum PromptCaret {
  /// `text` with a line break at the caret (replacing a selected range), and the caret after it. Without a caret, or one that no
  /// longer fits the text (it was set for an older string), the break goes at the end.
  static func insertingNewline(into text: String, selection: TextSelection?) -> (
    text: String, selection: TextSelection?
  ) {
    var edited = text
    guard let selection, case .selection(let range) = selection.indices, fits(range, in: text) else {
      edited.append("\n")
      return (edited, nil)
    }
    let offset = text.distance(from: text.startIndex, to: range.lowerBound)
    edited.replaceSubrange(range, with: "\n")
    let caret = edited.index(edited.startIndex, offsetBy: offset + 1)
    return (edited, TextSelection(insertionPoint: caret))
  }

  private static func fits(_ range: Range<String.Index>, in text: String) -> Bool {
    range.lowerBound >= text.startIndex && range.upperBound <= text.endIndex
  }
}

/// The text field of a conversation: a field that grows from one line to eight over a ``ComposerModel``. Return sends,
/// Shift-Return adds a line at the caret, and Escape (when ``leavesOnEscape``) hands the keyboard back. The composer bar and
/// the popover's quick-ask line are both this field.
struct MacPromptField: View {
  @Bindable var model: ComposerModel
  let placeholder: String
  let isEnabled: Bool
  let identifier: String
  /// Escape leaves the field. The popover keeps it for itself: there Escape closes the panel.
  let leavesOnEscape: Bool
  var focus: FocusState<Bool>.Binding
  /// Return, with something to send.
  let onSend: () -> Void
  @State private var selection: TextSelection?

  var body: some View {
    TextField(placeholder, text: $model.text, selection: $selection, axis: .vertical)
      .textFieldStyle(.plain)
      .lineLimit(1...8)
      .macFont(.body)
      .focused(focus)
      .disabled(!isEnabled)
      .onKeyPress(keys: [.return]) { press in handleReturn(press) }
      .onKeyPress(.escape) {
        guard leavesOnEscape else { return .ignored }
        focus.wrappedValue = false
        return .handled
      }
      // A send clears the text; a caret kept from the old text must not outlive it.
      .onChange(of: model.text.isEmpty) { selection = nil }
      .padding(.horizontal, Theme.Spacing.macComposerFieldHorizontal)
      .padding(.vertical, Theme.Spacing.macComposerFieldVertical)
      .background(Theme.Surface.panel, in: .rect(cornerRadius: Theme.Spacing.macComposerRadius))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Spacing.macComposerRadius)
          .strokeBorder(Theme.Surface.border, lineWidth: 0.5)
      }
      .accessibilityIdentifier(identifier)
  }

  private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
    if press.modifiers.contains(.shift) {
      let edited = PromptCaret.insertingNewline(into: model.text, selection: selection)
      model.text = edited.text
      selection = edited.selection
      return .handled
    }
    if model.canSend { onSend() }
    return .handled
  }
}
