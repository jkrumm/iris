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

/// A paragraph of a reply: the mockups' 16 pt body on a 1.5 line (`mock.css` `.mdx`), 10 pt between blocks, 6 pt between list items.
struct IrisParagraphStyle: StructuredText.ParagraphStyle {
  private static let lineSpacing: CGFloat = 0.31
  /// 10 pt at the 16 pt body.
  private static let spaceAbove: CGFloat = 0.625

  /// 6 pt at the 16 pt body.
  static let listItemSpacing = FontScaled<StructuredText.BlockSpacing>.fontScaled(top: 0.375)

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .textual.lineSpacing(.fontScaled(Self.lineSpacing))
      .textual.blockSpacing(.fontScaled(top: Self.spaceAbove))
  }
}

/// The marker column of every list: the same width and the same leading edge for a number ("1.") and a bullet, so an
/// ordered list and a bullet list in one answer indent alike (trailing-aligned, a bullet sat 23 pt right of a number).
private let listMarkerWidth = FontScaled<CGFloat>.fontScaled(1.5)

struct IrisOrderedListMarker: StructuredText.OrderedListMarker {
  func makeBody(configuration: Configuration) -> some View {
    Text("\(configuration.ordinal).")
      .monospacedDigit()
      .textual.frame(minWidth: listMarkerWidth, alignment: .leading)
  }
}

struct IrisBulletListMarker: StructuredText.UnorderedListMarker {
  func makeBody(configuration: Configuration) -> some View {
    SwiftUI.Image(systemName: "circle.fill")
      .textual.fontScale(0.33)
      .textual.frame(minWidth: listMarkerWidth, alignment: .leading)
  }
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

/// A fenced block: a header line with the language on the leading side and a copy button on the trailing one, then the code on
/// the JetBrains editor surface, scrolling sideways instead of wrapping. A fade on the trailing edge says there is more to
/// scroll to.
struct IrisCodeBlockStyle: StructuredText.CodeBlockStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        if let language = configuration.languageHint, !language.isEmpty {
          Text(verbatim: language)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .textCase(.uppercase)
            .foregroundStyle(CodeColors.label)
        }
        Spacer(minLength: 0)
        CopyCodeButton(copy: configuration.codeBlock.copyToPasteboard)
      }
      .padding(.horizontal, Theme.Spacing.md)
      .padding(.top, Theme.Spacing.sm)
      OverflowingCode(label: configuration.label)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CodeColors.background)
    .clipShape(.rect(cornerRadius: Theme.Radius.control))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.Surface.border, lineWidth: 0.5)
    }
    .textual.blockSpacing(.fontScaled(top: 0.8, bottom: 0))
  }
}

/// The copy icon of a code block's header: it turns into a checkmark for a moment after a tap. The icon is the header's height;
/// the hit area reaches out to a ``Theme/Spacing/tapTarget`` square around it without making the header taller.
private struct CopyCodeButton: View {
  let copy: () -> Void
  @State private var copied = false
  private static let iconSize: CGFloat = 16
  private static let confirmation = Duration.milliseconds(1500)

  var body: some View {
    Button {
      copy()
      copied = true
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(CodeColors.label)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: Self.iconSize, height: Self.iconSize)
        .contentShape(Rectangle().inset(by: -(Theme.Spacing.tapTarget - Self.iconSize) / 2))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      copied
        ? String(
          localized: "Copied", bundle: #bundle,
          comment: "VoiceOver label of a code block's copy button right after it copied")
        : String(localized: "Copy code", bundle: #bundle, comment: "VoiceOver label of the copy button on a code block")
    )
    .accessibilityIdentifier("thread.codeCopy")
    .task(id: copied) {
      guard copied else { return }
      do { try await Task.sleep(for: Self.confirmation) } catch { return }
      copied = false
    }
    .animation(.default, value: copied)
  }
}

/// The code lines in Textual's sideways scroll, with a fade over the trailing edge while lines run past it.
private struct OverflowingCode: View {
  let label: StructuredText.CodeBlockStyleConfiguration.Label
  /// How far the code reaches past the visible edge, in points; 0 when it all fits or the end is in view.
  @State private var hiddenTrailing: CGFloat = 0
  private static let fadeWidth = Theme.Spacing.gutter

  var body: some View {
    Overflow { state in
      label
        .textual.lineSpacing(.fontScaled(0.39))
        .textual.fontScale(0.8125)
        .fixedSize(horizontal: false, vertical: true)
        .monospaced()
        .padding(Theme.Spacing.md)
        .onGeometryChange(for: CGFloat.self) { proxy in
          guard let container = state.containerWidth else { return 0 }
          return max(0, proxy.frame(in: .scrollView).maxX - container)
        } action: {
          hiddenTrailing = $0
        }
    }
    .overlay(alignment: .trailing) {
      if hiddenTrailing > 1 {
        LinearGradient(
          colors: [CodeColors.background.opacity(0), CodeColors.background], startPoint: .leading, endPoint: .trailing
        )
        .frame(width: Self.fadeWidth)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
  }
}

extension View {
  /// The structured look of an assistant reply: headings, quotes, code on JetBrains colors.
  func irisMarkdown() -> some View {
    textual.headingStyle(IrisHeadingStyle())
      .textual.blockQuoteStyle(IrisBlockQuoteStyle())
      .textual.codeBlockStyle(IrisCodeBlockStyle())
      .textual.highlighterTheme(.iris)
      .textual.orderedListMarker(IrisOrderedListMarker())
      .textual.unorderedListMarker(IrisBulletListMarker())
  }
}
