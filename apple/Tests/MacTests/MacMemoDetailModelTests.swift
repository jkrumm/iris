import Foundation
import IrisCore
import Synchronization
import Testing

@testable import IrisMac

private final class RecordingPasteboard: Pasteboard {
  private let copies = Mutex<[String]>([])
  var last: String? { copies.withLock { $0.last } }
  func copy(_ text: String) { copies.withLock { $0.append(text) } }
}

@MainActor
@Suite("Mac memo detail model")
struct MacMemoDetailModelTests {
  private static let finished = "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34"

  private func model(
    pasteboard: RecordingPasteboard = RecordingPasteboard(), known: Bool = true
  ) async -> MacMemoDetailModel {
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let memo = known ? try? await api.memo(id: Self.finished).memo : nil
    return MacMemoDetailModel(
      memoID: Self.finished, memo: memo, client: api, pasteboard: pasteboard, copiedDuration: .milliseconds(30))
  }

  @Test("a memo the list does not hold arrives with the first load, with its steps")
  func loads() async {
    let model = await model(known: false)
    #expect(model.memo == nil && model.rows(now: .now).isEmpty)
    await model.load()
    #expect(model.memo?.id == Self.finished && !model.rows(now: .now).isEmpty && !model.loadFailed)
    #expect(model.totalValue(now: .now) != nil)
  }

  @Test("a memo that cannot be loaded says so and keeps nothing")
  func loadFails() async {
    let model = MacMemoDetailModel(
      memoID: "missing", client: FakeAPIClient(), pasteboard: RecordingPasteboard())
    await model.load()
    #expect(model.memo == nil && model.loadFailed)
  }

  @Test("Copy puts the plain transcript or reply on the pasteboard and shows Copied until the timer ends")
  func copies() async {
    let pasteboard = RecordingPasteboard()
    let model = await model(pasteboard: pasteboard)
    model.copy(.transcript)
    #expect(pasteboard.last == model.memo?.plainTranscript && model.copied == .transcript)
    model.copy(.reply)
    #expect(pasteboard.last == model.memo?.plainReply && model.copied == .reply)
    #expect(await eventually { model.copied == nil })
  }

  @Test("a finished memo has nothing to retry; the waterfall starts collapsed")
  func finishedMemo() async {
    let model = await model()
    await model.load()
    #expect(model.retrySteps.isEmpty && !model.isWaterfallExpanded)
    model.isWaterfallExpanded = true
    #expect(model.isWaterfallExpanded)
  }

  @Test(
    "a memo failed at act offers a retry from there; the retry restarts it and the waterfall opens on its own")
  func retries() async {
    let failedID = "9e2c4b70-1a58-4d36-8f07-5b3a6d1c8e24"
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let model = MacMemoDetailModel(memoID: failedID, client: api, pasteboard: RecordingPasteboard())
    await model.load()
    #expect(model.isWaterfallExpanded)
    #expect(model.retrySteps.last == .act)
    await model.retry(from: .act)
    #expect(model.failure == nil && !model.isRetrying)
    #expect(model.memo?.state != .failed)
    #expect(model.retrySteps.isEmpty)
  }

  @Test("a load that a retry's load overtook cannot put the older memo back")
  func supersededLoadIsDropped() async throws {
    let failedID = "9e2c4b70-1a58-4d36-8f07-5b3a6d1c8e24"
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let model = MacMemoDetailModel(memoID: failedID, client: api, pasteboard: RecordingPasteboard())
    await model.load()
    #expect(model.memo?.state == .failed)

    // An event-triggered load starts first and is slow: it reads the failed memo, then waits.
    let gate = await api.hold(.memo)
    let slow = Task { await model.load() }
    await gate.waitUntilHeld()
    // The retry restarts the memo; its own load answers at once.
    await model.retry(from: .act)
    #expect(model.memo?.state != .failed)
    gate.release()
    await slow.value
    #expect(model.memo?.state != .failed, "the overtaken load put the failed memo back")
  }

  @Test("a chat memo loads its conversation, read only; a plain memo has none")
  func loadsThread() async throws {
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let chat = MacMemoDetailModel(
      memoID: SampleData.chatFollowUpID, client: api, pasteboard: RecordingPasteboard())
    await chat.load()
    #expect(chat.memo?.continuesThread == true)
    let thread = try #require(chat.thread)
    #expect(thread.messages.contains { $0.role == .user } && thread.messages.contains { $0.role == .assistant })
    let plain = MacMemoDetailModel(
      memoID: "e8b3d2f0-4a17-4c59-8d60-1b7f3a9e5c24", client: api, pasteboard: RecordingPasteboard())
    await plain.load()
    #expect(plain.thread == nil)
  }

  @Test("a conversation that cannot be read is reported, not left loading; a later success clears it")
  func threadFailure() async {
    let api = FakeAPIClient()
    await SampleData.seed(api)
    await api.enqueueFailure(.transport(.notConnectedToInternet), for: .thread)
    let chat = MacMemoDetailModel(
      memoID: SampleData.chatFollowUpID, client: api, pasteboard: RecordingPasteboard())
    await chat.load()
    #expect(chat.memo?.continuesThread == true && chat.thread == nil && chat.threadFailed)
    await chat.load()
    #expect(chat.thread != nil && !chat.threadFailed)
  }

  @Test("a memo in a Hermes session is a chat from the list's copy; its turns come from the thread once it has loaded")
  func chatTurns() async {
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let memo = try? await api.memo(id: SampleData.chatFollowUpID).memo
    let chat = MacMemoDetailModel(
      memoID: SampleData.chatFollowUpID, memo: memo, client: api, pasteboard: RecordingPasteboard())
    #expect(chat.isChat && chat.thread == nil)
    #expect(chat.turns.map(\.id) == ["\(SampleData.chatFollowUpID).user", "\(SampleData.chatFollowUpID).reply"])
    await chat.load()
    #expect(chat.thread != nil && chat.turns.count == 4, "the first question and answer join the follow-up")
  }

  @Test("a memo alone in its session whose thread cannot be read still shows its own turns")
  func ownSessionWithoutThread() async {
    let api = FakeAPIClient()
    await SampleData.seed(api)
    await api.enqueueFailure(.transport(.notConnectedToInternet), for: .thread)
    let memo = try? await api.memo(id: Self.finished).memo
    let model = MacMemoDetailModel(
      memoID: Self.finished, memo: memo, client: api, pasteboard: RecordingPasteboard())
    #expect(model.memo?.threadId == Self.finished && model.isChat)
    await model.load()
    #expect(model.thread == nil && model.threadFailed && !model.continuesThread)
    #expect(model.turns.map(\.id) == ["\(Self.finished).user", "\(Self.finished).reply"])
  }

  @Test("every Hermes memo is a chat, also one that failed before act; a transcript stays a document")
  func chatsAndDocuments() async {
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let failedAtAct = MacMemoDetailModel(
      memoID: "9e2c4b70-1a58-4d36-8f07-5b3a6d1c8e24", client: api, pasteboard: RecordingPasteboard())
    await failedAtAct.load()
    #expect(failedAtAct.memo != nil && failedAtAct.isChat)
    let transcript = MacMemoDetailModel(
      memoID: "e8b3d2f0-4a17-4c59-8d60-1b7f3a9e5c24", client: api, pasteboard: RecordingPasteboard())
    await transcript.load()
    #expect(transcript.memo != nil && !transcript.isChat)
  }

  @Test("a running turn is a pending bubble; a reply sent from this Mac shows at once and keeps the chat")
  func runningAndSent() async throws {
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let model = MacMemoDetailModel(
      memoID: SampleData.hermesFollowUpID, client: api, pasteboard: RecordingPasteboard())
    await model.load()
    let thread = try #require(model.thread)
    #expect(model.isChat && model.turns.last?.id == "\(SampleData.hermesFollowUpID).pending")
    let sent = Memo(
      id: "sent-1", mode: .hermes, device: "mac", startedAt: .now, state: .transcribed, transcript: "And then?",
      threadId: thread.id, isTyped: true, createdAt: .now, updatedAt: .now)
    model.didSend(sent)
    #expect(model.turns.suffix(2).map(\.id) == ["sent-1.user", "sent-1.pending"])
    model.didSend(sent)
    #expect(model.turns.filter { $0.id == "sent-1.user" }.count == 1, "a second hand-over adds nothing")
  }
}
