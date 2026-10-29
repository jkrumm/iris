import Foundation
import Testing

@testable import IrisCapture

/// "Reset outbox": the unreadable queue file is renamed aside and kept, and a fresh queue opens.
struct OutboxQuarantineTests {
  private let moment = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10-26T07:33:20Z

  @Test func anUnreadableFileIsRenamedAsideAndKeptNextToIt() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "outbox.json")
    try Data("{ not json".utf8).write(to: file)
    let store = JSONFileOutboxStore(fileURL: file, now: { moment })

    await #expect(throws: OutboxStoreError.undecodable) { try await store.load() }
    let moved = try #require(try await store.quarantine())

    #expect(moved.lastPathComponent == "outbox.quarantined-20261026T073320Z.json")
    #expect(
      moved.deletingLastPathComponent().path == directory.path
        || moved.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
    #expect(try Data(contentsOf: moved) == Data("{ not json".utf8), "the bytes are kept as they were")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try await store.load() == OutboxRecord(), "a fresh queue opens")
    #expect(await store.quarantined().map(\.lastPathComponent) == [moved.lastPathComponent])
  }

  @Test func aSecondQuarantineInTheSameSecondNeverReusesAName() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "outbox.json")
    let store = JSONFileOutboxStore(fileURL: file, now: { moment })

    try Data("one".utf8).write(to: file)
    let first = try #require(try await store.quarantine())
    try Data("two".utf8).write(to: file)
    let second = try #require(try await store.quarantine())

    #expect(first != second)
    #expect(try Data(contentsOf: first) == Data("one".utf8))
    #expect(try Data(contentsOf: second) == Data("two".utf8))
    #expect(await store.quarantined().count == 2)
  }

  @Test func withoutAFileThereIsNothingToSetAside() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONFileOutboxStore(fileURL: directory.appending(path: "outbox.json"))
    #expect(try await store.quarantine() == nil)
    #expect(await store.quarantined().isEmpty)
  }

  @Test func theOtherFilesOfTheDirectoryAreNotQuarantinedFiles() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("x".utf8).write(to: directory.appending(path: "outbox.json"))
    try Data("x".utf8).write(to: directory.appending(path: "other.quarantined-1.json"))
    let store = JSONFileOutboxStore(fileURL: directory.appending(path: "outbox.json"))
    #expect(await store.quarantined().isEmpty)
  }

  @Test func theFakeStoreOpensEmptyAfterTheReset() async throws {
    let store = UnreadableOutboxStore()
    await #expect(throws: OutboxStoreError.undecodable) { try await store.load() }
    #expect(try await store.quarantine() != nil)
    #expect(try await store.load() == OutboxRecord())
    #expect(try await store.quarantine() == nil, "nothing left to set aside")
  }
}
