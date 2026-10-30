import Testing

@testable import Iris

@MainActor
@Suite("MemoPlayback")
struct MemoPlaybackTests {
  private let memo = MemoFactory.memo("p", audioSeconds: 3, replyText: "ok")
  private let source = FakeMediaSource()

  private func loaded(speech: SpeechPlayer = SpeechPlayer()) async -> MemoPlayback {
    let playback = MemoPlayback(memoID: memo.id, recordingDuration: 3, speech: speech)
    playback.attach()
    await playback.recording.load(source.audio(for: memo))
    return playback
  }

  @Test("starting the reply stops the recording, and starting the recording stops the reply")
  func exclusive() async {
    let playback = await loaded()

    playback.toggleRecording()
    #expect(playback.recording.isPlaying && !playback.isReplyPlaying)

    await playback.toggleReply(memo, source: source)
    #expect(playback.isReplyPlaying && !playback.recording.isPlaying)

    playback.toggleRecording()
    #expect(playback.recording.isPlaying && !playback.isReplyPlaying)

    playback.pauseAll()
    #expect(!playback.recording.isPlaying && !playback.isReplyPlaying)
    playback.teardown()
    #expect(!playback.recording.isObserving && !playback.speech.player.isObserving)
  }

  @Test("the reply is loaded the first time it plays, not before")
  func lazyReply() async {
    let playback = MemoPlayback(memoID: memo.id, recordingDuration: 3, speech: SpeechPlayer())
    #expect(!playback.speech.player.isLoaded)
    await playback.toggleReply(memo, source: source)
    #expect(playback.speech.player.isLoaded && playback.isReplyPlaying)
    playback.teardown()
  }

  @Test("a reply that starts on its own (a spoken reply) pauses the recording that is playing")
  func spokenReplyPausesTheRecording() async {
    let playback = await loaded()
    playback.toggleRecording()
    #expect(playback.recording.isPlaying)

    // Not through the screen: the spoken-replies path calls the shared player directly.
    await playback.speech.play(memo, source: source)
    #expect(playback.isReplyPlaying && !playback.recording.isPlaying)
    playback.teardown()
  }

  @Test("leaving a memo's screen does not stop another memo's reply")
  func teardownLeavesOtherReplies() async {
    let speech = SpeechPlayer()
    let other = MemoFactory.memo("other", replyText: "hello")
    await speech.play(other, source: source)
    let playback = MemoPlayback(memoID: memo.id, recordingDuration: 3, speech: speech)

    playback.teardown()
    #expect(speech.isPlaying("other"))
    speech.stop()
  }

  @Test("a screen going away does not disconnect the screen that replaced it")
  func teardownKeepsTheNewerScreensHook() async {
    let speech = SpeechPlayer()
    let old = await loaded(speech: speech)
    let new = await loaded(speech: speech)
    new.toggleRecording()
    #expect(new.recording.isPlaying)

    old.teardown()
    await speech.play(MemoFactory.memo("other", replyText: "hello"), source: source)
    #expect(speech.isPlaying("other") && !new.recording.isPlaying)
    new.teardown()
    speech.stop()
  }

  @Test("building a playback binds nothing until it is attached")
  func initHasNoSideEffects() async {
    let speech = SpeechPlayer()
    let screen = await loaded(speech: speech)
    screen.toggleRecording()
    _ = MemoPlayback(memoID: "throwaway", recordingDuration: 1, speech: speech)

    await speech.play(MemoFactory.memo("other", replyText: "hello"), source: source)
    #expect(!screen.recording.isPlaying)
    screen.teardown()
    speech.stop()
  }
}
