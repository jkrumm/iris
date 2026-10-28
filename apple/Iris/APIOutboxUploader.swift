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
/// retry or discard; everything else (no network, a 5xx, a wrong token the user may still fix) is retried with backoff.
nonisolated struct APIOutboxUploader: SegmentUploader {
  let client: any APIClient
  let created: CreatedMemoLog

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
      await created.record(memo)
    } catch {
      throw Self.classified(error)
    }
  }

  func upload(_ segment: ClosedSegment) async throws {
    let data: Data
    do {
      data = try Data(contentsOf: segment.fileURL)
    } catch {
      throw PermanentTransferError("the recording file is gone")
    }
    do {
      try await client.uploadSegment(memoID: segment.memoID.wireID, index: segment.index, data: data)
    } catch {
      throw Self.classified(error)
    }
  }

  func complete(memoID: MemoID, segmentCount: Int) async throws {
    do {
      _ = try await client.completeMemo(id: memoID.wireID, request: CompleteMemoRequest(segmentCount: segmentCount))
    } catch {
      throw Self.classified(error)
    }
  }

  static func classified(_ error: any Error) -> any Error {
    guard let api = error as? APIError else { return error }
    switch api {
    case .unauthorized, .transport, .decoding: return api
    case .server(let status, let body): return isTransient(status) ? api : PermanentTransferError(body.message)
    case .unexpectedStatus(let status): return isTransient(status) ? api : PermanentTransferError("HTTP \(status)")
    case .missingSegments(let message, _), .tooLarge(let message, _): return PermanentTransferError(message)
    case .notScripted(let call): return PermanentTransferError("not scripted: \(call)")
    }
  }

  private static func isTransient(_ status: Int) -> Bool {
    status == 408 || status == 429 || status >= 500
  }
}
