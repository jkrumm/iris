import SwiftUI

/// How a `detailCard` pads its content.
public enum DetailCardInset: Sendable {
  /// The card insets (`Theme.Spacing.cardInset*`): the default, so no caller pads a card itself.
  case card
  /// No padding: for a card of rows that pad themselves and run edge to edge (dividers, a bar along the bottom edge, a
  /// horizontally scrolling table).
  case flush
}

extension View {
  /// The flat panel the detail screen's sections sit on: panel fill, hairline border, card radius, the card insets inside,
  /// and the width the container offers. Content is clipped to it, so a full-width bar reaches the border.
  public func detailCard(_ inset: DetailCardInset = .card) -> some View {
    padding(.horizontal, inset == .card ? Theme.Spacing.cardInsetHorizontal : 0)
      .padding(.vertical, inset == .card ? Theme.Spacing.cardInsetVertical : 0)
      .frame(maxWidth: .infinity, alignment: .leading)
      .clipShape(.rect(cornerRadius: Theme.Radius.card))
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
