import Testing

@testable import Iris

@MainActor
@Suite("MemoPlayback")
struct MemoPlaybackTests {
  private func loaded() async -> MemoPlayback {
    let memo = MemoFactory.memo("p", audioSeconds: 3, replyText: "ok")
    let playback = MemoPlayback(recordingDuration: 3)
    await playback.recording.load(FakeMediaSource().audio(for: memo))
    await playback.reply.load(FakeMediaSource().speech(for: memo))
    return playback
  }

  @Test("starting the reply stops the recording, and starting the recording stops the reply")
  func exclusive() async {
    let memo = MemoFactory.memo("p", audioSeconds: 3, replyText: "ok")
    let playback = await loaded()

    playback.toggleRecording()
    #expect(playback.recording.isPlaying && !playback.reply.isPlaying)

    await playback.toggleReply(loading: FakeMediaSource().speech(for: memo))
    #expect(playback.reply.isPlaying && !playback.recording.isPlaying)

    playback.toggleRecording()
    #expect(playback.recording.isPlaying && !playback.reply.isPlaying)

    playback.pauseAll()
    #expect(!playback.recording.isPlaying && !playback.reply.isPlaying)
    playback.teardown()
    #expect(!playback.recording.isObserving && !playback.reply.isObserving)
  }

  @Test("the reply is loaded the first time it plays, not before")
  func lazyReply() async {
    let memo = MemoFactory.memo("p", audioSeconds: 3, replyText: "ok")
    let playback = MemoPlayback(recordingDuration: 3)
    #expect(!playback.reply.isLoaded)
    await playback.toggleReply(loading: FakeMediaSource().speech(for: memo))
    #expect(playback.reply.isLoaded && playback.reply.isPlaying)
    playback.teardown()
  }
}
