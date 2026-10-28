import SwiftUI

/// A transient banner for the result of an action, with an optional trailing action (Undo). Glass is limited
/// to the banner itself.
public struct ToastBanner: View {
  private let message: String
  private let actionTitle: String?
  private let action: (() -> Void)?

  public init(message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    HStack(spacing: Theme.Spacing.md) {
      Text(verbatim: message)
        .themeFont(.footnote, weight: .medium)
        .foregroundStyle(Theme.Ink.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let actionTitle, let action {
        Button(action: action) {
          Text(verbatim: actionTitle)
            .themeFont(.footnote, weight: .semibold)
            .foregroundStyle(Theme.Accent.tint)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.vertical, Theme.Spacing.md)
    .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.floating * 2))
    .accessibilityElement(children: .contain)
  }
}
