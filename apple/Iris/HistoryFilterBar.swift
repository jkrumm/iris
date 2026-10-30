import IrisUI
import SwiftUI

/// The quick-filter chips above the list.
struct HistoryFilterBar: View {
  @Binding var filters: HistoryFilters

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: Theme.Spacing.chipGap) {
        ForEach(QuickFilter.allCases, id: \.self) { filter in
          FilterChip(title: filter.title, systemImage: filter.systemImage, isOn: filters.quick == filter) {
            withAnimation(.snappy) { filters.toggle(filter) }
          }
          .accessibilityIdentifier("history.chip.\(filter.identifier)")
        }
      }
    }
    .contentMargins(.horizontal, Theme.Spacing.screenMargin, for: .scrollContent)
    .scrollIndicators(.hidden)
    .padding(.top, Theme.Spacing.chipRowTop)
  }
}

extension QuickFilter {
  var title: String {
    switch self {
    case .favorites: String(localized: "Favorites", comment: "Quick filter chip")
    case .chats: String(localized: "Chats", comment: "Quick filter chip")
    case .needsRoute: String(localized: "Needs route", comment: "Quick filter chip")
    case .archived: String(localized: "Archived", comment: "Quick filter chip")
    }
  }

  var systemImage: String {
    switch self {
    case .favorites: "star"
    case .chats: "bubble.left"
    case .needsRoute: "arrow.triangle.branch"
    case .archived: "archivebox"
    }
  }

  fileprivate var identifier: String {
    switch self {
    case .favorites: "favorites"
    case .chats: "chats"
    case .needsRoute: "needs-route"
    case .archived: "archived"
    }
  }
}
