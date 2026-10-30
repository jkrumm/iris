import Foundation
import Testing

@testable import IrisCapture

/// A queue file written before `completeMayHaveLanded` has no flag. Reading its absence as "never sent" let a tail grow a memo
/// whose `complete` had reached the server; only a completion that was never handed out is known not to have.
struct LegacyMemoRecordTests {
  /// What an older build wrote: the memo without the flag.
  private func legacyDecoded(_ completion: OutboxState, attempts: Int) throws -> OutboxMemo {
    let current = OutboxMemo(memoID: memo(1), segmentCount: 2, completion: completion, attempts: attempts)
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
    #expect(object["completeMayHaveLanded"] != nil, "the current build always writes the flag")
    object["completeMayHaveLanded"] = nil
    return try JSONDecoder().decode(OutboxMemo.self, from: JSONSerialization.data(withJSONObject: object))
  }

  @Test func aCompletionThatWasNeverHandedOutIsKnownNotToHaveLanded() throws {
    #expect(try legacyDecoded(.pending, attempts: 0).completeMayHaveLanded == false)
  }

  @Test(arguments: [
    (OutboxState.pending, 3), (.uploading, 0), (.failed(retryAt: Date(timeIntervalSince1970: 5)), 1), (.stalled, 10),
    (.uploaded, 0),
  ])
  func anyOtherStateMayHaveReachedTheServer(completion: OutboxState, attempts: Int) throws {
    #expect(try legacyDecoded(completion, attempts: attempts).completeMayHaveLanded == true)
  }

  @Test func theFlagItselfRoundTrips() throws {
    var current = OutboxMemo(memoID: memo(1), segmentCount: 2, completion: .pending, attempts: 0)
    #expect(
      try JSONDecoder().decode(OutboxMemo.self, from: JSONEncoder().encode(current)).completeMayHaveLanded == false)
    current.completeMayHaveLanded = true
    #expect(
      try JSONDecoder().decode(OutboxMemo.self, from: JSONEncoder().encode(current)).completeMayHaveLanded == true)
  }

  @Test func aTailOfALegacyMemoWithAFailedCompleteIsSetAsideNotGrownInto() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = memo(1)
    var item = voiceItem(id)
    item.create = .uploaded
    item.createMayHaveLanded = true
    let present = (0..<2).map { directory.appending(path: "\(id.uuidString)-\($0).m4a") }
    for url in present { try Data("audio".utf8).write(to: url) }
    let tail = directory.appending(path: "\(id.uuidString)-2.m4a")
    try Data("audio".utf8).write(to: tail)
    let entries = present.enumerated().map { index, url in
      OutboxEntry(
        segment: ClosedSegment(memoID: id, index: index, fileURL: url, byteCount: 5, duration: 10), sequence: index,
        state: .uploaded, attempts: 0)
    }
    let legacy = try legacyDecoded(.failed(retryAt: Date(timeIntervalSince1970: 5)), attempts: 1)
    let harness = try await OutboxHarness(
      record: OutboxRecord(entries: entries, memos: [legacy], items: [item], nextSequence: 2))

    let report = await harness.outbox.sweepOrphans(
      using: DirectorySegmentFiles(directory: directory, inspect: { _ in (5, 10) }))

    #expect(report.adopted.isEmpty && report.quarantined.count == 1, "the server may hold the memo closed at two")
    #expect(await harness.outbox.memos().first?.segmentCount == 2)
    await harness.outbox.shutdown()
  }
}
