import SwiftUI

/// What the user said (spoken or typed) as a turn of the conversation: a bubble in the accent tint on the right with the time under
/// it. A `footer` (the memo detail's recording player) sits inside the bubble under the text; `onCopy` adds Copy to its long press.
public struct UserTurnView<Footer: View>: View {
  private let text: String
  private let time: String
  private let identifier: String
  private let textRole: Theme.TextRole
  private let onCopy: (() -> Void)?
  private let hasFooter: Bool
  private let footer: Footer

  /// - Parameters:
  ///   - textRole: The size of the text: the iPhone's 15 pt `.subheadline`, the Mac passes `.footnote`.
  ///   - hasFooter: `false` when the footer builds nothing (an `if` that did not hold): no hairline, no empty row.
  public init(
    text: String, time: String, identifier: String = "thread.turn.user", textRole: Theme.TextRole = .subheadline,
    onCopy: (() -> Void)? = nil, hasFooter: Bool = true, @ViewBuilder footer: () -> Footer
  ) {
    self.text = text
    self.time = time
    self.identifier = identifier
    self.textRole = textRole
    self.onCopy = onCopy
    self.hasFooter = hasFooter
    self.footer = footer()
  }

  public var body: some View {
    ChatBubble(side: .user, time: time, onCopy: onCopy, hasFooter: hasFooter) {
      Text(verbatim: text)
        .themeFont(textRole)
        .foregroundStyle(Theme.Ink.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    } footer: {
      footer
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("You", bundle: #bundle, comment: "Who spoke a turn in a thread"))
    .accessibilityIdentifier(identifier)
  }
}

extension UserTurnView where Footer == EmptyView {
  public init(
    text: String, time: String, identifier: String = "thread.turn.user", textRole: Theme.TextRole = .subheadline,
    onCopy: (() -> Void)? = nil
  ) {
    self.init(
      text: text, time: time, identifier: identifier, textRole: textRole, onCopy: onCopy, hasFooter: false,
      footer: { EmptyView() })
  }
}
