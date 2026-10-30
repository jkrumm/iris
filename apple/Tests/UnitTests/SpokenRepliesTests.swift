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
    createdHere: @escaping (String) async -> Bool = { _ in true },
    isRecording: @escaping () -> Bool = { false }
  ) -> SpokenReplies {
    SpokenReplies(
      store: store ?? InMemorySpokenRepliesStore(on), speech: speech, client: client, media: { FakeMediaSource() },
      createdHere: createdHere, isRecording: isRecording)
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
      media: { SilentSource.shared.next() }, createdHere: { _ in true }, isRecording: { false })
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

  // MARK: Busy: a spoken reply waits, never interrupts

  @Test("a reply that is playing is not interrupted, and the newcomer is never spoken later")
  func playingReplyIsNotInterrupted() async {
    await seed("playing")
    await seed("newcomer")
    let replies = replies()
    await replies.memoDone(id: "playing")
    #expect(speech.isPlaying("playing"))
    await replies.memoDone(id: "newcomer")
    #expect(speech.isPlaying("playing"))
    #expect(speech.memoID == "playing")
    // Skipped for good: neither a repeated `memo.done` nor the player going quiet speaks it.
    speech.pause()
    await replies.memoDone(id: "newcomer")
    #expect(speech.memoID == "playing" && !speech.isPlaying("newcomer"))
    speech.stop()
  }

  @Test("a take that records blocks the spoken reply and is left alone")
  func recordingTake() async {
    await seed()
    var recording = true
    let replies = replies(isRecording: { recording })
    await replies.memoDone(id: "m")
    #expect(speech.memoID == nil && !speech.player.isLoaded)
    // Not queued: once the take is over the same memo still does not speak.
    recording = false
    await replies.memoDone(id: "m")
    #expect(speech.memoID == nil)
  }

  @Test("the open detail's recording keeps playing and the reply is skipped")
  func recordingPlayback() async {
    await seed()
    var paused = 0
    let owner = NSObject()
    speech.bindRecording(owner: owner, isPlaying: { true }, pause: { paused += 1 })
    await replies().memoDone(id: "m")
    #expect(paused == 0)
    #expect(speech.memoID == nil)
    speech.unbindRecording(owner: owner)
  }

  @Test("a take that starts while the speech downloads cancels the start and skips the memo")
  func takeStartsMidDownload() async {
    await seed()
    // The first `isRecording` read is the early check, the second the re-check after the fetch; the third is `shouldPlay`.
    var reads = 0
    let replies = replies(isRecording: {
      reads += 1
      return reads >= 3
    })
    await replies.memoDone(id: "m")
    #expect(!speech.isPlaying("m"))
    reads = 0
    await replies.memoDone(id: "m")
    #expect(reads == 0, "marked as skipped, so the repeat returns before looking at anything")
  }

  @Test("idle: nothing plays and no take records, so the reply speaks as before")
  func idleSpeaks() async {
    await seed()
    await replies(isRecording: { false }).memoDone(id: "m")
    #expect(speech.isPlaying("m"))
    speech.stop()
  }
}
