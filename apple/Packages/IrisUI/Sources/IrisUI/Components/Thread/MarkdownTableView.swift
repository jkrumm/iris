import SwiftUI
import Textual

/// A reply's table. It is a grid while it fits the width and a stack of cards (the first column titles each card) when it
/// does not, so a wide table never scrolls sideways on a phone.
public struct MarkdownTableView: View {
  private let table: MarkdownTable

  public init(table: MarkdownTable) {
    self.table = table
  }

  public var body: some View {
    ViewThatFits(in: .horizontal) {
      grid
      cards
    }
    .accessibilityIdentifier("thread.table")
  }

  private var grid: some View {
    Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.lg, verticalSpacing: Theme.Spacing.sm) {
      GridRow {
        ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
          cell(header)
            .themeFont(.caption, weight: .semibold)
            .foregroundStyle(Theme.Ink.muted)
        }
      }
      Divider().gridCellColumns(max(table.headers.count, 1))
      ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
        GridRow {
          ForEach(Array(row.enumerated()), id: \.offset) { _, value in
            cell(value)
              .themeFont(.footnote)
              .foregroundStyle(Theme.Ink.primary)
          }
        }
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(Theme.Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .detailCard()
  }

  private var cards: some View {
    VStack(spacing: Theme.Spacing.sm) {
      ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          if let title = row.first {
            cell(title)
              .themeFont(.subheadline, weight: .semibold)
              .foregroundStyle(Theme.Ink.primary)
          }
          ForEach(Array(row.enumerated().dropFirst()), id: \.offset) { column, value in
            VStack(alignment: .leading, spacing: 0) {
              cell(table.headers[column])
                .themeFont(.caption, weight: .semibold)
                .foregroundStyle(Theme.Ink.muted)
              cell(value)
                .themeFont(.footnote)
                .foregroundStyle(Theme.Ink.secondary)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .detailCard()
      }
    }
  }

  private func cell(_ markdown: String) -> some View {
    InlineText(markdown: markdown)
      .textual.inlineStyle(.iris)
      .multilineTextAlignment(.leading)
  }
}
