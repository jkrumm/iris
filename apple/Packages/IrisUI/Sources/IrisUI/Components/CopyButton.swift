import SwiftUI

/// A glass button that copies something and confirms it: while `isCopied` the label turns into a green check with
/// the confirmation title. The swap animates unless Reduce Motion is on, and VoiceOver hears the confirmation.
public struct CopyButton: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let title: String
  private let copiedTitle: String
  private let isCopied: Bool
  private let action: () -> Void

  public init(title: String, copiedTitle: String, isCopied: Bool, action: @escaping () -> Void) {
    self.title = title
    self.copiedTitle = copiedTitle
    self.isCopied = isCopied
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Spacing.xs) {
        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
          .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
          .accessibilityHidden(true)
        Text(verbatim: isCopied ? copiedTitle : title)
          .contentTransition(reduceMotion ? .identity : .interpolate)
      }
      .themeFont(.footnote, weight: .semibold)
      .foregroundStyle(isCopied ? Theme.Status.good : Theme.Accent.tint)
      .padding(.horizontal, Theme.Spacing.md)
      .padding(.vertical, Theme.Spacing.sm)
    }
    .buttonStyle(.glass)
    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isCopied)
    .onChange(of: isCopied) {
      if isCopied { AccessibilityNotification.Announcement(copiedTitle).post() }
    }
  }
}
