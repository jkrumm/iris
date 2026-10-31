import Foundation
import Testing

@testable import IrisUI

struct LastMemoSnapshotTests {
  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  private func snapshot(
    id: String = "memo-1", phase: LastMemoSnapshot.Phase = .done, chip: String? = "Hermes", headline: String? = "Plan",
    updated: Date = t0
  ) -> LastMemoSnapshot {
    LastMemoSnapshot(
      memoID: id, createdAt: Self.t0, phase: phase, routeChip: chip, headline: headline, updatedAt: updated)
  }

  @Test("a headline is one line of at most 60 characters, ending in an ellipsis when cut")
  func headlineCap() throws {
    let long = String(repeating: "wort ", count: 40)
    let capped = try #require(snapshot(headline: long).headline)
    #expect(capped.count <= LastMemoSnapshot.headlineLimit)
    #expect(capped.hasSuffix("…"))
    #expect(snapshot(headline: "  Wochenplan\n abgestimmt  ").headline == "Wochenplan abgestimmt")
    #expect(snapshot(headline: String(repeating: "a", count: 60)).headline?.count == 60)
    #expect(snapshot(headline: "   \n").headline == nil)
    #expect(snapshot(chip: String(repeating: "x", count: 80)).routeChip?.count == LastMemoSnapshot.routeChipLimit)
  }

  @Test("the wire form holds exactly the allowed fields and omits absent ones")
  func wireForm() throws {
    let data = try JSONEncoder().encode(snapshot(chip: nil, headline: nil))
    let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
    #expect(Set(keys) == ["memoID", "createdAt", "phase", "updatedAt"])
    let full = try JSONEncoder().encode(snapshot())
    let fullKeys = try #require(try JSONSerialization.jsonObject(with: full) as? [String: Any]).keys
    #expect(Set(fullKeys) == ["memoID", "createdAt", "phase", "routeChip", "headline", "updatedAt"])
  }

  @Test("decoding caps a headline somebody wrote by hand")
  func decodeCaps() throws {
    let json = """
      {"memoID":"m","createdAt":0,"phase":"done","headline":"\(String(repeating: "b", count: 200))","updatedAt":0}
      """
    let decoded = try JSONDecoder().decode(LastMemoSnapshot.self, from: Data(json.utf8))
    #expect(decoded.headline?.count == LastMemoSnapshot.headlineLimit)
  }

  @Test("an unknown phase does not decode")
  func unknownPhase() {
    let json = #"{"memoID":"m","createdAt":0,"phase":"exploding","updatedAt":0}"#
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(LastMemoSnapshot.self, from: Data(json.utf8)) }
  }

  @Test("staleAt is the one rule: a settled snapshot has none, an in-flight one is stale after it")
  func staleAt() {
    #expect(snapshot(phase: .done).staleAt == nil)
    let running = snapshot(phase: .processing)
    #expect(running.staleAt == Self.t0.addingTimeInterval(LastMemoSnapshot.staleAfter))
    #expect(!running.isStale(at: Self.t0.addingTimeInterval(LastMemoSnapshot.staleAfter)))
    #expect(running.isStale(at: Self.t0.addingTimeInterval(LastMemoSnapshot.staleAfter + 1)))
  }

  @Test("only an in-flight snapshot goes stale")
  func staleness() {
    let old = Self.t0.addingTimeInterval(LastMemoSnapshot.staleAfter + 1)
    #expect(snapshot(phase: .processing).isStale(at: old))
    #expect(!snapshot(phase: .processing).isStale(at: Self.t0.addingTimeInterval(60)))
    for settled in [LastMemoSnapshot.Phase.done, .failed, .needsRoute] {
      #expect(!snapshot(phase: settled).isStale(at: old.addingTimeInterval(86_400)))
    }
  }
}

struct LastMemoSnapshotStoreTests {
  private static let value = LastMemoSnapshot(
    memoID: "memo-1", createdAt: Date(timeIntervalSince1970: 1_800_000_000), phase: .needsRoute, routeChip: "Hermes",
    headline: "Router bestellen", updatedAt: Date(timeIntervalSince1970: 1_800_000_060))

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "iris-widget-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  @Test("a saved snapshot loads back, and a nil save removes it")
  func roundTrip() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileLastMemoSnapshotStore(directory: directory)
    #expect(store.load() == nil)
    #expect(store.save(Self.value))
    #expect(store.load() == Self.value)
    #expect(store.save(nil))
    #expect(store.load() == nil)
    #expect(store.save(nil), "removing what is not there is not a failure")
  }

  @Test("without a container (no App Group entitlement) nothing is stored and nothing crashes")
  func noContainer() {
    let store = FileLastMemoSnapshotStore(directory: nil)
    #expect(!store.isAvailable)
    #expect(store.load() == nil)
    #expect(!store.save(Self.value))
    #expect(!store.save(nil))
  }

  @Test("an App Group identifier the build is not entitled to is an unavailable store")
  func unentitledGroup() {
    // The unit-test host has no application-groups entitlement: on iOS the container URL is nil, on macOS a URL
    // that does not exist and cannot be created. Either way: no crash, nothing readable.
    let store = FileLastMemoSnapshotStore.appGroup(identifier: "group.invalid.\(UUID().uuidString)")
    #expect(store.load() == nil)
  }

  @Test("a file that is not a snapshot reads as no data")
  func corruptFile() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: directory.appending(path: FileLastMemoSnapshotStore.fileName))
    #expect(FileLastMemoSnapshotStore(directory: directory).load() == nil)
  }

  @Test("a directory that cannot be created is a failed save, not a throw")
  func unwritable() throws {
    let blocker = temporaryDirectory()
    try Data().write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }
    #expect(!FileLastMemoSnapshotStore(directory: blocker.appending(path: "inside")).save(Self.value))
  }
}

struct LastMemoWidgetContentTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("no snapshot is the static Open Iris state")
  func noData() {
    #expect(LastMemoWidgetContent(nil, at: Self.now) == .noData)
  }

  @Test("a fresh snapshot is shown as it is")
  func fresh() {
    let snapshot = LastMemoSnapshot(
      memoID: "m", createdAt: Self.now, phase: .done, routeChip: "Journal", headline: "Fertig", updatedAt: Self.now)
    #expect(
      LastMemoWidgetContent(snapshot, at: Self.now.addingTimeInterval(60))
        == .memo(.init(phase: .done, routeChip: "Journal", headline: "Fertig", age: .since(Self.now))))
  }

  @Test("an in-flight snapshot nobody updated reads as idle; a settled one never does")
  func stale() {
    let later = Self.now.addingTimeInterval(LastMemoSnapshot.staleAfter + 60)
    func make(_ phase: LastMemoSnapshot.Phase) -> LastMemoSnapshot {
      LastMemoSnapshot(memoID: "m", createdAt: Self.now, phase: phase, updatedAt: Self.now)
    }
    #expect(LastMemoWidgetContent(make(.processing), at: later) == .idle)
    #expect(LastMemoWidgetContent(make(.failed), at: later) != .idle)
  }
}

@MainActor
struct LastMemoWidgetFeedTests {
  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  private final class Counter {
    var reloads = 0
  }

  private final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
  }

  private func feed(
    _ store: InMemoryLastMemoSnapshotStore, counter: Counter, now: @escaping @MainActor () -> Date = { t0 }
  ) -> LastMemoWidgetFeed {
    LastMemoWidgetFeed(store: store, reload: { counter.reloads += 1 }, now: now)
  }

  private func memo(
    _ id: String, age: TimeInterval = 0, phase: LastMemoSnapshot.Phase = .processing, chip: String? = nil,
    headline: String? = nil, deleted: Bool = false
  ) -> WidgetMemoObservation {
    WidgetMemoObservation(
      id: id, createdAt: Self.t0.addingTimeInterval(-age), phase: phase, routeChip: chip, headline: headline,
      isDeleted: deleted)
  }

  @Test("a memo is stored and the widget reloaded; a settled state seen again costs no write and no reload")
  func storesAndDedupes() {
    let store = InMemoryLastMemoSnapshotStore()
    let counter = Counter()
    let feed = feed(store, counter: counter)
    feed.observe(memo("a"))
    #expect(store.load()?.phase == .processing)
    #expect(counter.reloads == 1)
    feed.observe(memo("a", phase: .done, chip: "Hermes", headline: "Plan"))
    #expect(store.load()?.headline == "Plan")
    #expect(counter.reloads == 2)
    feed.observe(memo("a", phase: .done, chip: "Hermes", headline: "Plan"))
    #expect(counter.reloads == 2)
  }

  @Test("a settled state keeps its first stamp, so its age stays true")
  func settledKeepsStamp() {
    let clock = Clock(Self.t0)
    let store = InMemoryLastMemoSnapshotStore()
    let feed = feed(store, counter: Counter(), now: { clock.now })
    feed.observe(memo("a", phase: .done))
    clock.now = Self.t0.addingTimeInterval(3_600)
    feed.observe(memo("a", phase: .done))
    #expect(store.load()?.updatedAt == Self.t0)
  }

  @Test(
    "an in-flight memo seen again is restamped and the widget reloaded, so it never goes idle while the app shows it")
  func inFlightRestamps() throws {
    let clock = Clock(Self.t0)
    let counter = Counter()
    let store = InMemoryLastMemoSnapshotStore()
    let feed = feed(store, counter: counter, now: { clock.now })
    feed.observe(memo("a"))
    let firstStaleAt = try #require(store.load()?.staleAt)
    clock.now = Self.t0.addingTimeInterval(LastMemoSnapshot.staleAfter + 60)
    #expect(try #require(store.load()).isStale(at: clock.now))
    feed.observe(memo("a"))
    let restamped = try #require(store.load())
    #expect(!restamped.isStale(at: clock.now))
    #expect(try #require(restamped.staleAt) > firstStaleAt)
    #expect(counter.reloads == 2)
  }

  @Test("an older memo never replaces a newer one; a newer one does")
  func newestWins() {
    let store = InMemoryLastMemoSnapshotStore()
    let feed = feed(store, counter: Counter())
    feed.observe(memo("new", age: 10))
    feed.observe(memo("old", age: 600, phase: .done))
    #expect(store.load()?.memoID == "new")
    feed.observe(memo("newest", age: 0))
    #expect(store.load()?.memoID == "newest")
  }

  @Test("the shown memo being deleted clears the snapshot; another memo's deletion does not")
  func deletion() {
    let store = InMemoryLastMemoSnapshotStore()
    let feed = feed(store, counter: Counter())
    feed.observe(memo("a"))
    feed.observe(memo("b", age: 100, deleted: true))
    #expect(store.load()?.memoID == "a")
    feed.observe(memo("a", deleted: true))
    #expect(store.load() == nil)
  }

  @Test("a reset (the connection changed) clears the snapshot and what was forgotten")
  func reset() {
    let store = InMemoryLastMemoSnapshotStore()
    let counter = Counter()
    let feed = feed(store, counter: counter)
    feed.observe(memo("a"))
    feed.forget(id: "gone")
    feed.reset()
    #expect(store.load() == nil)
    #expect(counter.reloads == 2)
    feed.reset()
    #expect(counter.reloads == 2, "nothing stored, nothing to reload")
    feed.observe(memo("gone", phase: .done))
    #expect(store.load()?.memoID == "gone", "an id forgotten on the old server is a different memo on the new one")
  }

  @Test("a soft-deleted memo comes back when the app sees it restored")
  func restore() {
    let store = InMemoryLastMemoSnapshotStore()
    let feed = feed(store, counter: Counter())
    feed.observe(memo("a"))
    feed.observe(memo("a", deleted: true))
    #expect(store.load() == nil)
    feed.observe(memo("a", phase: .done))
    #expect(store.load()?.memoID == "a")
  }

  @Test("a memo the app hid or purged is not brought back by a late event")
  func forgetIsFinal() {
    let store = InMemoryLastMemoSnapshotStore()
    let counter = Counter()
    let feed = feed(store, counter: counter)
    feed.observe(memo("c"))
    feed.forget(id: "c")
    #expect(store.load() == nil)
    let reloads = counter.reloads
    feed.observe(memo("c", phase: .done))
    #expect(store.load() == nil)
    #expect(counter.reloads == reloads)
    feed.observe(memo("d"))
    #expect(store.load()?.memoID == "d")
  }

  @Test("the first launch picks up what the last run stored")
  func resumes() {
    let stored = LastMemoSnapshot(memoID: "a", createdAt: Self.t0, phase: .done, updatedAt: Self.t0)
    let store = InMemoryLastMemoSnapshotStore(stored)
    let counter = Counter()
    let feed = feed(store, counter: counter)
    feed.observe(memo("old", age: 50))
    #expect(store.load()?.memoID == "a")
    #expect(counter.reloads == 0)
  }

  @Test("a store that cannot be written costs no reload and never throws")
  func unwritable() {
    let store = InMemoryLastMemoSnapshotStore(accepting: false)
    let counter = Counter()
    let feed = feed(store, counter: counter)
    feed.observe(memo("a"))
    feed.forget(id: "a")
    #expect(counter.reloads == 0)
  }

  @Test("the snapshot never holds more than the headline: a long one is capped before it is stored")
  func capsBeforeStoring() {
    let store = InMemoryLastMemoSnapshotStore()
    let feed = feed(store, counter: Counter())
    feed.observe(memo("a", phase: .done, headline: String(repeating: "Satz ", count: 60)))
    #expect((store.load()?.headline?.count ?? 0) <= LastMemoSnapshot.headlineLimit)
  }
}

struct LastMemoTimelinePlanTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func snapshot(_ phase: LastMemoSnapshot.Phase, updated: Date = now) -> LastMemoSnapshot {
    LastMemoSnapshot(memoID: "m", createdAt: Self.now, phase: phase, headline: "Plan", updatedAt: updated)
  }

  @Test("no snapshot: one static entry, no relevance")
  func noData() {
    let plan = LastMemoTimelinePlan(snapshot: nil, now: Self.now)
    #expect(plan.entries == [.init(date: Self.now, content: .noData, relevance: nil)])
  }

  @Test("an in-flight snapshot gets an idle entry at its staleAt, from the same rule isStale uses")
  func idleEntry() throws {
    let running = snapshot(.processing)
    let plan = LastMemoTimelinePlan(snapshot: running, now: Self.now.addingTimeInterval(60))
    #expect(plan.entries.count == 2)
    let idle = plan.entries[1]
    #expect(idle.date == running.staleAt)
    #expect(idle.content == .idle)
    #expect(idle.relevance == nil)
    #expect(plan.entries[0].content != .idle)
  }

  @Test("settled snapshots have a single entry however old they are")
  func settled() {
    for phase in [LastMemoSnapshot.Phase.done, .failed, .needsRoute] {
      let plan = LastMemoTimelinePlan(snapshot: snapshot(phase), now: Self.now.addingTimeInterval(86_400))
      #expect(plan.entries.count == 1)
      #expect(plan.entries[0].content != .idle)
    }
  }

  @Test("an in-flight snapshot already past staleAt is idle now, with no relevance and no second entry")
  func alreadyStale() {
    let late = Self.now.addingTimeInterval(LastMemoSnapshot.staleAfter + 5)
    let plan = LastMemoTimelinePlan(snapshot: snapshot(.processing), now: late)
    #expect(plan.entries == [.init(date: late, content: .idle, relevance: nil)])
  }

  @Test("relevance: needs a route outranks failed, processing and done")
  func relevance() throws {
    func score(_ phase: LastMemoSnapshot.Phase) throws -> Float {
      try #require(LastMemoTimelinePlan(snapshot: snapshot(phase), now: Self.now).entries[0].relevance).score
    }
    #expect(try score(.needsRoute) > score(.failed))
    #expect(try score(.failed) > score(.processing))
    #expect(try score(.processing) > score(.done))
    #expect(try score(.done) > 0)
  }
}
