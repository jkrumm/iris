import Foundation
import Testing

@testable import IrisCapture

/// What a take leaves behind when it is dropped or fails on its own.
struct TakeCleanupTests {
  private let request = TakeRequest(mode: "auto", title: "Voice memo")

  private func touch(_ name: String, in directory: URL) -> URL {
    let url = directory.appending(path: name)
    FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3]))
    return url
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  @Test func discardFilesRemovesTheFilesOfOneMemoOnly() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let mine = [
      touch("\(memo(1).uuidString)-0.m4a", in: directory), touch("\(memo(1).uuidString)-4.m4a", in: directory),
    ]
    let others = [touch("\(memo(2).uuidString)-0.m4a", in: directory), touch("notes.txt", in: directory)]

    await DirectorySegmentFiles(directory: directory).discardFiles(of: memo(1))

    #expect(mine.allSatisfy { !exists($0) })
    #expect(others.allSatisfy { exists($0) })
  }

  @Test func aCancelledTakeLeavesNoFileBehindEvenForASegmentThatNeverClosed() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: fake.recorder, outbox: harness.outbox, clock: harness.clock,
      files: DirectorySegmentFiles(directory: directory))
    let id = try await session.start(request)
    await fake.recorder.feed(frames: 12 * SegmentRotationPolicy().sampleRate)
    // The files a failed close leaves: the segment that did not close, and the one the closer held back behind it.
    let stranded = [touch("\(id.uuidString)-1.m4a", in: directory), touch("\(id.uuidString)-2.m4a", in: directory)]
    let otherTake = touch("\(memo(9).uuidString)-0.m4a", in: directory)

    #expect(await session.cancel() == id)

    #expect(stranded.allSatisfy { !exists($0) }, "the user dropped the take: nothing of it stays on disk")
    #expect(exists(otherTake), "another take's file is not touched")
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aTakeThatIsStoppedKeepsEveryFile() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness(deletesFilesWhenDone: false)
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: fake.recorder, outbox: harness.outbox, clock: harness.clock,
      files: DirectorySegmentFiles(directory: directory))
    let id = try await session.start(request)
    await fake.recorder.feed(frames: 12 * SegmentRotationPolicy().sampleRate)
    let stranded = touch("\(id.uuidString)-5.m4a", in: directory)

    _ = try await session.stop()

    #expect(exists(stranded), "a take that is sent never loses a file to a cleanup")
    await session.shutdown()
    await harness.outbox.shutdown()
  }
}
