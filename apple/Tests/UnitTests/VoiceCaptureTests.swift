import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("Voice capture through the outbox")
struct VoiceCaptureTests {
  let client = FakeAPIClient(now: { MemoFactory.now })
  let request = VoiceReplyRequest(threadId: "t", mode: .hermes)

  private func seedThread() async {
    await client.seed(
      ThreadDetail(
        thread: MemoThread(id: "t", kind: .hermes, title: "T", createdAt: MemoFactory.now, updatedAt: MemoFactory.now),
        memos: [], messages: []))
  }

  @Test("a take creates the memo, uploads its segments and completes it")
  func take() async throws {
    await seedThread()
    let rig = OutboxRig(client: client)
    let voice = rig.voice(seconds: 12)
    try await voice.begin(request)
    guard case .sent(let memo) = try await voice.end(cancelled: false) else {
      Issue.record("expected the memo")
      return
    }
    #expect(memo.threadId == "t" && memo.mode == .hermes)

    #expect(await rig.drain())
    let id = memo.id
    #expect(await client.segments[id]?.keys.sorted() == [0, 1])
    #expect(await client.memos[id]?.memo.state == .received)
    #expect(await client.memos[id]?.memo.segmentCount == 2)
  }

  @Test("a take without a connection is queued, and everything goes up once it is back")
  func offlineTake() async throws {
    await seedThread()
    let rig = OutboxRig(client: client)
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .createMemo)
    let voice = rig.voice(seconds: 3)
    try await voice.begin(request)
    #expect(try await voice.end(cancelled: false) == .queued)
    let item = try #require(await rig.service.queuedItems().first)
    #expect(item.kind == .voiceReply)

    await rig.clock.advance(by: 2)
    #expect(await rig.drain())
    #expect(await client.memos[item.id]?.memo.state == .received)
  }

  @Test("a cancelled take sends nothing and leaves nothing in the queue")
  func cancelled() async throws {
    await seedThread()
    let rig = OutboxRig(client: client)
    let voice = rig.voice(seconds: 3)
    try await voice.begin(request)
    #expect(try await voice.end(cancelled: true) == .discarded)
    #expect(await client.calls.isEmpty)
    #expect(await rig.service.queuedItems().isEmpty)
  }

  @Test("a take that heard nothing is dropped")
  func silent() async throws {
    await seedThread()
    let rig = OutboxRig(client: client)
    let voice = rig.voice(seconds: 0)
    try await voice.begin(request)
    #expect(try await voice.end(cancelled: false) == .discarded)
    #expect(await client.calls.isEmpty)
  }

  @Test("a denied microphone fails the start")
  func denied() async {
    let rig = OutboxRig(client: client)
    let voice = OutboxVoiceReplyCapture(stack: rig.stack, service: rig.service, requestPermission: { false })
    await #expect(throws: CaptureError.self) { try await voice.begin(request) }
  }
}
