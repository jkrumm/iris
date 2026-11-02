import Testing

@testable import Iris

@Suite("History result count")
struct HistoryResultCountTests {
  @Test("the count is exact only for a settled list that fits the first page")
  func exactCount() {
    #expect(HistoryResultCount.exact(memos: 3, isSettled: true) == 3)
    #expect(HistoryResultCount.exact(memos: 0, isSettled: true) == 0)
    #expect(
      HistoryResultCount.exact(memos: HistoryFilters.pageSize - 1, isSettled: true) == HistoryFilters.pageSize - 1)
    // A full page may have more behind it, and a list still loading is not the answer yet.
    #expect(HistoryResultCount.exact(memos: HistoryFilters.pageSize, isSettled: true) == nil)
    #expect(HistoryResultCount.exact(memos: 3, isSettled: false) == nil)
  }

  @Test("the button names the count, one memo in the singular, no number when unknown")
  func buttonTitle() {
    #expect(HistoryResultCount.buttonTitle(nil) == "Show memos")
    #expect(HistoryResultCount.buttonTitle(1) == "Show 1 memo")
    #expect(HistoryResultCount.buttonTitle(3) == "Show 3 memos")
  }
}
