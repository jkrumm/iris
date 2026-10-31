import Foundation
import Testing

@testable import IrisCapture

/// A file the sweep cannot move out of the capture directory stays where it is; it must not stay invisible.
struct StrayFilesTests {
  /// A store whose volume refuses every move.
  private struct ReadOnlyQuarantine: SegmentFileStore {
    let directory: URL

    func segmentFiles() async -> [URL] {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      return names.filter { $0.hasSuffix(".m4a") }.map { directory.appending(path: $0) }
    }
    func inspect(_ url: URL) -> (byteCount: Int, duration: TimeInterval)? { nil }
    func setAside(_ url: URL) async -> URL? { nil }
    func setAsideFiles() async -> [SetAsideFile] { [] }
    /// The strays are described by the store that holds them, not looked up by the outbox.
    func describe(_ urls: [URL]) async -> [SetAsideFile] {
      urls.map { SetAsideFile(url: $0, byteCount: 4_242, modifiedAt: nil) }
    }
  }

  @Test func aFileThatCannotBeMovedIsReportedAndListedForSettings() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stray = directory.appending(path: "\(memo(9).uuidString)-0.m4a")
    try Data("half a take".utf8).write(to: stray)
    let harness = try await OutboxHarness()
    #expect(await harness.outbox.strayFiles().isEmpty, "nothing before a sweep")

    let report = await harness.outbox.sweepOrphans(using: ReadOnlyQuarantine(directory: directory))

    #expect(report.stuck == [stray] && report.quarantined.isEmpty)
    let listed = await harness.outbox.strayFiles()
    #expect(listed.map(\.url) == [stray] && listed.first?.byteCount == 4_242, "sized by the store")
    #expect(FileManager.default.fileExists(atPath: stray.path), "and it is still there")

    await harness.outbox.shutdown()
  }

  @Test func aStrayThatIsGoneByItselfIsNoLongerListed() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stray = directory.appending(path: "\(memo(9).uuidString)-0.m4a")
    try Data("half a take".utf8).write(to: stray)
    let harness = try await OutboxHarness()
    // The real store, with a quarantine folder that cannot be made (a file is in its place).
    try Data().write(to: directory.appending(path: "quarantine"))
    let store = DirectorySegmentFiles(directory: directory, inspect: { _ in nil })
    await harness.outbox.sweepOrphans(using: store)
    #expect(await harness.outbox.strayFiles().map(\.url) == [stray])
    #expect(await harness.outbox.strayFiles().first?.byteCount == 11)

    try FileManager.default.removeItem(at: stray)
    #expect(await harness.outbox.strayFiles().isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func aCleanSweepListsNothing() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("half a take".utf8).write(to: directory.appending(path: "\(memo(9).uuidString)-0.m4a"))
    let harness = try await OutboxHarness()

    let report = await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))

    #expect(report.stuck.isEmpty && report.quarantined.count == 1)
    #expect(await harness.outbox.strayFiles().isEmpty)
    await harness.outbox.shutdown()
  }
}
