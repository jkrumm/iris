import Foundation
import IrisCapture
import IrisCore

extension UUID {
  /// The memo id as the server spells it: lower-case.
  nonisolated var wireID: String { uuidString.lowercased() }
}

/// The outbox's network side over an `APIClient`: the memo is created by id, segments go up by index, `complete` closes the
/// take. Every call is idempotent on the server, so a retry after a lost answer is harmless. A refusal a retry cannot
/// change (a 4xx other than 408 and 429) is thrown as `PermanentTransferError`, which stalls the item for the user to
/// retry or discard. No network, a 5xx, a 408 or a 429 are `TransientTransferError`: retried with backoff for as long as
/// it takes, without using up the outbox's attempts. Anything else (a wrong token the user may still fix, an answer that
/// does not decode, a segment file that cannot be read right now) is retried with backoff too, and stalls after
/// `OutboxPolicy.maxAttempts`.
nonisolated struct APIOutboxUploader: SegmentUploader {
  let client: any APIClient
  let created: CreatedMemoLog
  /// Where a segment goes when the server closed its memo without it (see `upload`); the capture directory's set-aside folder.
  var keeping: (any SegmentFileStore)?
  func create(_ item: OutboxItem) async throws {
    let id = item.memoID.wireID
    let mode = MemoMode(rawValue: item.mode) ?? .auto
    do {
      let memo =
        switch item.kind {
        case .voice:
          try await client.createMemo(
            CreateMemoRequest(id: id, mode: mode, startedAt: item.startedAt, threadId: item.threadID))
        case .text(let text):
          try await client.createTextMemo(
            CreateTextMemoRequest(id: id, mode: mode, startedAt: item.startedAt, text: text, threadId: item.threadID))
        }
      await created.record(memo, serverKey: item.serverKey)
    } catch {
      throw Self.classified(error)
    }
  }

  func upload(_ segment: ClosedSegment) async throws {
    let data: Data
    do {
      data = try Data(contentsOf: segment.fileURL)
    } catch {
      // Only a file that is not there is gone for good. One that exists but cannot be read (data protection before the
      // first unlock, a busy volume) may be readable on the next try, and its own error is the message the queue shows.
      guard !FileManager.default.fileExists(atPath: segment.fileURL.path) else { throw error }
      throw PermanentTransferError("the recording file is gone")
    }
    do {
      try await client.uploadSegment(memoID: segment.memoID.wireID, index: segment.index, data: data)
    } catch let APIError.server(status, body) where status == 409 && body.error == .badState {
      // The memo has left `receiving`. When the server completed it with this segment, the segment is delivered and `complete`
      // then answers with the memo it has. When it completed it with fewer, this file is the only copy of that audio: the
      // outbox makes it its own transcribe memo (`LateTailError`); of a memo the user deleted it is set aside where Settings
      // shows it, never deleted with the rest of the take.
      try await settleClosedMemo(segment, answer: body.message)
    } catch {
      throw Self.classified(error)
    }
  }

  private func settleClosedMemo(_ segment: ClosedSegment, answer: String) async throws {
    let closed: Memo
    do {
      closed = try await client.memo(id: segment.memoID.wireID).memo
    } catch {
      throw Self.classified(error)  // not knowing what the server holds is not an answer: try again later
    }
    guard (closed.segmentCount ?? 0) <= segment.index else { return }
    if !closed.isDeleted { throw LateTailError(answer) }
    guard let keeping, await keeping.setAside(segment.fileURL) != nil else {
      throw PermanentTransferError("the server closed this memo without this recording, which is kept: \(answer)")
    }
  }

  func complete(memoID: MemoID, segmentCount: Int) async throws {
    do {
      _ = try await client.completeMemo(id: memoID.wireID, request: CompleteMemoRequest(segmentCount: segmentCount))
    } catch let APIError.missingSegments(message, missing) {
      // The server holds fewer segments than were sent: the outbox sends the listed ones again (the files are still here).
      throw MissingSegmentsError(indices: missing, message: message)
    } catch {
      throw Self.classified(error)
    }
  }

  /// `DELETE` of a discarded take's memo. Done when the server deleted it, never had it (404) or will not delete it any more
  /// (409 `bad_state`: it left `receiving`, so it is a real memo now); History stops hiding it in every case (`settle`):
  /// the server's list decides from here, which keeps a deleted or purged memo out and shows a 409 one.
  func delete(memoID: MemoID) async throws {
    do {
      _ = try await client.deleteMemo(id: memoID.wireID)
    } catch let APIError.server(status, _) where status == 404 || status == 409 {
      // Final answers: nothing a retry could change.
    } catch {
      throw Self.classified(error)
    }
    await created.settle(memoID.wireID)
  }

  static func classified(_ error: any Error) -> any Error {
    guard let api = error as? APIError else { return error }
    switch api {
    case .unauthorized, .decoding: return api
    case .transport: return TransientTransferError(String(describing: api))
    case .server(let status, let body):
      return isTransient(status) ? TransientTransferError(body.message) : PermanentTransferError(body.message)
    case .unexpectedStatus(let status):
      return isTransient(status) ? TransientTransferError("HTTP \(status)") : PermanentTransferError("HTTP \(status)")
    // `complete` turns `missingSegments` into a retry itself; anywhere else it is a refusal.
    case .missingSegments(let message, _), .tooLarge(let message, _): return PermanentTransferError(message)
    case .notScripted(let call): return PermanentTransferError("not scripted: \(call)")
    }
  }

  private static func isTransient(_ status: Int) -> Bool {
    status == 408 || status == 429 || status >= 500
  }
}
