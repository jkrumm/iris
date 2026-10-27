import IrisCore
import IrisUI
import SwiftUI

/// Placeholder menu bar panel: the recent memos from the shared fake data.
struct RecentMemosPanel: View {
  let model: HistoryModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      Text(String(localized: "Recent memos", comment: "Menu bar panel title"))
        .themeFont(.subheadline, weight: .semibold)
        .foregroundStyle(Theme.Ink.primary)
      ForEach(model.memos.prefix(5)) { memo in
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
          RouteChip(label: memo.routeLabel, systemImage: "arrow.triangle.branch")
          Text(memo.rowHeadline)
            .themeFont(.footnote)
            .foregroundStyle(Theme.Ink.primary)
            .lineLimit(1)
          Spacer(minLength: Theme.Spacing.sm)
          Text(memo.relativeTime)
            .themeFont(.caption)
            .foregroundStyle(Theme.Ink.muted)
        }
      }
    }
    .padding(Theme.Spacing.lg)
    .frame(width: 420)
    .accessibilityIdentifier("mac.recent")
  }
}
