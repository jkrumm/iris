import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("ComposerModel")
struct ComposerModelTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func model(
    _ request: ComposerRequest = ComposerRequest(), rig: OutboxRig? = nil, ids: [UInt8] = [1, 2, 3]
  ) -> (ComposerModel, OutboxRig) {
    var remaining = ids
    let rig = rig ?? OutboxRig(client: client)
    let composer = ComposerModel(
      request: request, outbox: rig.service, now: { MemoFactory.now },
      makeID: {
        MemoID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, remaining.isEmpty ? 99 : remaining.removeFirst()))
      })
    return (composer, rig)
  }

  private let firstID = "00000000-0000-0000-0000-000000000001"

  @Test("an empty or blank text cannot be sent")
  func blank() async {
    let (composer, _) = model()
    #expect(!composer.canSend)
    composer.text = " \n  "
    #expect(!composer.canSend)
    #expect(await composer.send() == nil)
    #expect(await client.calls.isEmpty)
  }

  @Test("the text is sent trimmed with the chosen mode, and the memo comes back typed")
  func sends() async throws {
    let (composer, _) = model()
    composer.mode = .chat
    composer.text = "  Which Postgres index fits? \n"
    guard case .sent(let memo)? = await composer.send() else {
      Issue.record("expected the memo")
      return
    }

    #expect(memo.isTyped && memo.mode == .chat && memo.transcript == "Which Postgres index fits?")
    #expect(
      await client.calls == [
        .createTextMemo(
          CreateTextMemoRequest(
            id: firstID, mode: .chat, startedAt: MemoFactory.now, text: "Which Postgres index fits?"))
      ])
  }

  @Test("the counter counts Unicode code points like the server and blocks past the limit")
  func limit() {
    let (composer, _) = model()
    composer.text = String(repeating: "a", count: CreateTextMemoRequest.maxTextCharacters)
    #expect(composer.canSend && !composer.isOverLimit)
    composer.text += "a"
    #expect(composer.isOverLimit && !composer.canSend)
    composer.text = "👨‍👩‍👧"
    #expect(composer.characterCount == 5)
  }

  @Test("a send the server cannot take is queued, and the retry sends the same memo id")
  func offlineQueuesAndRetriesWithTheSameID() async throws {
    let (composer, rig) = model()
    composer.text = "Router bestellen"
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .createTextMemo)
    #expect(await composer.send() == .queued)
    #expect(await rig.service.queuedItems().map(\.title) == ["Router bestellen"])
    #expect(await rig.service.queuedItems().map(\.kind) == [.typedMemo])

    await rig.clock.advance(by: 2)
    #expect(await rig.drain())
    let ids = await client.calls.compactMap { call -> String? in
      if case .createTextMemo(let request) = call { request.id } else { nil }
    }
    #expect(ids == [firstID, firstID])
    #expect(await client.memos[firstID]?.memo.transcript == "Router bestellen")
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
    let (composer, _) = model(request)
    composer.text = "and a second question"
    guard case .sent(let memo)? = await composer.send() else {
      Issue.record("expected the memo")
      return
    }
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
    let (composer, _) = model()
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
