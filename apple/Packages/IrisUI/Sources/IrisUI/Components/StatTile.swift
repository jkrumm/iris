import SwiftUI

/// A headline number with its label and a one-line comparison ("Memos · 38 · +27 % vs prior").
public struct StatTile: View {
  private let title: String
  private let value: String
  private let caption: String?
  private let captionColor: Color

  public init(title: String, value: String, caption: String? = nil, captionColor: Color = Theme.Ink.muted) {
    self.title = title
    self.value = value
    self.caption = caption
    self.captionColor = captionColor
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
      Text(verbatim: title)
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.muted)
      Text(verbatim: value)
        .themeFont(.kpi, weight: .bold)
        .foregroundStyle(Theme.Ink.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(verbatim: caption ?? " ")
        .themeFont(.caption)
        .foregroundStyle(captionColor)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.Spacing.md)
    .padding(.vertical, Theme.Spacing.md)
    .detailCard()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "\(title), \(value)"))
    .accessibilityValue(Text(verbatim: caption ?? ""))
  }
}
