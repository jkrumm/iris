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
      (.threads, ListMemosQuery(limit: 50, thread: true)),
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
    filters.toggle(.threads)
    #expect(filters.quick == .threads)
    filters.toggle(.threads)
    #expect(filters.quick == nil)
    #expect(filters.query() == ListMemosQuery(limit: 50))
  }

  @Test("a kind goes through ?kind= and a second tap, in any case, clears it")
  func kindQuery() {
    var filters = HistoryFilters()
    filters.toggleKind("github issue")
    #expect(filters.query() == ListMemosQuery(limit: 50, kind: "github issue"))
    #expect(filters.isSelected(kind: "Github Issue"))
    filters.toggleKind("GITHUB ISSUE")
    #expect(filters.query() == ListMemosQuery(limit: 50))
  }

  @Test("the thread narrowing sends thread=true without a chip")
  func threadNarrowing() {
    var filters = HistoryFilters()
    filters.setThread(true)
    #expect(filters.query() == ListMemosQuery(limit: 50, thread: true))
    #expect(filters.isFiltering && filters.needsServerMatching)
    filters.setThread(false)
    #expect(filters.query() == ListMemosQuery(limit: 50))
  }

  @Test("a chip, the sheet and the search combine into one query")
  func combined() {
    var filters = HistoryFilters()
    filters.toggle(.favorites)
    filters.toggleKind("task")
    filters.toggleState(.failed)
    filters.searchText = "  release "
    #expect(
      filters.query(cursor: "50")
        == ListMemosQuery(limit: 50, cursor: "50", q: "release", state: .failed, favorite: true, kind: "task"))
    #expect(filters.sheetFilterCount == 2)
  }

  @Test("a blank search sends no q")
  func blankSearch() {
    var filters = HistoryFilters()
    filters.searchText = "   "
    #expect(filters.query().q == nil)
    #expect(!filters.isFiltering)
  }

  @Test("reset clears the sheet and keeps the chip and the search")
  func resetSheet() {
    var filters = HistoryFilters()
    filters.toggle(.favorites)
    filters.toggleKind("note")
    filters.toggleState(.failed)
    filters.searchText = "plan"
    filters.resetSheet()
    #expect(filters.query() == ListMemosQuery(limit: 50, q: "plan", favorite: true))
  }

  @Test("matches judges flags, kind and state, and never shows an archived or deleted memo by default")
  func matching() {
    var filters = HistoryFilters()
    #expect(filters.matches(MemoFactory.memo("a")))
    #expect(!filters.matches(MemoFactory.memo("a", archived: true)))
    filters.toggle(.archived)
    #expect(filters.matches(MemoFactory.memo("a", archived: true)))
    #expect(!filters.matches(MemoFactory.memo("a")))

    filters.clear()
    filters.toggle(.favorites)
    filters.toggleKind("task")
    #expect(filters.matches(MemoFactory.memo("a", favorite: true, kind: "task")))
    #expect(filters.matches(MemoFactory.memo("a", favorite: true, kind: "Task")))
    #expect(!filters.matches(MemoFactory.memo("a", favorite: true, kind: "note")))
    #expect(!filters.matches(MemoFactory.memo("a", kind: "task")))
  }

  // MARK: Kind chips

  private func memos(_ kinds: [String?]) -> [Memo] {
    kinds.enumerated().map { MemoFactory.memo("m\($0.offset)", kind: $0.element) }
  }

  @Test("kinds are distinct case-insensitively, most frequent first, then by name; none adds nothing")
  func kindDerivation() {
    let filters = HistoryFilters()
    let loaded = memos(["note", "Task", "task", nil, "answer", "TASK", "note", ""])
    #expect(filters.kinds(in: loaded) == ["task", "note", "answer"])
    #expect(filters.kinds(in: memos([nil, nil])).isEmpty)
    #expect(filters.kinds(in: []).isEmpty)
  }

  @Test("the quick row shows at most five kinds")
  func kindCap() {
    let filters = HistoryFilters()
    let loaded = memos(["a", "b", "c", "d", "e", "f", "g"])
    #expect(filters.kinds(in: loaded, limit: HistoryFilters.kindChipLimit) == ["a", "b", "c", "d", "e"])
    #expect(filters.kinds(in: loaded).count == 7)
  }

  @Test("a selected kind stays visible when it drops out of the loaded set or past the cap")
  func selectedKindStays() {
    var filters = HistoryFilters()
    filters.toggleKind("zebra")
    #expect(filters.kinds(in: memos(["a", "a", "b"]), limit: 5) == ["a", "b", "zebra"])
    #expect(filters.kinds(in: []) == ["zebra"])
    let many = memos(["a", "b", "c", "d", "e", "f", "zebra"])
    #expect(filters.kinds(in: many, limit: 5) == ["a", "b", "c", "d", "zebra"])
  }
}
