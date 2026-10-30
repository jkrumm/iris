import SwiftUI
import Textual

extension StructuredText.HighlighterTheme {
  /// The JetBrains Light / Dark syntax colors (``CodeColors``) on Textual's token names.
  static let iris: Self = {
    func color(_ color: Color) -> AnyTextProperty { AnyTextProperty(.foregroundColor(DynamicColor(color))) }
    func italic(_ color: Color) -> AnyTextProperty {
      AnyTextProperty(.foregroundColor(DynamicColor(color)), .italic)
    }
    return Self(
      foregroundColor: DynamicColor(CodeColors.plain), backgroundColor: DynamicColor(CodeColors.background),
      tokenProperties: [
        .keyword: color(CodeColors.keyword), .builtin: color(CodeColors.keyword),
        .literal: color(CodeColors.keyword), .boolean: color(CodeColors.keyword),
        .important: color(CodeColors.keyword), .atrule: color(CodeColors.keyword),
        .string: color(CodeColors.string), .char: color(CodeColors.string), .regex: color(CodeColors.string),
        .attributeValue: color(CodeColors.string), .interpolation: color(CodeColors.string),
        .url: color(CodeColors.link), .number: color(CodeColors.number),
        .symbol: color(CodeColors.constant), .constant: italic(CodeColors.constant),
        .property: color(CodeColors.constant), .variable: color(CodeColors.plain),
        .className: color(CodeColors.type), .function: color(CodeColors.function),
        .functionName: color(CodeColors.function), .functionDefinition: color(CodeColors.function),
        .operator: color(CodeColors.plain), .punctuation: color(CodeColors.plain),
        .comment: color(CodeColors.comment), .blockComment: color(CodeColors.comment),
        .docComment: italic(CodeColors.docComment), .prolog: color(CodeColors.comment),
        .doctype: color(CodeColors.comment), .cdata: color(CodeColors.comment),
        .mark: color(CodeColors.docComment), .preprocessor: color(CodeColors.attribute),
        .directive: color(CodeColors.attribute), .attribute: color(CodeColors.attribute),
        .attributeName: color(CodeColors.attribute), .tag: color(CodeColors.tag),
        .selector: color(CodeColors.tag), .namespace: color(CodeColors.plain), .entity: color(CodeColors.escape),
        .inserted: color(Theme.Status.good), .deleted: color(Theme.Status.bad),
      ])
  }()
}

/// Headings of a reply: one step above the body at the top, a hairline under the first two levels.
struct IrisHeadingStyle: StructuredText.HeadingStyle {
  /// Font scale per level (1...6): h1 to h3 step above the body, h4 to h6 are body size and told apart by weight and colour.
  private static let scales: [CGFloat] = [1.35, 1.2, 1.08, 1, 1, 1]
  /// Levels up to this one get the hairline and the larger gap above.
  private static let lastRuledLevel = 2
  /// Levels up to this one are in primary ink; deeper ones in secondary.
  private static let lastPrimaryLevel = 3
  private static let lineSpacing: CGFloat = 0.15
  private static let spaceAboveRuled: CGFloat = 1.4
  private static let spaceAbove: CGFloat = 1.0
  private static let spaceBelow: CGFloat = 0.5
  private static let hairline: CGFloat = 1

  func makeBody(configuration: Configuration) -> some View {
    let level = min(max(configuration.headingLevel, 1), Self.scales.count)
    let isRuled = level <= Self.lastRuledLevel
    configuration.label
      .textual.fontScale(Self.scales[level - 1])
      .textual.lineSpacing(.fontScaled(Self.lineSpacing))
      .textual.blockSpacing(
        .fontScaled(top: isRuled ? Self.spaceAboveRuled : Self.spaceAbove, bottom: Self.spaceBelow)
      )
      .fontWeight(.semibold)
      .foregroundStyle(level <= Self.lastPrimaryLevel ? Theme.Ink.primary : Theme.Ink.secondary)
      .padding(.bottom, isRuled ? Theme.Spacing.xs : 0)
      .overlay(alignment: .bottom) {
        if isRuled { Theme.divider.frame(height: Self.hairline) }
      }
  }
}

/// A quote: an accent rule on the leading edge over a quiet panel.
struct IrisBlockQuoteStyle: StructuredText.BlockQuoteStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(Theme.Ink.secondary)
      .textual.padding(.fontScaled(0.8))
      .background {
        ZStack(alignment: .leading) {
          Rectangle().fill(Theme.Surface.subtle)
          Rectangle().fill(Theme.Accent.tint).frame(width: 3)
        }
        .clipShape(.rect(cornerRadius: Theme.Radius.tight))
      }
      .textual.blockSpacing(.fontScaled(top: 0.8, bottom: 0))
  }
}

/// A fenced block: the language on a header line, then the code on the JetBrains editor surface, scrolling sideways
/// instead of wrapping.
struct IrisCodeBlockStyle: StructuredText.CodeBlockStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let language = configuration.languageHint, !language.isEmpty {
        Text(verbatim: language)
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .textCase(.uppercase)
          .foregroundStyle(CodeColors.label)
          .padding(.horizontal, Theme.Spacing.md)
          .padding(.top, Theme.Spacing.sm)
      }
      Overflow {
        configuration.label
          .textual.lineSpacing(.fontScaled(0.39))
          .textual.fontScale(0.882)
          .fixedSize(horizontal: false, vertical: true)
          .monospaced()
          .padding(Theme.Spacing.md)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CodeColors.background)
    .clipShape(.rect(cornerRadius: Theme.Radius.card))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.Surface.border, lineWidth: 0.5)
    }
    .textual.blockSpacing(.fontScaled(top: 0.8, bottom: 0))
  }
}

extension View {
  /// The structured look of an assistant reply: headings, quotes, code on JetBrains colors.
  func irisMarkdown() -> some View {
    textual.headingStyle(IrisHeadingStyle())
      .textual.blockQuoteStyle(IrisBlockQuoteStyle())
      .textual.codeBlockStyle(IrisCodeBlockStyle())
      .textual.highlighterTheme(.iris)
  }
}
