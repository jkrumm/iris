import Foundation
import IrisCore
import Testing

@testable import IrisMac

@MainActor
@Suite("Mac typed memos")
struct MacComposerTests {
  /// A fake root whose pipeline takes 40 ms per stage, loaded (the samples, the sample threads, the lists).
  private func loadedRoot() async -> MacCompositionRoot {
    let root = MacCompositionRoot(
      arguments: [MacCompositionRoot.fakeDataArgument, "-IrisFakeStepMs", "40"],
      credentials: InMemoryCredentialStore(), poster: RecordingNotificationPoster())
    root.begin()
    _ = await eventually { !root.windowHistory.memos.isEmpty || !root.history.memos.isEmpty }
    return root
  }

  private func textRequests(_ root: MacCompositionRoot) async -> [CreateTextMemoRequest] {
    guard let fake = root.fakeAPI else { return [] }
    return await fake.calls.compactMap { (call) -> CreateTextMemoRequest? in
      guard case .createTextMemo(let request) = call else { return nil }
      return request
    }
  }

  @Test("a memo typed on the New memo page reaches the server, opens as a chat and gets its answer in place")
  func newMemo() async throws {
    let root = await loadedRoot()
    let composer = root.composer(for: nil)
    #expect(composer.offersTranscribe && root.composer(for: nil) === composer, "one composer per page")
    composer.text = "Plan my Friday release"
    await root.sendTyped(composer, mode: .hermes)

    #expect(composer.text.isEmpty && composer.failure == nil)
    let requests = await textRequests(root)
    #expect(requests.count == 1 && requests.first?.text == "Plan my Friday release")
    #expect(requests.first?.mode == .hermes && requests.first?.threadId == nil)
    let id = try #require(root.selectedMemoID, "a new memo opens in the window")
    #expect(requests.first?.id == id)
    #expect(await eventually { root.windowHistory.memos.contains { $0.id == id } })

    let model = root.detailModel(for: id)
    await model.load()
    #expect(model.isChat && model.turns.first?.content == .user("Plan my Friday release"))
    #expect(
      await eventually {
        await model.load()
        return model.turns.last?.id == "\(id).reply"
      })
    if case .assistant(let text, _, _) = model.turns.last?.content {
      #expect(text == "This is the fake answer to your message.")
    } else {
      Issue.record("the pending turn did not become the answer")
    }
  }

  @Test("Transcribe only sends the memo in mode transcribe")
  func transcribeOnly() async {
    let root = await loadedRoot()
    let composer = root.composer(for: nil)
    composer.text = "Just the words"
    await root.sendTyped(composer, mode: .transcribe)
    #expect(await textRequests(root).first?.mode == .transcribe)
  }

  @Test("a reply continues the open conversation: it goes out with the thread id, stays on the memo and shows at once")
  func reply() async throws {
    let root = await loadedRoot()
    root.selectedMemoID = SampleData.hermesThreadID
    let open = root.detailModel(for: SampleData.hermesThreadID)
    await open.load()
    let thread = try #require(open.thread)
    #expect(open.replyThreadID == thread.id)

    let composer = root.composer(for: thread.id)
    #expect(!composer.offersTranscribe)
    composer.text = "And a rollback?"
    await root.sendTyped(composer, mode: .hermes)

    #expect(composer.text.isEmpty)
    #expect(await textRequests(root).first?.threadId == thread.id)
    #expect(root.selectedMemoID == SampleData.hermesThreadID, "a reply stays in its conversation")
    #expect(open.turns.contains { $0.content == .user("And a rollback?") })
  }

  @Test("a reply cannot be sent as Transcribe; the text stays")
  func replyIsHermesOnly() async {
    let root = await loadedRoot()
    let composer = root.composer(for: SampleData.hermesThreadID)
    composer.text = "Words"
    await root.sendTyped(composer, mode: .transcribe)
    #expect(composer.text == "Words" && root.selectedMemoID == nil)
    #expect(await textRequests(root).isEmpty)
  }

  @Test("a memo the server refuses for good keeps the text and says why")
  func refused() async {
    let root = await loadedRoot()
    await root.fakeAPI?.enqueueFailure(
      .server(status: 400, body: ErrorBody(error: .badRequest, message: "text is not acceptable")),
      for: .createTextMemo)
    let composer = root.composer(for: nil)
    composer.text = "Not acceptable"
    await root.sendTyped(composer, mode: .hermes)
    #expect(composer.text == "Not acceptable" && composer.failure != nil)
    #expect(root.selectedMemoID == nil)
  }

  @Test("a memo the server cannot be reached for is queued: the text goes, the note shows for a moment")
  func queued() async {
    let root = await loadedRoot()
    root.queuedNoteDuration = .milliseconds(150)
    await root.fakeAPI?.enqueueFailure(.transport(.notConnectedToInternet), for: .createTextMemo)
    let composer = root.composer(for: nil)
    composer.text = "Later"
    // The outbox waits its first-attempt window for the server before it settles for "queued".
    await root.sendTyped(composer, mode: .hermes)
    #expect(composer.text.isEmpty && composer.failure == nil)
    #expect(root.queuedNote == ObjectIdentifier(composer))
    #expect(root.selectedMemoID == nil, "a queued memo has no server copy to open yet")
    #expect(await eventually { root.queuedNote == nil })
  }

  @Test("each conversation keeps its own draft")
  func drafts() async {
    let root = await loadedRoot()
    let page = root.composer(for: nil)
    let reply = root.composer(for: SampleData.hermesThreadID)
    page.text = "one"
    reply.text = "two"
    #expect(page !== reply)
    #expect(root.composer(for: nil).text == "one")
    #expect(root.composer(for: SampleData.hermesThreadID).text == "two")
  }

  @Test("New memo clears the selection and asks the window to open")
  func newMemoAction() async {
    let root = await loadedRoot()
    root.selectedMemoID = SampleData.hermesThreadID
    let requests = root.windowRequest
    root.newMemo()
    #expect(root.selectedMemoID == nil && root.windowRequest == requests + 1)
  }
}
