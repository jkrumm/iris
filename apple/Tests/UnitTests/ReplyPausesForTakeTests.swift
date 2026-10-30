import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// Wave 18 I1: recording takes priority over playback. A take that starts pauses a playing spoken reply and the open
/// detail's recording, so the microphone never hears them; nothing resumes by itself.
@MainActor
@Suite("A take start pauses playback")
struct ReplyPausesForTakeTests {
  let client = FakeAPIClient(now: { MemoFactory.now })
  private let memo = MemoFactory.memo("spoken", audioSeconds: 3, replyText: "ok")
  private let source = FakeMediaSource()

  private func controller(_ rig: OutboxRig, speech: SpeechPlayer) -> TakeController {
    let coordinator = TakeLiveActivityCoordinator(
      activity: RecordingLiveActivity(), stack: rig.stack, created: rig.created)
    return TakeController(
      stack: rig.stack, liveActivity: coordinator, outbox: rig.service, microphone: nil, canRecord: true,
      isConfigured: { true }, requestPermission: { true }, speech: speech)
  }

  @Test("pauseForTake stops the reply and the open detail's recording, and keeps them stopped")
  func pausesBoth() async {
    let speech = SpeechPlayer()
    let playback = MemoPlayback(memoID: memo.id, recordingDuration: 3, speech: speech)
    playback.attach()
    await playback.recording.load(source.audio(for: memo))

    await speech.play(memo, source: source)
    #expect(speech.isPlaying(memo.id))
    speech.pauseForTake()
    #expect(!speech.isPlaying(memo.id) && !speech.isBusy)

    playback.toggleRecording()
    #expect(playback.recording.isPlaying)
    speech.pauseForTake()
    #expect(!playback.recording.isPlaying && !speech.isBusy)
    playback.teardown()
  }

  @Test("starting a take pauses the playing reply before the recorder opens")
  func takeStartPausesTheReply() async throws {
    let rig = OutboxRig(client: client)
    let speech = SpeechPlayer()
    let controller = controller(rig, speech: speech)
    await speech.play(memo, source: source)
    #expect(speech.isPlaying(memo.id))

    try await controller.start(mode: .auto)

    #expect(!speech.isPlaying(memo.id))
    #expect(speech.player.isLoaded, "paused, not released: the reply is still there to resume by hand")
    try await controller.stop()
    #expect(!speech.isPlaying(memo.id), "ending the take does not resume it")
  }

  @Test("a thread's hold-to-talk take pauses the reply too")
  func threadTakePausesTheReply() async throws {
    let rig = OutboxRig(client: client)
    let speech = SpeechPlayer()
    // The controller follows the session for takes it did not start (this one goes straight to the capture session).
    let following = controller(rig, speech: speech)
    await speech.play(memo, source: source)
    #expect(speech.isPlaying(memo.id))

    let voice = rig.voice()
    try await voice.begin(VoiceReplyRequest(threadId: "thread-1", mode: .chat))

    var paused = false
    for _ in 0..<500 where !paused {
      paused = !speech.isPlaying(memo.id)
      if !paused { try await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(paused)
    _ = try await voice.end(cancelled: true)
    withExtendedLifetime(following) {}
  }

  @Test("a start with nothing playing changes nothing")
  func nothingPlaying() async throws {
    let rig = OutboxRig(client: client)
    let speech = SpeechPlayer()
    let controller = controller(rig, speech: speech)

    try await controller.start(mode: .auto)

    #expect(!speech.isBusy && speech.memoID == nil)
    try await controller.stop()
  }
}
