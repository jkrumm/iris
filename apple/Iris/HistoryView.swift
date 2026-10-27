import IrisCore
import IrisUI
import SwiftUI

struct HistoryView: View {
  let model: HistoryModel

  var body: some View {
    NavigationStack {
      List(model.memos) { memo in
        NavigationLink(value: memo) {
          HistoryRow(memo: memo)
        }
        .accessibilityIdentifier("history.row")
        .listRowBackground(Theme.Surface.panel)
      }
      .accessibilityIdentifier("history.list")
      .scrollContentBackground(.hidden)
      .background(Theme.Surface.background)
      .overlay {
        if model.loadFailed {
          ContentUnavailableView(
            String(localized: "Could not load memos", comment: "History error title"),
            systemImage: "exclamationmark.triangle")
        }
      }
      .navigationTitle(String(localized: "History", comment: "Navigation title of the memo list"))
      .navigationDestination(for: Memo.self) { memo in
        MemoDetailView(memo: memo)
      }
    }
  }
}

private struct HistoryRow: View {
  let memo: Memo

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack {
        RouteChip(label: memo.routeLabel, systemImage: "arrow.triangle.branch")
        Spacer()
        Text(memo.relativeTime)
          .themeFont(.caption)
          .foregroundStyle(Theme.Ink.muted)
      }
      Text(memo.rowHeadline)
        .themeFont(.subheadline, weight: .semibold)
        .foregroundStyle(Theme.Ink.primary)
        .lineLimit(2)
      Text(memo.state.label)
        .themeFont(.caption, weight: .medium)
        .foregroundStyle(memo.state.color)
    }
    .padding(.vertical, Theme.Spacing.xs)
    .accessibilityElement(children: .combine)
  }
}
