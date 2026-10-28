import Foundation
import IrisCapture
import IrisCore

/// A voice reply being started: it continues `threadId`, and the memo is created in `mode`.
struct VoiceReplyRequest: Equatable, Sendable {
  let threadId: String
  let mode: MemoMode
}

/// The capture port of the thread screen: one take bound to a thread. Production capture (the outbox, I3) fills it in;
/// until then the app runs on ``FakeVoiceReplyCapture`` under `-IrisFakeCapture` and ``UnavailableVoiceReplyCapture``
/// otherwise.
protocol VoiceReplyCapture {
  /// `false` while nothing can record; the hold-to-talk control is then disabled.
  var isAvailable: Bool { get }
  /// Starts a take for the request.
  func begin(_ request: VoiceReplyRequest) async throws
  /// Ends the take. Cancelled: nothing is sent and `nil` comes back. Otherwise the memo the take became.
  func end(cancelled: Bool) async throws -> Memo?
}

struct UnavailableVoiceReplyCapture: VoiceReplyCapture {
  var isAvailable: Bool { false }
  func begin(_ request: VoiceReplyRequest) async throws {}
  func end(cancelled: Bool) async throws -> Memo? { nil }
}

/// Records silence through `FakeCapture` and creates the voice memo on the API the way the outbox will: no segments,
/// no upload, a memo that continues the thread. Every request is kept for the tests.
final class FakeVoiceReplyCapture: VoiceReplyCapture {
  private(set) var requests: [VoiceReplyRequest] = []
  private let capture: FakeCapture
  private let client: any APIClient
  private let now: () -> Date
  private var take: (request: VoiceReplyRequest, id: MemoID, startedAt: Date)?

  init(capture: FakeCapture, client: any APIClient, now: @escaping () -> Date = { Date() }) {
    self.capture = capture
    self.client = client
    self.now = now
  }

  var isAvailable: Bool { true }

  func begin(_ request: VoiceReplyRequest) async throws {
    requests.append(request)
    let id = try await capture.startTake()
    take = (request, id, now())
  }

  func end(cancelled: Bool) async throws -> Memo? {
    guard let take else { return nil }
    self.take = nil
    try await capture.stopTake()
    guard !cancelled else { return nil }
    return try await client.createMemo(
      CreateMemoRequest(
        id: take.id.uuidString.lowercased(), mode: take.request.mode, startedAt: take.startedAt,
        threadId: take.request.threadId))
  }
}
