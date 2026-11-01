import Foundation
import IrisCapture
import IrisCore
import Synchronization
import Testing

@testable import Iris

/// Wave 19 I1: outbox work stays bound to the server it was queued for across a connection switch, and History does not merge
/// an answer or a created memo of the server it just left.
@MainActor
@Suite("Server-bound outbox")
struct ServerBoundOutboxTests {
  private let serverA = ConnectionCredentials(urlText: "https://a.example.com", token: "token-a")!
  private let serverB = ConnectionCredentials(urlText: "https://b.example.com", token: "token-b")!
  private let fakeA = FakeAPIClient(now: { MemoFactory.now })
  private let fakeB = FakeAPIClient(now: { MemoFactory.now })

  private func client(startingOn credentials: ConnectionCredentials) -> ReconfigurableAPIClient {
    let (fakeA, fakeB, serverA) = (fakeA, fakeB, serverA)
    return ReconfigurableAPIClient(
      credentials: credentials,
      makeClient: { $0.serverURL == serverA.serverURL ? fakeA : fakeB })
  }

  private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  private func createCalls(_ fake: FakeAPIClient) async -> Int {
    await fake.calls.count { if case .createTextMemo = $0 { true } else { false } }
  }

  // MARK: The client checks the server at the moment it picks its target

  @Test("a call made for an item of another server is refused, one for its own or for no item goes through")
  func clientChecksTheServer() async throws {
    let client = client(startingOn: serverA)
    #expect(client.serverKey == serverA.serverKey)

    _ = try await OutboxTransfer.$serverKey.withValue(serverA.serverKey) { try await client.health() }
    _ = try await client.health()
    await #expect(throws: WrongServerError.self) {
      _ = try await OutboxTransfer.$serverKey.withValue(serverB.serverKey) { try await client.health() }
    }
    #expect(await fakeB.calls.isEmpty, "nothing reached the other server")

    client.reconfigure(nil)
    await #expect(throws: WrongServerError.self) {
      _ = try await OutboxTransfer.$serverKey.withValue(serverA.serverKey) { try await client.health() }
    }
  }

  // MARK: A queued memo waits for its server

  @Test("a typed memo queued for A is not sent to B after a switch, and goes to A when A is configured again")
  func queuedItemWaitsForItsServer() async throws {
    let client = client(startingOn: serverA)
    let created = CreatedMemoLog()
    let capture = FakeCapture(
      directory: FileManager.default.temporaryDirectory.appending(path: "iris-unit-\(UUID().uuidString)"))
    let clock = ManualClock()
    let stack = CaptureStack(
      .init(
        session: capture.session, routes: capture.routes, recorder: capture.recorder, clock: clock,
        store: InMemoryOutboxStore(), uploader: APIOutboxUploader(client: client, created: created),
        policy: OutboxPolicy(jitter: { 0 }), serverKey: { client.serverKey }))
    let service = OutboxService(stack: stack, created: created, now: { MemoFactory.now })
    await fakeA.enqueueFailure(.transport(.notConnectedToInternet), for: .createTextMemo)

    let outcome = await service.submitText(
      TextSubmission(id: MemoID(), mode: .auto, text: "for A", threadId: nil, startedAt: MemoFactory.now),
      window: .milliseconds(200))
    #expect(outcome == .queued)
    #expect(await createCalls(fakeA) == 1)

    client.reconfigure(serverB)
    await clock.advance(by: 600)
    await service.resume()
    try await stack.outbox().settled()
    #expect(await createCalls(fakeB) == 0, "A's memo never reaches B")
    #expect(await service.queuedItems().count == 1, "and waits in the queue, visible")

    client.reconfigure(serverA)
    await service.resume()
    #expect(await waitFor { await createCalls(fakeA) == 2 })
    #expect(await waitFor { await service.queuedItems().isEmpty })
    #expect(await createCalls(fakeB) == 0)
  }

  @Test("the memo the outbox created is recorded with the server it was created on")
  func createdMemoCarriesItsServer() async throws {
    let created = CreatedMemoLog()
    let seen = Mutex<[String?]>([])
    await created.setServerHandler { _, server in seen.withLock { $0.append(server) } }
    let uploader = APIOutboxUploader(client: fakeA, created: created)
    var item = OutboxItem(
      memoID: MemoID(), kind: .text("hi"), mode: "auto", startedAt: MemoFactory.now, queuedAt: MemoFactory.now,
      title: "hi")
    item.serverKey = serverA.serverKey

    try await uploader.create(item)

    #expect(seen.withLock { $0 } == [serverA.serverKey])
  }

  // MARK: History

  /// A History whose server follows `key`.
  private final class Switchable: Sendable {
    private let key: Mutex<String?>
    init(_ key: String?) { self.key = Mutex(key) }
    var current: String? { key.withLock { $0 } }
    func switchTo(_ key: String?) { self.key.withLock { $0 = key } }
  }

  @Test("a memo created on the server History just left is not inserted into the new server's list")
  func staleCreatedMemoIsDropped() {
    let server = Switchable(serverA.serverKey)
    let history = HistoryModel(client: fakeA, serverKey: { server.current })
    server.switchTo(serverB.serverKey)  // the hand-off was buffered across the switch

    history.insert(MemoFactory.memo("from-a"), origin: serverA.serverKey)
    #expect(history.memos.isEmpty)

    history.insert(MemoFactory.memo("from-b"), origin: serverB.serverKey)
    history.insert(MemoFactory.memo("unbound"), origin: nil)
    #expect(Set(history.memos.map(\.id)) == ["from-b", "unbound"])
  }

  @Test("a first page that was asked of A and answers after the switch to B is not merged into B's list")
  func staleReconciliationIsDropped() async {
    let server = Switchable(serverA.serverKey)
    let history = HistoryModel(client: fakeA, serverKey: { server.current })
    await fakeA.seed(MemoFactory.detail(MemoFactory.memo("only-on-a")))
    let gate = await fakeA.hold(.listMemos)

    let loading = Task { await history.load() }
    await gate.waitUntilHeld()
    server.switchTo(serverB.serverKey)
    gate.release()
    await loading.value

    #expect(history.memos.isEmpty, "A's rows do not appear in B's list")
    #expect(!history.hasLoaded)
    #expect(!history.isLoading)
  }

  @Test("the rows of the old server are gone while the new server's first page is on its way")
  func rowsOfTheOldServerAreDropped() async {
    let server = Switchable(serverA.serverKey)
    let history = HistoryModel(client: fakeA, serverKey: { server.current })
    await fakeA.seed(MemoFactory.detail(MemoFactory.memo("on-a")))
    await history.load()
    #expect(history.memos.map(\.id) == ["on-a"])

    server.switchTo(serverB.serverKey)
    let gate = await fakeA.hold(.listMemos)
    let loading = Task { await history.load() }
    await gate.waitUntilHeld()
    #expect(history.memos.isEmpty)
    gate.release()
    await loading.value
  }

  @Test("an event refresh that was asked of A and answers after the switch changes nothing in B's list")
  func staleRefreshIsDropped() async {
    let server = Switchable(serverA.serverKey)
    let history = HistoryModel(client: fakeA, serverKey: { server.current })
    let memo = MemoFactory.memo("on-both")
    await fakeA.seed(MemoFactory.detail(memo))
    let gate = await fakeA.hold(.memo)

    let handling = Task {
      await history.handle(.memoUpdated(MemoEvent(id: memo.id, state: .received, at: MemoFactory.now)))
    }
    await gate.waitUntilHeld()
    server.switchTo(serverB.serverKey)
    gate.release()
    await handling.value

    #expect(history.memos.isEmpty)
  }
}
