import Foundation
import IrisCore
import Testing

@testable import IrisMac

@Suite("Done catch-up")
struct DoneCatchUpTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func memo(_ id: String, _ state: MemoState, updated: TimeInterval = 0) -> Memo {
    Memo(
      id: id, mode: .auto, device: "iphone", startedAt: now, state: state, createdAt: now,
      updatedAt: now.addingTimeInterval(updated))
  }

  @Test("the initial load only sets the baseline, even when memos in it are done")
  func initialLoad() {
    var catchUp = DoneCatchUp()
    #expect(catchUp.newlyDone(in: [], hasLoaded: false, filters: HistoryFilters()).isEmpty)
    #expect(catchUp.newlyDone(in: [Self.memo("a", .notified)], hasLoaded: true, filters: HistoryFilters()).isEmpty)
  }

  @Test("a memo that was running in the last snapshot and is done now is announced once")
  func finishedWhileAway() {
    var catchUp = DoneCatchUp()
    let filters = HistoryFilters()
    _ = catchUp.newlyDone(in: [Self.memo("a", .acted), Self.memo("b", .notified)], hasLoaded: true, filters: filters)
    let done = [Self.memo("a", .notified, updated: 5), Self.memo("b", .notified)]
    #expect(catchUp.newlyDone(in: done, hasLoaded: true, filters: filters) == ["a"])
    #expect(catchUp.newlyDone(in: done, hasLoaded: true, filters: filters).isEmpty)
  }

  @Test(
    "a memo new to the list that finished after everything the last snapshot knew is announced; an older one is not")
  func newToTheList() {
    var catchUp = DoneCatchUp()
    let filters = HistoryFilters()
    _ = catchUp.newlyDone(in: [Self.memo("a", .notified, updated: 10)], hasLoaded: true, filters: filters)
    let next = [
      Self.memo("fresh", .notified, updated: 20), Self.memo("a", .notified, updated: 10),
      Self.memo("older", .notified, updated: -50),
    ]
    #expect(catchUp.newlyDone(in: next, hasLoaded: true, filters: filters) == ["fresh"])
  }

  @Test("a new filter sets a new baseline instead of announcing what it reveals")
  func filterChange() {
    var catchUp = DoneCatchUp()
    _ = catchUp.newlyDone(in: [Self.memo("a", .acted)], hasLoaded: true, filters: HistoryFilters())
    var searching = HistoryFilters()
    searching.searchText = "milk"
    #expect(catchUp.newlyDone(in: [Self.memo("a", .notified, updated: 5)], hasLoaded: true, filters: searching).isEmpty)
  }

  @Test("a deleted memo is never announced")
  func deleted() {
    var catchUp = DoneCatchUp()
    let filters = HistoryFilters()
    _ = catchUp.newlyDone(in: [Self.memo("a", .acted)], hasLoaded: true, filters: filters)
    var gone = Self.memo("a", .notified, updated: 5)
    gone.deletedAt = Self.now
    #expect(catchUp.newlyDone(in: [gone], hasLoaded: true, filters: filters).isEmpty)
  }

  @Test("the link tracker reports each return of the connection, not the first sign of life twice")
  func linkTracker() {
    var tracker = LinkTracker()
    let seen = [ServerLink.unknown, .live, .live, .unreachable, .live, .rejected, .live].map { tracker.cameBack($0) }
    #expect(seen == [false, true, false, false, true, false, true])
  }
}
