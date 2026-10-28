import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("OutboxService")
struct OutboxServiceTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func submission(_ n: UInt8, text: String = "hello", threadId: String? = nil, mode: MemoMode = .auto)
    -> TextSubmission
  {
    TextSubmission(
      id: MemoID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n)), mode: mode, text: text, threadId: threadId,
      startedAt: MemoFactory.now)
  }

  @Test("a text that the server takes comes back as the memo, and the queue stays empty")
  func sent() async throws {
    let rig = OutboxRig(client: client)
    guard case .sent(let memo) = await rig.service.submitText(submission(1)) else {
      Issue.record("expected the memo")
      return
    }
    #expect(memo.transcript == "hello" && memo.isTyped)
    #expect(await rig.service.queuedItems().isEmpty)
  }

  @Test("offline is queued, not lost: the item waits with a retry time and goes out when the clock gets there")
  func offline() async throws {
    let rig = OutboxRig(client: client)
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .createTextMemo)
    #expect(await rig.service.submitText(submission(1, text: "later")) == .queued)

    let queued = await rig.service.queuedItems()
    #expect(queued.count == 1 && queued.first?.title == "later")
    guard case .failed(let retryAt?, _)? = queued.first?.state else {
      Issue.record("expected a failed item with a retry time, got \(String(describing: queued.first?.state))")
      return
    }
    #expect(retryAt == (await rig.clock.now()).addingTimeInterval(2))

    await rig.clock.advance(by: 2)
    #expect(await rig.drain())
    #expect(await client.memos.values.map(\.memo.transcript) == ["later"])
  }

  @Test("retry now sends a queued item before its deadline")
  func retryNow() async throws {
    let rig = OutboxRig(client: client)
    await client.enqueueFailure(.transport(.timedOut), for: .createTextMemo)
    #expect(await rig.service.submitText(submission(1)) == .queued)
    let id = try #require(await rig.service.queuedItems().first?.id)

    await rig.service.retry(id: id)
    #expect(await rig.drain())
    #expect(await client.memos[id] != nil)
  }

  @Test("discard drops the item; the server never sees it")
  func discard() async throws {
    let rig = OutboxRig(client: client)
    await client.enqueueFailure(.transport(.timedOut), for: .createTextMemo)
    #expect(await rig.service.submitText(submission(1)) == .queued)
    let id = try #require(await rig.service.queuedItems().first?.id)

    await rig.service.discard(id: id)
    #expect(await rig.service.queuedItems().isEmpty)
    await rig.clock.advance(by: 600)
    #expect(await client.memos.isEmpty)
  }

  @Test("a refusal a retry cannot change stalls the item with the server's words")
  func refusalStalls() async throws {
    let rig = OutboxRig(client: client)
    // An unknown thread is a 404 on the server: waiting does not help.
    #expect(await rig.service.submitText(submission(1, threadId: "gone", mode: .hermes)) == .queued)

    let item = try #require(await rig.service.queuedItems().first)
    #expect(item.kind == .textReply)
    #expect(item.state == .failed(retryAt: nil, reason: "thread gone not found"))
    await rig.clock.advance(by: 10_000)
    #expect(await client.calls.count == 1, "a stalled item is never retried by itself")
  }

  @Test("the same submission twice is one memo")
  func idempotent() async {
    let rig = OutboxRig(client: client)
    _ = await rig.service.submitText(submission(1))
    _ = await rig.service.submitText(submission(1))
    #expect(await client.memos.count == 1)
    #expect(await client.calls.count == 1)
  }

  @Test("a queue survives a relaunch: a new service over the same store sends what was left")
  func relaunch() async throws {
    let store = InMemoryOutboxStore()
    let clock = ManualClock()
    let first = OutboxRig(client: client, store: store, clock: clock)
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .createTextMemo)
    #expect(await first.service.submitText(submission(1, text: "kept")) == .queued)
    try await first.stack.outbox().shutdown()

    let second = OutboxRig(client: client, store: store, clock: clock)
    #expect(await second.service.queuedItems().map(\.title) == ["kept"])
    await clock.advance(by: 2)
    #expect(await second.drain())
    #expect(await client.memos.values.map(\.memo.transcript) == ["kept"])
  }

  @Test("the queue kinds tell a voice memo, a reply, a typed memo and a chat message apart")
  func kinds() async throws {
    func item(_ kind: OutboxItemKind, mode: String, thread: String?) -> QueuedItem {
      QueuedItem(
        OutboxQueueItem(
          item: OutboxItem(
            memoID: MemoID(), kind: kind, mode: mode, threadID: thread, startedAt: MemoFactory.now,
            queuedAt: MemoFactory.now, title: "t"),
          status: .waiting))
    }
    #expect(item(.voice, mode: "auto", thread: nil).kind == .voiceMemo)
    #expect(item(.voice, mode: "hermes", thread: "t").kind == .voiceReply)
    #expect(item(.text("x"), mode: "auto", thread: nil).kind == .typedMemo)
    #expect(item(.text("x"), mode: "chat", thread: nil).kind == .chatMessage)
    #expect(item(.text("x"), mode: "chat", thread: "t").kind == .textReply)
  }

  @Test("the change stream tells Settings when the queue moves")
  func changes() async throws {
    let rig = OutboxRig(client: client)
    var iterator = await rig.service.changes().makeAsyncIterator()
    await client.enqueueFailure(.transport(.timedOut), for: .createTextMemo)
    _ = await rig.service.submitText(submission(1))
    #expect(await iterator.next() != nil)
  }
}

@Suite("APIOutboxUploader")
struct APIOutboxUploaderTests {
  private func isPermanent(_ error: APIError) -> Bool {
    APIOutboxUploader.classified(error) is PermanentTransferError
  }

  @Test("no network, a wrong token and server trouble are retried")
  func transient() {
    #expect(!isPermanent(.transport(.notConnectedToInternet)))
    #expect(!isPermanent(.unauthorized))
    #expect(!isPermanent(.unexpectedStatus(502)))
    #expect(!isPermanent(.unexpectedStatus(429)))
    #expect(!isPermanent(.decoding("x")))
    #expect(!isPermanent(.server(status: 503, body: ErrorBody(error: .unavailable, message: "down"))))
  }

  @Test("a refusal the server will repeat stalls the item")
  func permanent() {
    #expect(isPermanent(.server(status: 404, body: ErrorBody(error: .notFound, message: "no thread"))))
    #expect(isPermanent(.server(status: 409, body: ErrorBody(error: .conflict, message: "other body"))))
    #expect(isPermanent(.server(status: 400, body: ErrorBody(error: .badRequest, message: "empty"))))
    #expect(isPermanent(.tooLarge(message: "big", maxBytes: 1)))
    #expect(isPermanent(.missingSegments(message: "gone", missing: [1])))
    #expect(isPermanent(.unexpectedStatus(404)))
  }

  @Test("a voice item is created with createMemo, carrying its thread")
  func voiceCreate() async throws {
    let client = FakeAPIClient()
    await client.seed(
      ThreadDetail(
        thread: MemoThread(id: "t", kind: .hermes, title: "T", createdAt: MemoFactory.now, updatedAt: MemoFactory.now),
        memos: [], messages: []))
    let created = CreatedMemoLog()
    let uploader = APIOutboxUploader(client: client, created: created)
    let id = MemoID()
    try await uploader.create(
      OutboxItem(
        memoID: id, kind: .voice, mode: "hermes", threadID: "t", startedAt: MemoFactory.now, queuedAt: MemoFactory.now,
        title: "Voice reply"))

    #expect(
      await client.calls == [
        .createMemo(CreateMemoRequest(id: id.wireID, mode: .hermes, startedAt: MemoFactory.now, threadId: "t"))
      ])
    #expect(await created.memo(id: id.wireID)?.threadId == "t")
  }

  @Test("a segment whose file is gone is a permanent failure")
  func missingFile() async {
    let uploader = APIOutboxUploader(client: FakeAPIClient(), created: CreatedMemoLog())
    let segment = ClosedSegment(
      memoID: MemoID(), index: 0, fileURL: URL(fileURLWithPath: "/nonexistent/0.m4a"), byteCount: 1, duration: 1)
    await #expect(throws: PermanentTransferError.self) { try await uploader.upload(segment) }
  }
}
