import SwiftUI
import Textual

/// A reply's table: a grid on the card panel. A table wider than the reply scrolls sideways inside the card, with a fade over
/// the trailing edge while columns run past it; a long cell wraps at ``columnCap`` instead of widening the whole table.
public struct MarkdownTableView: View {
  /// The widest a column grows before its text wraps, in points.
  static let columnCap: CGFloat = 240
  private static let fadeWidth = Theme.Spacing.gutter

  private let table: MarkdownTable
  /// How far the columns reach past the visible edge, in points; 0 when the table fits or its end is in view.
  @State private var hiddenTrailing: CGFloat = 0

  public init(table: MarkdownTable) {
    self.table = table
  }

  public var body: some View {
    ScrollView(.horizontal) {
      grid
        .padding(Theme.Spacing.md)
    }
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    .onScrollGeometryChange(for: CGFloat.self) { geometry in
      max(0, geometry.contentSize.width - geometry.contentOffset.x - geometry.containerSize.width)
    } action: { _, hidden in
      hiddenTrailing = hidden
    }
    .overlay(alignment: .trailing) {
      if hiddenTrailing > 1 {
        LinearGradient(
          colors: [Theme.Surface.panel.opacity(0), Theme.Surface.panel], startPoint: .leading, endPoint: .trailing
        )
        .frame(width: Self.fadeWidth)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .detailCard()
    .accessibilityIdentifier("thread.table")
  }

  private var grid: some View {
    Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.lg, verticalSpacing: Theme.Spacing.sm) {
      GridRow {
        ForEach(Array(table.headers.enumerated()), id: \.offset) { column, header in
          cell(header, column: column)
            .themeFont(.caption, weight: .semibold)
            .foregroundStyle(Theme.Ink.muted)
        }
      }
      Divider().gridCellColumns(max(table.headers.count, 1))
      ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
        GridRow {
          ForEach(Array(row.enumerated()), id: \.offset) { column, value in
            cell(value, column: column)
              .themeFont(.footnote)
              .foregroundStyle(Theme.Ink.primary)
          }
        }
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private func cell(_ markdown: String, column: Int) -> some View {
    let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
    let math = MathSpans.prepare(markdown)
    return CappedWidth(cap: Self.columnCap) {
      InlineText(markdown: math ?? markdown, syntaxExtensions: math == nil ? [] : [.math])
        .textual.inlineStyle(.iris)
        .multilineTextAlignment(alignment.textAlignment)
    }
    .gridColumnAlignment(alignment.horizontalAlignment)
  }
}

extension MarkdownTable.Alignment {
  fileprivate var horizontalAlignment: HorizontalAlignment {
    switch self {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  fileprivate var textAlignment: TextAlignment {
    switch self {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}

/// Offers its one subview the proposed width, but never more than `cap`, so a long cell wraps at the cap while a short one
/// keeps its natural width (a plain `frame(maxWidth:)` clamps the frame and leaves the text laid out at its full length).
private struct CappedWidth: Layout {
  let cap: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    return subview.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? cap, cap), height: proposal.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
  }
}
