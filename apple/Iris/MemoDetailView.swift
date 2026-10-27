import IrisCore
import IrisUI
import SwiftUI

/// Placeholder for the memo detail screen (transcript, steps, route decision land in R1).
struct MemoDetailView: View {
  let memo: Memo

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
      RouteChip(label: memo.routeLabel, systemImage: "arrow.triangle.branch")
      Text(memo.rowHeadline)
        .themeFont(.title3, weight: .semibold)
        .foregroundStyle(Theme.Ink.primary)
      Text(memo.state.label)
        .themeFont(.footnote, weight: .medium)
        .foregroundStyle(memo.state.color)
      Text(String(localized: "Memo detail is not built yet.", comment: "Placeholder on the detail screen"))
        .themeFont(.footnote)
        .foregroundStyle(Theme.Ink.muted)
      Spacer()
    }
    .padding(Theme.Spacing.lg)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.Surface.background)
    .navigationTitle(String(localized: "Memo", comment: "Navigation title of the memo detail"))
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("memo.detail")
  }
}
