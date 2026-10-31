import IrisUI
import SwiftUI

/// The search field and the filter button floating above the tab bar (`history.html` `.sbwrap`): a glass capsule and a
/// round glass button with the number of sheet filters as a badge. Content scrolls under them.
struct HistorySearchBar: View {
  @Binding var text: String
  let filterCount: Int
  let onFilter: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: Theme.Spacing.barGap) {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(Theme.Ink.muted)
          .accessibilityHidden(true)
        TextField(
          String(localized: "Search transcripts", comment: "Search field prompt on the memo list"), text: $text
        )
        .themeFont(.callout)
        .focused($isFocused)
        .submitLabel(.search)
        .autocorrectionDisabled()
        .accessibilityIdentifier("history.search")
        if !text.isEmpty {
          Button {
            text = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Ink.faint)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(String(localized: "Clear search", comment: "Empties the search field"))
        }
      }
      .padding(.horizontal, Theme.Spacing.lg)
      .frame(height: Theme.Spacing.barControlSize)
      .glassEffect(.regular, in: .capsule)
      Button(action: onFilter) {
        Image(systemName: "line.3.horizontal.decrease")
          .foregroundStyle(Theme.Ink.secondary)
          .frame(width: Theme.Spacing.barControlSize, height: Theme.Spacing.barControlSize)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular, in: .circle)
      .overlay(alignment: .topTrailing) { badge }
      .accessibilityLabel(String(localized: "Filter", comment: "Opens the filter sheet"))
      .accessibilityValue(filterCount > 0 ? Text("\(filterCount)") : Text(verbatim: ""))
      .accessibilityIdentifier("history.filter")
    }
    .padding(.horizontal, Theme.Spacing.barInset)
    .padding(.bottom, Theme.Spacing.barGap)
  }

  @ViewBuilder private var badge: some View {
    if filterCount > 0 {
      Text(verbatim: "\(filterCount)")
        .themeFont(.micro, weight: .bold)
        .foregroundStyle(Theme.Accent.onFill)
        .padding(.horizontal, Theme.Spacing.xs)
        .frame(minWidth: 18, minHeight: 18)
        .background(Theme.Accent.fill, in: .capsule)
        .offset(x: Theme.Spacing.hair, y: -Theme.Spacing.hair)
        .accessibilityHidden(true)
    }
  }
}
