import IrisCore

/// What the main window's sidebar can select. Each scope maps onto ``HistoryFilters``, the same filters the iPhone's History
/// uses, so the list, paging and event handling are the shared model's.
enum MacLibraryScope: Hashable, CaseIterable {
  case all
  case needsRoute
  case favorites
  case archive
  case chats
  case hermesThreads

  /// Narrows `filters` to the scope and drops the previous scope's narrowing; the search text stays.
  func apply(to filters: inout HistoryFilters) {
    let search = filters.searchText
    filters.clear()
    filters.searchText = search
    switch self {
    case .all: break
    case .needsRoute: filters.toggle(.needsRoute)
    case .favorites: filters.toggle(.favorites)
    case .archive: filters.toggle(.archived)
    case .chats: filters.toggle(.chats)
    case .hermesThreads: filters.setKind(.hermes)
    }
  }
}
