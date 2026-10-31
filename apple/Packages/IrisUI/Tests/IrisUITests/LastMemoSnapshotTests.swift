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

  @Test("a memo is stored and the widget reloaded; the same state again costs no reload")
  func storesAndDedupes() {
    let store = InMemoryLastMemoSnapshotStore()
    let counter = Counter()
    let feed = feed(store, counter: counter)
    feed.observe(memo("a"))
    #expect(store.load()?.phase == .processing)
    #expect(counter.reloads == 1)
    feed.observe(memo("a"))
    #expect(counter.reloads == 1)
    feed.observe(memo("a", phase: .done, chip: "Hermes", headline: "Plan"))
    #expect(store.load()?.headline == "Plan")
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
    feed.observe(memo("c"))
    feed.forget(id: "c")
    #expect(store.load() == nil)
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
