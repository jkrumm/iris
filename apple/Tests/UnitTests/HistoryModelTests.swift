import Foundation
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("HistoryModel")
struct HistoryModelTests {
  let client = FakeAPIClient(now: { MemoFactory.now })
  let model: HistoryModel

  init() {
    model = HistoryModel(client: client)
  }

  private func seed(_ memos: Memo...) async {
    for memo in memos { await client.seed(MemoFactory.detail(memo)) }
  }

  private var ids: [String] { model.memos.map(\.id) }

  private func serverFlags(_ id: String) async throws -> Memo {
    try await client.memo(id: id).memo
  }

  // MARK: Loading

  @Test("a parked memo is pinned above the newest-first list")
  func pinnedOnTop() async {
    await seed(
      MemoFactory.memo("old", age: 300), MemoFactory.memo("new", age: 10),
      MemoFactory.memo("parked", age: 600, state: .needsRoute))
    await model.load()
    #expect(ids == ["parked", "new", "old"])
    #expect(model.pinned.map(\.id) == ["parked"])
  }

  @Test("a done parked memo is no longer pinned")
  func doneIsNotPinned() async {
    await seed(MemoFactory.memo("new", age: 10), MemoFactory.memo("handled", age: 600, state: .needsRoute, done: true))
    await model.load()
    #expect(model.pinned.isEmpty)
    #expect(ids == ["new", "handled"])
  }

  @Test("paging appends the next page without repeating a memo that was pinned")
  func pagingDedupes() async {
    let page = HistoryFilters.pageSize
    await seed(MemoFactory.memo("parked", age: 10_000, state: .needsRoute))
    for index in 0..<page + 4 { await seed(MemoFactory.memo("m\(index)", age: Double(index))) }
    await model.load()
    #expect(model.items.count == page)

    // The parked memo is answered after the first page: the server now lists it as an item on page two.
    _ = try? await client.routeMemo(id: "parked", request: RouteRequest(destination: .journal))
    await model.loadMoreIfNeeded(current: model.items[page - 1])

    #expect(ids.count == page + 5)
    #expect(Set(ids).count == ids.count)
    #expect(model.pinned.map(\.id) == ["parked"])
  }

  @Test("only the last row triggers the next page")
  func pagingTriggersOnTheLastRow() async {
    let page = HistoryFilters.pageSize
    for index in 0..<page + 1 { await seed(MemoFactory.memo("m\(index)", age: Double(index))) }
    await model.load()
    await model.loadMoreIfNeeded(current: model.items[0])
    #expect(model.items.count == page)
    await model.loadMoreIfNeeded(current: model.items[page - 1])
    #expect(model.items.count == page + 1)
  }

  @Test("a filter reaches the server and a failed load flags the error")
  func filtersAndFailure() async {
    await seed(MemoFactory.memo("plain", age: 5), MemoFactory.memo("star", age: 10, favorite: true))
    model.filters.toggle(.favorites)
    await model.load()
    #expect(ids == ["star"])
    #expect(await client.calls.last == .listMemos(ListMemosQuery(limit: 50, favorite: true)))

    await client.enqueueFailure(.unexpectedStatus(500), for: .listMemos)
    await model.load()
    #expect(model.loadFailed)
    await model.load()
    #expect(!model.loadFailed)
  }

  @Test("a failed load after a filter change shows the error, not the previous filter's rows")
  func failedLoadClearsStaleRows() async {
    for index in 0..<HistoryFilters.pageSize + 1 { await seed(MemoFactory.memo("m\(index)", age: Double(index))) }
    await model.load()
    let last = model.items[model.items.count - 1]
    model.filters.toggle(.favorites)
    await client.enqueueFailure(.unexpectedStatus(500), for: .listMemos)
    await model.load()
    #expect(model.memos.isEmpty)
    #expect(model.loadFailed)

    let listCalls = await client.calls.filter { if case .listMemos = $0 { true } else { false } }.count
    await model.loadMoreIfNeeded(current: last)
    #expect(await client.calls.filter { if case .listMemos = $0 { true } else { false } }.count == listCalls)
  }

  @Test("the cursor of one filter set never pages another")
  func cursorBelongsToItsFilters() async {
    for index in 0..<HistoryFilters.pageSize + 1 { await seed(MemoFactory.memo("m\(index)", age: Double(index))) }
    await model.load()
    let last = model.items[model.items.count - 1]
    model.filters.toggle(.favorites)
    await model.loadMoreIfNeeded(current: last)
    #expect(model.items.count == HistoryFilters.pageSize)
    #expect(await client.calls.last == .listMemos(ListMemosQuery(limit: 50)))
  }

  @Test("a failed refresh with the same filters keeps the rows and says so")
  func failedRefreshKeepsRows() async {
    await seed(MemoFactory.memo("a"))
    await model.load()
    await client.enqueueFailure(.unexpectedStatus(500), for: .listMemos)
    await model.load()
    #expect(ids == ["a"])
    #expect(model.toast?.kind == .error)
  }

  // MARK: Flag actions

  @Test("done unpins a parked memo, dims it in place and tells the server")
  func doneUnpins() async throws {
    await seed(MemoFactory.memo("new", age: 10), MemoFactory.memo("parked", age: 600, state: .needsRoute))
    await model.load()
    await model.toggleDone(try #require(model.pinned.first))
    #expect(model.pinned.isEmpty)
    #expect(ids == ["new", "parked"])
    #expect(model.memos[1].done)
    #expect(try await serverFlags("parked").done)
    #expect(await client.calls.contains(.setFlags(id: "parked", done: true, favorite: nil, archived: nil)))
  }

  @Test("a second done swipe undoes it")
  func doneToggles() async throws {
    await seed(MemoFactory.memo("a", done: true))
    await model.load()
    await model.toggleDone(model.memos[0])
    #expect(!model.memos[0].done)
    #expect(try await !serverFlags("a").done)
  }

  @Test("favorite keeps the row and marks it")
  func favoriteMarks() async throws {
    await seed(MemoFactory.memo("a"))
    await model.load()
    await model.toggleFavorite(model.memos[0])
    #expect(model.memos[0].favorite)
    #expect(try await serverFlags("a").favorite)
  }

  @Test("unfavoriting under the Favorites filter removes the row")
  func unfavoriteLeavesFavorites() async {
    await seed(MemoFactory.memo("a", age: 1, favorite: true), MemoFactory.memo("b", age: 2, favorite: true))
    model.filters.toggle(.favorites)
    await model.load()
    await model.toggleFavorite(model.memos[0])
    #expect(ids == ["b"])
  }

  @Test("archive removes the row; under the Archived filter the unarchive does")
  func archiveRemoves() async throws {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    await model.load()
    await model.toggleArchived(model.memos[0])
    #expect(ids == ["b"])
    #expect(try await serverFlags("a").archived)

    model.filters.toggle(.archived)
    await model.load()
    #expect(ids == ["a"])
    await model.toggleArchived(model.memos[0])
    #expect(ids.isEmpty)
    #expect(try await !serverFlags("a").archived)
  }

  @Test("a refused flag change rolls the row back and says so")
  func flagRollback() async throws {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    await model.load()
    await client.enqueueFailure(.unexpectedStatus(500), for: .setFlags)
    await model.toggleArchived(model.memos[0])
    #expect(ids == ["a", "b"])
    #expect(!model.memos[0].archived)
    #expect(model.toast?.kind == .error)

    await client.enqueueFailure(.unexpectedStatus(500), for: .setFlags)
    await model.toggleDone(model.memos[0])
    #expect(!model.memos[0].done)
  }

  @Test("a flag change whose answer arrives after a delete does not bring the memo back")
  func staleFlagsAfterDelete() async {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    await model.load()
    let flagged = model.memos[0]
    let gate = await client.hold(.setFlags)
    let flags = Task { await model.toggleFavorite(flagged) }
    await gate.waitUntilHeld()
    await model.delete(flagged)
    gate.release()
    await flags.value
    #expect(ids == ["b"])
  }

  @Test("a failed flag change whose answer arrives after a delete does not roll the row back")
  func staleRollbackAfterDelete() async {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    await model.load()
    await client.enqueueFailure(.unexpectedStatus(500), for: .setFlags)
    let flagged = model.memos[0]
    let gate = await client.hold(.setFlags)
    let flags = Task { await model.toggleDone(flagged) }
    await gate.waitUntilHeld()
    await model.delete(flagged)
    gate.release()
    await flags.value
    #expect(ids == ["b"])
  }

  @Test("an undo whose answer arrives after a second delete does not show the memo")
  func staleUndoAfterDelete() async {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    await model.load()
    await model.delete(model.memos[0])
    let gate = await client.hold(.restoreMemo)
    let undo = Task { await model.undoDelete() }
    await gate.waitUntilHeld()
    // The restore has run on the server; a refresh shows the memo again and the user deletes it a second time
    // before the first restore's answer lands.
    await model.load()
    #expect(ids == ["a", "b"])
    await model.delete(model.memos[0])
    gate.release()
    await undo.value
    #expect(ids == ["b"])
  }

  @Test("a memo created on this device shows at the top at once and is not doubled by the next refresh")
  func insertCreated() async {
    await seed(MemoFactory.memo("a", age: 100))
    await model.load()
    let created = MemoFactory.memo("typed", age: 1, typed: true)
    model.insert(created)
    #expect(ids == ["typed", "a"])

    await seed(created)
    await model.load()
    #expect(ids == ["typed", "a"])
  }

  // MARK: Delete and undo

  @Test("delete removes the row at once and offers the undo, which restores it in place")
  func deleteAndUndo() async throws {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2), MemoFactory.memo("c", age: 3))
    await model.load()
    await model.delete(model.memos[1])
    #expect(ids == ["a", "c"])
    #expect(model.toast?.kind == .undoDelete(memoID: "b"))
    #expect(try await serverFlags("b").isDeleted)

    await model.undoDelete()
    #expect(ids == ["a", "b", "c"])
    #expect(model.toast == nil)
    #expect(try await !serverFlags("b").isDeleted)
    #expect(await client.calls.contains(.restoreMemo(id: "b")))
  }

  @Test("a refused delete puts the row back")
  func deleteRollback() async {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    await model.load()
    await client.enqueueFailure(.unexpectedStatus(500), for: .deleteMemo)
    await model.delete(model.memos[0])
    #expect(ids == ["a", "b"])
    #expect(model.toast?.kind == .error)
  }

  @Test("a memo the pipeline is still driving is not deletable")
  func deleteNeedsSettled() async {
    await seed(MemoFactory.memo("busy", state: .transcribed))
    await model.load()
    await model.delete(model.memos[0])
    #expect(ids == ["busy"])
    #expect(await !client.calls.contains(.deleteMemo(id: "busy")))
  }

  @Test("dismissing a stale toast leaves the newer one")
  func dismissIsKeyed() async {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    await model.load()
    await model.delete(model.memos[0])
    let first = model.toast
    await model.delete(model.memos[0])
    model.dismissToast(id: first!.id)
    #expect(model.toast != nil)
    model.dismissToast(id: model.toast!.id)
    #expect(model.toast == nil)
  }

  // MARK: Live updates

  private func event(_ id: String, _ state: MemoState = .notified) -> ServerEvent {
    .memoUpdated(MemoEvent(id: id, state: state, at: MemoFactory.now))
  }

  @Test("each update bumps that memo's revision, which is what reloads an open detail")
  func eventBumpsRevision() async {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    await model.load()
    #expect(model.revision(of: "a") == 0)
    await model.handle(event("a"))
    await model.handle(event("a"))
    #expect(model.revision(of: "a") == 2)
    #expect(model.revision(of: "b") == 0)
  }

  @Test("an update for a memo in the list refreshes the row in place")
  func eventUpdatesRow() async throws {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    await model.load()
    _ = try await client.setFlags(id: "b", done: nil, favorite: true, archived: nil)
    await model.handle(event("b"))
    #expect(ids == ["a", "b"])
    #expect(model.memos[1].favorite)
  }

  @Test("an update for a new memo inserts it where it sorts")
  func eventInserts() async {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("c", age: 3))
    await model.load()
    await seed(MemoFactory.memo("b", age: 2), MemoFactory.memo("fresh", age: 0))
    await model.handle(event("b"))
    await model.handle(event("fresh"))
    #expect(ids == ["fresh", "a", "b", "c"])
  }

  @Test("a memo that reaches needs_route is pinned, and answered it is not")
  func eventPins() async throws {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("m", age: 2, state: .transcribed))
    await model.load()
    await seed(MemoFactory.memo("m", age: 2, state: .needsRoute))
    await model.handle(event("m", .needsRoute))
    #expect(model.pinned.map(\.id) == ["m"])

    _ = try await client.routeMemo(id: "m", request: RouteRequest(destination: .journal))
    await model.handle(event("m", .routed))
    #expect(model.pinned.isEmpty)
    #expect(ids == ["a", "m"])
  }

  @Test("a memo that no longer matches the active filter leaves the list")
  func eventLeavesFilter() async throws {
    await seed(MemoFactory.memo("a", age: 1, favorite: true), MemoFactory.memo("b", age: 2, favorite: true))
    model.filters.toggle(.favorites)
    await model.load()
    _ = try await client.setFlags(id: "a", done: nil, favorite: false, archived: nil)
    await model.handle(event("a"))
    #expect(ids == ["b"])

    await seed(MemoFactory.memo("x", age: 0))
    await model.handle(event("x"))
    #expect(ids == ["b"])
  }

  @Test("a delete from another device removes the row")
  func eventRemovesDeleted() async throws {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    await model.load()
    _ = try await client.deleteMemo(id: "a")
    await model.handle(event("a"))
    #expect(ids == ["b"])
  }

  // MARK: Hidden memos and the media cache

  private final class Evictions {
    var ids: [String] = []
  }

  @Test("a hidden memo stays hidden after a relaunch until its delete settles")
  func hiddenSurvivesRelaunch() async {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    let store = InMemoryHiddenMemoStore()
    let first = HistoryModel(client: client, hiddenStore: store)
    await first.load()
    first.hide("a")
    #expect(first.memos.map(\.id) == ["b"])
    #expect(store.load() == ["a"])

    // The relaunch: a new model over the same store never shows the memo, whatever the server still lists.
    let relaunched = HistoryModel(client: client, hiddenStore: store)
    await relaunched.load()
    #expect(relaunched.memos.map(\.id) == ["b"])

    relaunched.unhide("a")
    #expect(store.load().isEmpty)
    await relaunched.load()
    #expect(relaunched.memos.map(\.id) == ["a", "b"])
  }

  @Test("settling a delete that was never hidden changes nothing")
  func unhideUnknown() {
    let store = InMemoryHiddenMemoStore(["x"])
    let model = HistoryModel(client: client, hiddenStore: store)
    model.unhide("other")
    #expect(store.load() == ["x"])
  }

  @Test("at launch only the ids with a queued delete stay hidden")
  func reconcileHidden() async {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2))
    let store = InMemoryHiddenMemoStore(["a", "b"])
    let model = HistoryModel(client: client, hiddenStore: store)
    model.reconcileHidden(pendingDeletions: ["a"])
    #expect(store.load() == ["a"])
    await model.load()
    #expect(model.memos.map(\.id) == ["b"])
  }

  @Test("the user defaults store round-trips the ids and removes its key when empty")
  func userDefaultsStore() throws {
    let suite = "iris-hidden-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsHiddenMemoStore(suiteName: suite)
    #expect(store.load().isEmpty)
    store.save(["b", "a"])
    #expect(UserDefaultsHiddenMemoStore(suiteName: suite).load() == ["a", "b"])
    store.save([])
    #expect(defaults.object(forKey: UserDefaultsHiddenMemoStore.key) == nil)
  }

  @Test("a deleted or hidden memo, and one deleted on another device, drops its cached media")
  func evictsMedia() async throws {
    await seed(MemoFactory.memo("a", age: 1), MemoFactory.memo("b", age: 2), MemoFactory.memo("c", age: 3))
    let evictions = Evictions()
    let model = HistoryModel(client: client, evictMedia: { evictions.ids.append($0) })
    await model.load()

    await model.delete(model.memos[0])
    #expect(evictions.ids == ["a"])

    model.hide("b")
    #expect(evictions.ids == ["a", "b"])

    // Deleted on another device: the event brings the soft-deleted memo.
    _ = try await client.deleteMemo(id: "c")
    await model.handle(event("c"))
    #expect(evictions.ids == ["a", "b", "c"])
    #expect(model.memos.isEmpty)
  }

  @Test("under a search the server decides whether a new memo belongs")
  func eventUnderSearchReloads() async {
    await seed(MemoFactory.memo("a", age: 1))
    model.filters.searchText = "memo b"
    await model.load()
    #expect(ids.isEmpty)
    await seed(MemoFactory.memo("b", age: 2))
    await model.handle(event("b"))
    #expect(ids == ["b"])
  }

  @Test("the event stream drives the list until cancelled")
  func streamDrivesList() async throws {
    await seed(MemoFactory.memo("a", age: 1))
    await model.load()
    let follow = Task { await model.observeEvents() }
    await seed(MemoFactory.memo("b", age: 0))
    client.emit(event("b"))
    for _ in 0..<200 where ids != ["b", "a"] { try await Task.sleep(for: .milliseconds(10)) }
    follow.cancel()
    #expect(ids == ["b", "a"])
  }
}
