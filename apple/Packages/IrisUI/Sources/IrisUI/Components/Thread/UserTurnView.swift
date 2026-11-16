import SwiftUI

/// What the user said (spoken or typed) as a turn of the conversation: a bubble in the accent tint on the right with the time under
/// it. A `footer` (the memo detail's recording player) sits inside the bubble under the text; `onCopy` adds Copy and `onDetails` Details to its long press.
public struct UserTurnView<Footer: View>: View {
  private let text: String
  private let time: String
  private let identifier: String
  private let textRole: Theme.TextRole
  private let onCopy: (() -> Void)?
  private let onDetails: (() -> Void)?
  private let hasFooter: Bool
  private let collapsedLineLimit: Int?
  private let footer: Footer

  /// - Parameters:
  ///   - textRole: The size of the text: the iPhone's 15 pt `.subheadline`, the Mac passes `.footnote`.
  ///   - hasFooter: `false` when the footer builds nothing (an `if` that did not hold): no hairline, no empty row.
  ///   - collapsedLineLimit: Cuts the text after this many lines behind a Show all button (a long transcript); `nil` shows it whole.
  public init(
    text: String, time: String, identifier: String = "thread.turn.user", textRole: Theme.TextRole = .subheadline,
    onCopy: (() -> Void)? = nil, onDetails: (() -> Void)? = nil, hasFooter: Bool = true,
    collapsedLineLimit: Int? = nil,
    @ViewBuilder footer: () -> Footer
  ) {
    self.text = text
    self.time = time
    self.identifier = identifier
    self.textRole = textRole
    self.onCopy = onCopy
    self.onDetails = onDetails
    self.hasFooter = hasFooter
    self.collapsedLineLimit = collapsedLineLimit
    self.footer = footer()
  }

  public var body: some View {
    ChatBubble(side: .user, time: time, onCopy: onCopy, onDetails: onDetails, hasFooter: hasFooter) {
      if let collapsedLineLimit {
        ClampedText(text: text, role: textRole, lineLimit: collapsedLineLimit)
      } else {
        Text(verbatim: text)
          .themeFont(textRole)
          .foregroundStyle(Theme.Ink.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
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
    onCopy: (() -> Void)? = nil, onDetails: (() -> Void)? = nil
  ) {
    self.init(
      text: text, time: time, identifier: identifier, textRole: textRole, onCopy: onCopy, onDetails: onDetails,
      hasFooter: false, footer: { EmptyView() })
  }
}
