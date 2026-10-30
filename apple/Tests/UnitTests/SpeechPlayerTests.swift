import Foundation
import IrisCore
import Testing

@testable import Iris

/// A source whose speech download always fails (nothing listens on the port).
private struct UnreachableSource: MemoMediaSource {
  func audio(for memo: Memo) -> MediaRequest? { nil }
  func speech(for memo: Memo) -> MediaRequest? {
    MediaRequest(url: URL(string: "http://127.0.0.1:9/speech")!, headers: [:])
  }
  func asset(memoID: String, assetID: String) -> MediaRequest? { nil }
}

@MainActor
@Suite("SpeechPlayer")
struct SpeechPlayerTests {
  private let source = FakeMediaSource()
  private let first = MemoFactory.memo("first", replyText: "one")
  private let second = MemoFactory.memo("second", replyText: "two")

  @Test("play speaks the memo's reply and remembers whose it is")
  func playsAReply() async {
    let speech = SpeechPlayer()
    await speech.play(first, source: source)
    #expect(speech.isPlaying("first"))
    #expect(!speech.isPlaying("second"))
    speech.stop()
  }

  @Test("toggle pauses the reply that is playing and resumes it, without reloading")
  func toggles() async {
    let speech = SpeechPlayer()
    await speech.toggle(first, source: source)
    #expect(speech.isPlaying("first"))
    await speech.toggle(first, source: source)
    #expect(!speech.isPlaying("first"))
    #expect(speech.player.isLoaded)
    await speech.toggle(first, source: source)
    #expect(speech.isPlaying("first"))
    speech.stop()
  }

  @Test("a second memo's reply replaces the first")
  func replaces() async {
    let speech = SpeechPlayer()
    await speech.play(first, source: source)
    await speech.play(second, source: source)
    #expect(speech.isPlaying("second") && !speech.isPlaying("first"))
    speech.stop()
  }

  @Test("a memo with nothing to say plays nothing and keeps what was speaking")
  func silentMemo() async {
    let speech = SpeechPlayer()
    await speech.play(first, source: source)
    await speech.play(MemoFactory.memo("mute"), source: source)
    #expect(speech.isPlaying("first"))
    speech.stop()
  }

  @Test("a reply the caller no longer wants once the download is done stays silent")
  func gateAfterDownload() async {
    let speech = SpeechPlayer()
    let started = await speech.play(first, source: source, shouldPlay: { false })
    #expect(!started)
    #expect(!speech.isPlaying("first"))
    #expect(await speech.play(first, source: source))
    speech.stop()
  }

  @Test("stop for another memo is ignored; stop for this one, or for none, releases the player")
  func stopsByMemo() async {
    let speech = SpeechPlayer()
    await speech.play(first, source: source)
    speech.stop(memoID: "second")
    #expect(speech.isPlaying("first"))
    speech.stop(memoID: "first")
    #expect(speech.memoID == nil && !speech.player.isLoaded)
  }

  @Test("a download that fails leaves the player holding no memo")
  func failedLoadClearsTheMemo() async {
    let speech = SpeechPlayer()
    let started = await speech.play(first, source: UnreachableSource())
    #expect(!started)
    #expect(speech.memoID == nil)
    #expect(!speech.isPlaying("first"))
  }
}
