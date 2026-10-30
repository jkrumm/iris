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
    let outcome = await rig.service.submitText(submission(1, threadId: "gone", mode: .hermes))
    #expect(outcome == .stalled(reason: "thread gone not found"), "not 'queued': it will never be sent by itself")

    // The refused text stays with the caller, so the stalled item does not stay behind to be sent twice.
    #expect(await rig.service.queuedItems().isEmpty)
    await rig.clock.advance(by: 10_000)
    #expect(await client.calls.count == 1, "a stalled item is never retried by itself")
  }

  @Test("a stalled item a voice take left in the queue stays there for Retry and Discard")
  func stalledTakeStays() async throws {
    let rig = OutboxRig(client: client)
    let voice = rig.voice()
    try await voice.begin(VoiceReplyRequest(threadId: "gone", mode: .hermes))
    #expect(try await voice.end(cancelled: false) == .queued)
    let item = try #require(await rig.service.queuedItems().first)
    #expect(item.state == .failed(retryAt: nil, reason: "thread gone not found"))
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

  @Test("segments the server already has for a completed memo are delivered on its 409, and the queue clears")
  func completedMemoClearsTheQueue() async throws {
    let id = MemoID()
    let wire = id.wireID
    // The server has the whole take and has completed it (the audio was sent by hand, or the answers were lost).
    _ = try await client.createMemo(CreateMemoRequest(id: wire, mode: .auto, startedAt: MemoFactory.now))
    for index in 0..<3 { try await client.uploadSegment(memoID: wire, index: index, data: Data("audio".utf8)) }
    _ = try await client.completeMemo(id: wire, request: CompleteMemoRequest(segmentCount: 3))
    let uploadsBefore = await client.calls.count
    for _ in 0..<3 {
      await client.enqueueFailure(
        .server(status: 409, body: ErrorBody(error: .badState, message: "memo is received, no longer receiving")),
        for: .uploadSegment)
    }

    // The phone's queue: the take is created, its three segments and its `complete` are still waiting.
    let directory = FileManager.default.temporaryDirectory.appending(path: "iris-unit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var item = OutboxItem(
      memoID: id, kind: .voice, mode: "auto", startedAt: MemoFactory.now, queuedAt: MemoFactory.now, title: "Voice memo"
    )
    item.create = .uploaded
    var machine = OutboxStateMachine()
    machine.enqueueItem(item)
    for index in 0..<3 {
      let url = directory.appending(path: "\(index).m4a")
      try Data("audio".utf8).write(to: url)
      machine.enqueue(ClosedSegment(memoID: id, index: index, fileURL: url, byteCount: 5, duration: 1))
    }
    machine.finishMemo(id, segmentCount: 3)
    let rig = OutboxRig(client: client, store: InMemoryOutboxStore(record: machine.record))

    #expect(await rig.drain())
    let outbox = try await rig.stack.outbox()
    #expect(await outbox.entries().isEmpty)
    #expect(await outbox.items().isEmpty)
    #expect(await outbox.memos().isEmpty)
    #expect(await rig.service.queuedItems().isEmpty, "no failed row, no error")
    let calls = await client.calls.dropFirst(uploadsBefore)
    #expect(
      calls.filter { if case .uploadSegment = $0 { true } else { false } }.count == 3, "each segment once, no loop")
    #expect(calls.last == .completeMemo(id: wire, request: CompleteMemoRequest(segmentCount: 3)))
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

  /// A server that completed the memo with `held` segments (none: the memo still receives), and one segment file on disk.
  private struct ClosedMemo {
    let client = FakeAPIClient(now: { MemoFactory.now })
    let directory = FileManager.default.temporaryDirectory.appending(path: "iris-unit-\(UUID().uuidString)")
    let id = MemoID()
    let file: URL

    init(held: Int) async throws {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      file = directory.appending(path: "\(id.uuidString)-2.m4a")
      try Data("audio".utf8).write(to: file)
      _ = try await client.createMemo(CreateMemoRequest(id: id.wireID, mode: .auto, startedAt: MemoFactory.now))
      for index in 0..<held { try await client.uploadSegment(memoID: id.wireID, index: index, data: Data("x".utf8)) }
      if held > 0 { _ = try await client.completeMemo(id: id.wireID, request: CompleteMemoRequest(segmentCount: held)) }
      await client.enqueueFailure(
        .server(status: 409, body: ErrorBody(error: .badState, message: "no longer receiving")), for: .uploadSegment)
    }

    var segment: ClosedSegment { ClosedSegment(memoID: id, index: 2, fileURL: file, byteCount: 5, duration: 1) }
    var uploader: APIOutboxUploader { APIOutboxUploader(client: client, created: CreatedMemoLog()) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
  }

  @Test("a segment the server has for a completed memo is delivered and its file is left to the queue")
  func segmentTheServerHolds() async throws {
    let memo = try await ClosedMemo(held: 3)
    defer { memo.remove() }
    try await memo.uploader.upload(memo.segment)
    #expect(FileManager.default.fileExists(atPath: memo.file.path))
  }

  @Test(
    "a segment the server's completed memo lacks is a late tail: the uploader hands it to the outbox, file untouched")
  func segmentTheServerLacks() async throws {
    let memo = try await ClosedMemo(held: 1)
    defer { memo.remove() }
    await #expect(throws: LateSegmentError.self) { try await memo.uploader.upload(memo.segment) }
    #expect(try Data(contentsOf: memo.file) == Data("audio".utf8))
  }

  @Test("a memo that never received a segment is the same: a late tail")
  func segmentOfAMemoWithNone() async throws {
    let memo = try await ClosedMemo(held: 0)
    defer { memo.remove() }
    await #expect(throws: LateSegmentError.self) { try await memo.uploader.upload(memo.segment) }
  }

  @Test("a deleted memo also answers 409: its segment is dropped, never turned into a late-tail memo")
  func segmentOfADeletedMemo() async throws {
    let memo = try await ClosedMemo(held: 0)
    defer { memo.remove() }
    _ = try await memo.client.deleteMemo(id: memo.id.wireID)

    try await memo.uploader.upload(memo.segment)  // returns: the entry clears, nothing is queued

    let created = CreatedMemoLog()
    let outbox = try await Outbox(
      store: InMemoryOutboxStore(), uploader: APIOutboxUploader(client: memo.client, created: created),
      clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
    await memo.client.enqueueFailure(
      .server(status: 409, body: ErrorBody(error: .badState, message: "memo is deleted")), for: .uploadSegment)
    try await outbox.enqueueItem(
      OutboxItem(
        memoID: memo.id, kind: .voice, mode: "auto", startedAt: MemoFactory.now, queuedAt: MemoFactory.now,
        title: "Voice memo"))
    await outbox.enqueue(memo.segment)
    await outbox.settled()
    let makes = await memo.client.calls.filter {
      if case .createMemo(let request) = $0 { request.mode == .transcribe } else { false }
    }
    #expect(makes.isEmpty)
    await outbox.shutdown()
  }

  @Test("when the server cannot be asked what it holds, nothing is decided: retried later, file untouched")
  func segmentLookupFails() async throws {
    let memo = try await ClosedMemo(held: 1)
    defer { memo.remove() }
    await memo.client.enqueueFailure(.transport(.notConnectedToInternet), for: .memo)
    await #expect(throws: TransientTransferError.self) { try await memo.uploader.upload(memo.segment) }
    #expect(FileManager.default.fileExists(atPath: memo.file.path))
  }

  @Test(
    "through the outbox a late tail is created on the server as its own transcribe memo, and the take is left alone")
  func lateTailThroughTheOutbox() async throws {
    let memo = try await ClosedMemo(held: 1)
    defer { memo.remove() }
    let created = CreatedMemoLog()
    let outbox = try await Outbox(
      store: InMemoryOutboxStore(), uploader: APIOutboxUploader(client: memo.client, created: created),
      clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))

    try await outbox.enqueueItem(
      OutboxItem(
        memoID: memo.id, kind: .voice, mode: "auto", startedAt: MemoFactory.now, queuedAt: MemoFactory.now,
        title: "Voice memo"))
    // The server holds segment 0 and completed the memo; the take's segment 1 arrives late and is refused.
    let late = ClosedSegment(memoID: memo.id, index: 1, fileURL: memo.file, byteCount: 5, duration: 1)
    await outbox.enqueue(late)
    await outbox.settled()
    let first = directoryFile(memo, "0")
    await outbox.enqueue(ClosedSegment(memoID: memo.id, index: 0, fileURL: first, byteCount: 1, duration: 1))
    await outbox.finishMemo(memo.id, segmentCount: 2)
    await outbox.settled()

    let calls = await memo.client.calls
    let makes = calls.compactMap { call -> CreateMemoRequest? in
      guard case .createMemo(let request) = call, request.mode == .transcribe else { return nil }
      return request
    }
    let tail = try #require(makes.first)
    #expect(makes.count == 1 && tail.threadId == nil && tail.id != memo.id.wireID)
    #expect(calls.contains(.uploadSegment(memoID: tail.id, index: 0, byteCount: 5)))
    #expect(calls.contains(.completeMemo(id: tail.id, request: CompleteMemoRequest(segmentCount: 1))))
    #expect(await created.memo(id: tail.id)?.mode == .transcribe)
    let detail = try await memo.client.memo(id: tail.id)
    #expect(detail.memo.segmentCount == 1)
    #expect(
      calls.contains(.completeMemo(id: memo.id.wireID, request: CompleteMemoRequest(segmentCount: 1))),
      "the take is completed with what the server holds, so the server does not refuse it")
    #expect(await outbox.queue().isEmpty, "the take clears too, nothing stalls")
    await outbox.shutdown()
  }

  @Test("a segment whose bytes differ from the server's stays a refusal")
  func segmentConflict() async throws {
    let client = FakeAPIClient()
    await client.enqueueFailure(
      .server(status: 409, body: ErrorBody(error: .conflict, message: "other bytes")), for: .uploadSegment)
    let file = FileManager.default.temporaryDirectory.appending(path: "iris-unit-\(UUID().uuidString).m4a")
    try Data("audio".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    await #expect(throws: PermanentTransferError.self) {
      try await APIOutboxUploader(client: client, created: CreatedMemoLog()).upload(
        ClosedSegment(memoID: MemoID(), index: 0, fileURL: file, byteCount: 5, duration: 1))
    }
  }

  @Test("a segment whose file is gone is a permanent failure")
  func missingFile() async {
    let uploader = APIOutboxUploader(client: FakeAPIClient(), created: CreatedMemoLog())
    let segment = ClosedSegment(
      memoID: MemoID(), index: 0, fileURL: URL(fileURLWithPath: "/nonexistent/0.m4a"), byteCount: 1, duration: 1)
    await #expect(throws: PermanentTransferError.self) { try await uploader.upload(segment) }
  }
}
