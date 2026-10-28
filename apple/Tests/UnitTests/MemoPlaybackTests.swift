import Testing

@testable import Iris

@MainActor
@Suite("MemoPlayback")
struct MemoPlaybackTests {
  private func loaded() -> MemoPlayback {
    let memo = MemoFactory.memo("p", audioSeconds: 3, replyText: "ok")
    let playback = MemoPlayback(recordingDuration: 3)
    playback.recording.load(FakeMediaSource().audio(for: memo))
    playback.reply.load(FakeMediaSource().speech(for: memo))
    return playback
  }

  @Test("starting the reply stops the recording, and starting the recording stops the reply")
  func exclusive() {
    let memo = MemoFactory.memo("p", audioSeconds: 3, replyText: "ok")
    let playback = loaded()

    playback.toggleRecording()
    #expect(playback.recording.isPlaying && !playback.reply.isPlaying)

    playback.toggleReply(loading: FakeMediaSource().speech(for: memo))
    #expect(playback.reply.isPlaying && !playback.recording.isPlaying)

    playback.toggleRecording()
    #expect(playback.recording.isPlaying && !playback.reply.isPlaying)

    playback.pauseAll()
    #expect(!playback.recording.isPlaying && !playback.reply.isPlaying)
  }

  @Test("the reply is loaded the first time it plays, not before")
  func lazyReply() {
    let memo = MemoFactory.memo("p", audioSeconds: 3, replyText: "ok")
    let playback = MemoPlayback(recordingDuration: 3)
    #expect(!playback.reply.isLoaded)
    playback.toggleReply(loading: FakeMediaSource().speech(for: memo))
    #expect(playback.reply.isLoaded && playback.reply.isPlaying)
  }
}
