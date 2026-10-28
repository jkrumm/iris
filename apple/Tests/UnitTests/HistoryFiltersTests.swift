import IrisCore
import Testing

@testable import Iris

@Suite("HistoryFilters")
struct HistoryFiltersTests {
  @Test("no filter asks for the plain first page")
  func plainQuery() {
    #expect(HistoryFilters().query() == ListMemosQuery(limit: 50))
  }

  @Test(
    "each quick filter becomes its query parameter",
    arguments: [
      (QuickFilter.favorites, ListMemosQuery(limit: 50, favorite: true)),
      (.chats, ListMemosQuery(limit: 50, kind: .chat)),
      (.needsRoute, ListMemosQuery(limit: 50, state: .needsRoute)),
      (.archived, ListMemosQuery(limit: 50, archived: true)),
    ])
  func quickQuery(filter: QuickFilter, expected: ListMemosQuery) {
    var filters = HistoryFilters()
    filters.toggle(filter)
    #expect(filters.query() == expected)
  }

  @Test("one quick filter is active at a time and a second tap clears it")
  func quickIsExclusive() {
    var filters = HistoryFilters()
    filters.toggle(.favorites)
    filters.toggle(.chats)
    #expect(filters.quick == .chats)
    filters.toggle(.chats)
    #expect(filters.quick == nil)
    #expect(filters.query() == ListMemosQuery(limit: 50))
  }

  @Test("a chip, the sheet and the search combine into one query")
  func combined() {
    var filters = HistoryFilters()
    filters.toggle(.favorites)
    filters.toggleRoute(.hermes)
    filters.toggleState(.failed)
    filters.searchText = "  release "
    #expect(
      filters.query(cursor: "50")
        == ListMemosQuery(limit: 50, cursor: "50", q: "release", route: .hermes, state: .failed, favorite: true))
    #expect(filters.sheetFilterCount == 2)
  }

  @Test("a blank search sends no q")
  func blankSearch() {
    var filters = HistoryFilters()
    filters.searchText = "   "
    #expect(filters.query().q == nil)
    #expect(!filters.isFiltering)
  }

  @Test("the Needs route chip and the sheet's Needs route state are one filter")
  func needsRouteIsOneFilter() {
    var filters = HistoryFilters()
    filters.toggleState(.needsRoute)
    #expect(filters.quick == .needsRoute)
    #expect(filters.effectiveState == .needsRoute)
    filters.toggleState(.failed)
    #expect(filters.quick == nil)
    #expect(filters.effectiveState == .failed)
    filters.toggle(.needsRoute)
    #expect(filters.effectiveState == .needsRoute)
    #expect(filters.state == nil)
  }

  @Test("reset clears the sheet and keeps the chip and the search")
  func resetSheet() {
    var filters = HistoryFilters()
    filters.toggle(.favorites)
    filters.toggleRoute(.journal)
    filters.toggleState(.failed)
    filters.searchText = "plan"
    filters.resetSheet()
    #expect(filters.query() == ListMemosQuery(limit: 50, q: "plan", favorite: true))
  }

  @Test("matches judges flags, route and state, and never shows an archived or deleted memo by default")
  func matching() {
    var filters = HistoryFilters()
    #expect(filters.matches(MemoFactory.memo("a")))
    #expect(!filters.matches(MemoFactory.memo("a", archived: true)))
    filters.toggle(.archived)
    #expect(filters.matches(MemoFactory.memo("a", archived: true)))
    #expect(!filters.matches(MemoFactory.memo("a")))

    filters.clear()
    filters.toggle(.favorites)
    filters.toggleRoute(.hermes)
    #expect(filters.matches(MemoFactory.memo("a", route: "hermes", favorite: true)))
    #expect(!filters.matches(MemoFactory.memo("a", route: "journal", favorite: true)))
    #expect(!filters.matches(MemoFactory.memo("a", route: "hermes")))
  }
}
