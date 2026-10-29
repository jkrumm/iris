import Foundation
import IrisCore
import Testing

@testable import Iris

/// A media source that has no speech the first time it is asked and the fake's after that.
private final class SilentSource: @unchecked Sendable {
  nonisolated(unsafe) static let shared = SilentSource()
  private var asked = 0

  func next() -> any MemoMediaSource {
    asked += 1
    return asked == 1 ? UnavailableMediaSource() : FakeMediaSource()
  }
}

@MainActor
@Suite("SpokenReplies")
struct SpokenRepliesTests {
  let client = FakeAPIClient(now: { MemoFactory.now })
  let speech = SpeechPlayer()

  private func replies(
    on: Bool = true, store: InMemorySpokenRepliesStore? = nil,
    createdHere: @escaping (String) async -> Bool = { _ in true }
  ) -> SpokenReplies {
    SpokenReplies(
      store: store ?? InMemorySpokenRepliesStore(on), speech: speech, client: client, media: { FakeMediaSource() },
      createdHere: createdHere)
  }

  private func seed(_ id: String = "m", state: MemoState = .notified, replyText: String? = "Alles notiert.") async {
    await client.seed(MemoFactory.detail(MemoFactory.memo(id, state: state, route: "hermes", replyText: replyText)))
  }

  @Test("a finished reply of this device is spoken while the app is in the foreground")
  func speaks() async {
    await seed()
    await replies().memoDone(id: "m")
    #expect(speech.isPlaying("m"))
    speech.stop()
  }

  @Test("it stays silent when the setting is off")
  func off() async {
    await seed()
    await replies(on: false).memoDone(id: "m")
    #expect(speech.memoID == nil)
  }

  @Test("it stays silent while the app is not in the foreground")
  func background() async {
    await seed()
    let replies = replies()
    replies.isForeground = false
    await replies.memoDone(id: "m")
    #expect(speech.memoID == nil)
  }

  @Test("another device's memo is never spoken")
  func otherDevice() async {
    await seed()
    await replies(createdHere: { _ in false }).memoDone(id: "m")
    #expect(speech.memoID == nil)
  }

  @Test("a memo that is parked or has no reply is not spoken")
  func notReady() async {
    await seed("parked", state: .needsRoute, replyText: nil)
    await seed("mute", replyText: nil)
    let replies = replies()
    await replies.memoDone(id: "parked")
    await replies.memoDone(id: "mute")
    #expect(speech.memoID == nil)
  }

  @Test("a reply that could not start is tried again on the next memo.done")
  func notMarkedUntilItPlays() async {
    await seed()
    // Another reply is loading: the player takes none. Simulated by a source without speech for the first attempt.
    let replies = SpokenReplies(
      store: InMemorySpokenRepliesStore(true), speech: speech, client: client,
      media: { SilentSource.shared.next() }, createdHere: { _ in true })
    await replies.memoDone(id: "m")
    #expect(speech.memoID == nil)
    await replies.memoDone(id: "m")
    #expect(speech.isPlaying("m"))
    speech.stop()
  }

  @Test("each memo is spoken once")
  func once() async {
    await seed()
    let replies = replies()
    await replies.memoDone(id: "m")
    speech.stop()
    await replies.memoDone(id: "m")
    #expect(speech.memoID == nil)
  }

  @Test("the setting is read from the store and written back on change")
  func persists() {
    let store = InMemorySpokenRepliesStore(false)
    let replies = replies(on: false, store: store)
    #expect(!replies.isOn)
    replies.isOn = true
    #expect(store.load())
    #expect(self.replies(store: store).isOn)
  }
}
