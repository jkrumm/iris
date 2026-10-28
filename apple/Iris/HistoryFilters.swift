import IrisCore

/// The chips above the list. One is active at a time; tapping it again clears it.
enum QuickFilter: CaseIterable, Hashable {
  case favorites
  case chats
  case needsRoute
  case archived
}

/// Everything that narrows the History list: a quick-filter chip, the filter sheet (route, state) and the search
/// text. They combine; `query(cursor:)` is the one place that turns them into `GET /v1/memos` parameters.
struct HistoryFilters: Hashable {
  static let pageSize = 50

  private(set) var quick: QuickFilter?
  private(set) var route: RouteDestination?
  private(set) var state: MemoState?
  var searchText = ""

  /// The state the server is asked for. The Needs route chip and the sheet's Needs route state are one filter.
  var effectiveState: MemoState? { quick == .needsRoute ? .needsRoute : state }

  /// How many sheet filters are on, for the badge on the filter button.
  var sheetFilterCount: Int { (route == nil ? 0 : 1) + (effectiveState == nil ? 0 : 1) }

  var isFiltering: Bool { quick != nil || sheetFilterCount > 0 || trimmedSearch != nil }

  /// The server alone can decide membership: `kind` and `q` are not on the wire memo.
  var needsServerMatching: Bool { quick == .chats || trimmedSearch != nil }

  private var trimmedSearch: String? {
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  mutating func toggle(_ filter: QuickFilter) {
    quick = quick == filter ? nil : filter
    if quick == .needsRoute { state = nil }
  }

  mutating func toggleRoute(_ destination: RouteDestination) {
    route = route == destination ? nil : destination
  }

  mutating func toggleState(_ newState: MemoState) {
    if effectiveState == newState {
      quick = quick == .needsRoute ? nil : quick
      state = nil
    } else if newState == .needsRoute {
      quick = .needsRoute
      state = nil
    } else {
      quick = quick == .needsRoute ? nil : quick
      state = newState
    }
  }

  /// Clears the sheet's filters; the chip and the search stay.
  mutating func resetSheet() {
    route = nil
    state = nil
    if quick == .needsRoute { quick = nil }
  }

  mutating func clear() {
    self = HistoryFilters()
  }

  func query(cursor: String? = nil) -> ListMemosQuery {
    ListMemosQuery(
      limit: Self.pageSize, cursor: cursor, q: trimmedSearch, route: route, state: effectiveState,
      favorite: quick == .favorites, archived: quick == .archived, kind: quick == .chats ? .chat : nil)
  }

  /// The flag, route and state half of the filter, for a memo the client already holds (an SSE update, an
  /// optimistic flag change). It cannot tell `q` or `kind`; see `needsServerMatching`.
  func matches(_ memo: Memo) -> Bool {
    guard !memo.isDeleted, memo.archived == (quick == .archived) else { return false }
    if quick == .favorites, !memo.favorite { return false }
    if let route, memo.route != route.rawValue { return false }
    if let effectiveState, memo.state != effectiveState { return false }
    return true
  }
}
