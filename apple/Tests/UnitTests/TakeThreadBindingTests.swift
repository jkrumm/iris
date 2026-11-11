import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

@Suite("TakeThreadBinding")
struct TakeThreadBindingTests {
  private func current(threadID: String?) -> ConversationPresence.Current {
    .init(anchorID: "a", threadID: threadID, memoIDs: ["a"])
  }

  @Test("a conversation on top continues its thread in Hermes mode")
  func conversationOnTop() {
    #expect(TakeThreadBinding.threadID(for: .hermes, presence: current(threadID: "t1")) == "t1")
  }

  @Test("nothing on screen, or another tab, starts a new memo")
  func nothingOnScreen() {
    #expect(TakeThreadBinding.threadID(for: .hermes, presence: nil) == nil)
  }

  @Test("Transcribe never continues a thread")
  func transcribe() {
    #expect(TakeThreadBinding.threadID(for: .transcribe, presence: current(threadID: "t1")) == nil)
  }

  @Test("a conversation whose thread is not known yet starts a new memo")
  func unknownThread() {
    #expect(TakeThreadBinding.threadID(for: .hermes, presence: current(threadID: nil)) == nil)
  }
}

extension CaptureHandlerSuites {
  @MainActor
  @Suite("Thread-bound take")
  struct ThreadBoundTakeTests {
    private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
      for _ in 0..<Int(seconds * 100) {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return await condition()
    }

    private func make() -> (CompositionRoot, Task<Void, Never>) {
      let root = CompositionRoot(arguments: ["-IrisFakeCapture"], credentials: InMemoryCredentialStore())
      let take = root.take
      return (root, Task { await take.run() })
    }

    @Test("a take bound to a thread is a normal take: screen, banner state, preview, and a reply in the queue")
    func boundTakeIsFull() async throws {
      let (root, follower) = make()
      defer { follower.cancel() }
      let take = root.take

      try await root.takeController.start(mode: .hermes, threadID: "t1")
      #expect(await waitFor { take.isActive && take.showsFull })
      #expect(take.state.request?.threadID == "t1" && take.state.request?.holdToTalk == false)
      #expect(await root.fakeLiveActivity?.starts.count == 1)
      let item = try #require(await root.outbox.queuedItems().first)
      #expect(item.kind == .voiceReply, "the outbox item carries the thread id")

      await take.discard()
      #expect(await waitFor { !take.isActive })
    }

    @Test("a hold-to-talk request is not a take of the take screen")
    func holdToTalkIsNot() {
      let (root, follower) = make()
      defer { follower.cancel() }
      let take = root.take
      var state = TakeState.idle
      state.phase = .recording
      state.memoID = MemoID()
      state.request = TakeRequest(mode: "hermes", threadID: "t1", holdToTalk: true, title: "Voice reply")
      take.apply(state)
      #expect(!take.isActive && !take.showsFull)
      state.memoID = MemoID()
      state.request = TakeRequest(mode: "hermes", threadID: "t1", title: "Voice reply")
      take.apply(state)
      #expect(take.isActive && take.showsFull)
    }

    @Test("Reply by voice starts a Hermes take bound to the thread")
    func replyByVoice() async throws {
      let (root, follower) = make()
      defer { follower.cancel() }
      let take = root.take

      await root.startReplyByVoice(threadID: "t9")
      #expect(await waitFor { take.isActive && take.showsFull })
      #expect(take.state.request?.threadID == "t9")
      #expect(take.failure == nil)
      await take.discard()
      #expect(await waitFor { !take.isActive })
    }
  }
}
