import Foundation
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("ComposerModel")
struct ComposerModelTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func model(
    _ request: ComposerRequest = ComposerRequest(), ids: [String] = ["id-1", "id-2", "id-3"]
  ) -> ComposerModel {
    var remaining = ids
    return ComposerModel(
      request: request, client: client, now: { MemoFactory.now },
      makeID: { remaining.isEmpty ? "spare" : remaining.removeFirst() })
  }

  @Test("an empty or blank text cannot be sent")
  func blank() async {
    let composer = model()
    #expect(!composer.canSend)
    composer.text = " \n  "
    #expect(!composer.canSend)
    #expect(await composer.send() == nil)
    #expect(await client.calls.isEmpty)
  }

  @Test("the text is sent trimmed with the chosen mode, and the memo comes back typed")
  func sends() async throws {
    let composer = model()
    composer.mode = .chat
    composer.text = "  Which Postgres index fits? \n"
    let memo = try #require(await composer.send())

    #expect(memo.isTyped && memo.mode == .chat && memo.transcript == "Which Postgres index fits?")
    #expect(
      await client.calls == [
        .createTextMemo(
          CreateTextMemoRequest(
            id: "id-1", mode: .chat, startedAt: MemoFactory.now, text: "Which Postgres index fits?"))
      ])
  }

  @Test("the counter counts Unicode code points like the server and blocks past the limit")
  func limit() {
    let composer = model()
    composer.text = String(repeating: "a", count: CreateTextMemoRequest.maxTextCharacters)
    #expect(composer.canSend && !composer.isOverLimit)
    composer.text += "a"
    #expect(composer.isOverLimit && !composer.canSend)
    composer.text = "👨‍👩‍👧"
    #expect(composer.characterCount == 5)
  }

  @Test("a failed send keeps the text and the id, so the retry cannot create a second memo")
  func retryKeepsTheID() async throws {
    let composer = model()
    composer.text = "Router bestellen"
    await client.enqueueFailure(.unexpectedStatus(503), for: .createTextMemo)
    #expect(await composer.send() == nil)
    #expect(composer.failure != nil)
    #expect(composer.text == "Router bestellen")

    let memo = try #require(await composer.send())
    #expect(memo.id == "id-1")
    #expect(composer.failure == nil)
    let ids = await client.calls.compactMap { call -> String? in
      if case .createTextMemo(let request) = call { request.id } else { nil }
    }
    #expect(ids == ["id-1", "id-1"])
  }

  @Test("editing after a failure is a new memo with a new id")
  func editedBodyGetsANewID() async throws {
    let composer = model()
    composer.text = "first"
    await client.enqueueFailure(.unexpectedStatus(503), for: .createTextMemo)
    _ = await composer.send()
    composer.text = "second"
    #expect(try #require(await composer.send()).id == "id-2")
  }

  @Test("a reply continues the thread of the memo it answers")
  func replyContinuesTheThread() async throws {
    var spoken = MemoFactory.memo("m", mode: .chat)
    spoken.threadId = "thread-1"
    let request = ComposerRequest.reply(to: spoken)
    #expect(request.threadId == "thread-1" && request.mode == .chat)

    let thread = MemoThread(
      id: "thread-1", kind: .chat, title: "Q", createdAt: MemoFactory.now, updatedAt: MemoFactory.now)
    await client.seed(ThreadDetail(thread: thread, memos: [], messages: []))
    let composer = model(request)
    composer.text = "and a second question"
    let memo = try #require(await composer.send())
    #expect(memo.threadId == "thread-1")
  }

  @Test("a memo outside a thread is answered with a fresh chat")
  func replyWithoutAThread() {
    let request = ComposerRequest.reply(to: MemoFactory.memo("m", mode: .hermes))
    #expect(request.threadId == nil && request.mode == .chat)
  }

  @Test("the composer offers every mode the server accepts")
  func modes() {
    #expect(ComposerModel.modes == [.auto, .journal, .hermes, .tab, .chat])
  }

  @Test("Cancel is off while a send is on the wire and back once it answers")
  func cancelDuringSend() async {
    let composer = model()
    composer.text = "Hello"
    #expect(composer.canCancel)
    let gate = await client.hold(.createTextMemo)
    let send = Task { await composer.send() }
    defer { gate.release() }
    guard await waitUntilHeld(gate) else { return }
    #expect(composer.isSending && !composer.canCancel)
    gate.release()
    _ = await send.value
    #expect(!composer.isSending && composer.canCancel)
  }
}
