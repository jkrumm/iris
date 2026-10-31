import IrisUI
import SwiftUI

/// The large title and its one-line summary, the way the History mockup sets them: 30 pt bold on the screen margin,
/// 18 pt above, 6 pt below each line (`history.html` `h1` and `.sub`).
struct HistoryTitleBlock: View {
  let title: String
  let subtitle: String?
  let onCompose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        Text(verbatim: title)
          .themeFont(.display, weight: .bold)
          .foregroundStyle(Theme.Ink.primary)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: Theme.Spacing.sm)
        Button(action: onCompose) {
          Image(systemName: "square.and.pencil")
            .frame(width: Theme.Spacing.barControlSize, height: Theme.Spacing.barControlSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Accent.tint)
        .glassEffect(.regular, in: .circle)
        .accessibilityLabel(String(localized: "New memo", comment: "Opens the typed-memo composer"))
        .accessibilityIdentifier("history.compose")
      }
      .padding(.top, Theme.Spacing.titleTop)
      .padding(.bottom, Theme.Spacing.titleBottom)
      if let subtitle {
        Text(verbatim: subtitle)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.faint)
          .padding(.bottom, Theme.Spacing.titleBottom)
      }
    }
    .padding(.horizontal, Theme.Spacing.screenMargin)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
