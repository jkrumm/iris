import SwiftUI

extension View {
  /// The flat panel the detail screen's sections sit on: panel fill, hairline border, card radius. Content is
  /// clipped to it, so a full-width bar reaches the border.
  public func detailCard() -> some View {
    clipShape(.rect(cornerRadius: Theme.Radius.card))
      .background(Theme.Surface.panel, in: .rect(cornerRadius: Theme.Radius.card))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
          .strokeBorder(Theme.Surface.border, lineWidth: 0.5)
      }
  }
}

/// A small uppercase section label with an optional trailing note ("STEPS", "TRANSCRIPT · de").
public struct DetailSectionLabel: View {
  private let title: String
  private let trailing: String?

  public init(_ title: String, trailing: String? = nil) {
    self.title = title
    self.trailing = trailing
  }

  public var body: some View {
    HStack {
      Text(verbatim: title)
      Spacer(minLength: Theme.Spacing.sm)
      if let trailing { Text(verbatim: trailing) }
    }
    .themeFont(.caption, weight: .semibold)
    .textCase(.uppercase)
    .foregroundStyle(Theme.Ink.muted)
    .accessibilityAddTraits(.isHeader)
  }
}
