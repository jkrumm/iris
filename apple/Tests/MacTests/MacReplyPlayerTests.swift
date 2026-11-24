import Foundation
import IrisCore
import IrisUI
import Testing

@testable import IrisMac

/// The conversation's inline reply players on the Mac's fake composition: the fake media source writes silent clips, so the real
/// `AVPlayer` of `MacAudioPlayer` plays them without a server.
@MainActor
@Suite("Mac inline reply player")
struct MacReplyPlayerTests {
  private static let finished = "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34"

  private func controls() async -> (ReplyControls, MacAudioPlayer) {
    let root = MacCompositionRoot(
      arguments: [MacCompositionRoot.fakeDataArgument], credentials: InMemoryCredentialStore(),
      poster: RecordingNotificationPoster(), takeEngine: FakeTakeEngine(), permission: FakeMicrophonePermission(),
      hotkey: FakeTakeHotkey())
    root.begin()
    _ = await eventually { !root.windowHistory.memos.isEmpty || !root.history.memos.isEmpty }
    let model = root.detailModel(for: Self.finished)
    await model.load()
    let player = MacAudioPlayer()
    let controls = MacReplyControls.make(player: player, source: { root.mediaSource }, memo: { model.memo(id: $0) })
    return (controls, player)
  }

  @Test("an answer that can speak plays its summary, pauses, resumes, seeks and switches to the full reply")
  func playsOneReply() async {
    let (controls, player) = await controls()
    #expect(controls.canPlay(Self.finished))
    #expect(controls.playback(Self.finished) == .idle, "nothing plays before the first tap")

    controls.onToggle(Self.finished)
    #expect(await eventually { controls.playback(Self.finished).isPlaying })
    #expect(controls.playback(Self.finished).choice == .summary)
    #expect(
      await eventually { controls.playback(Self.finished).duration > 0 }, "the clip's own length shows once known")

    controls.onToggle(Self.finished)
    let paused = controls.playback(Self.finished)
    #expect(paused.isActive && !paused.isPlaying, "the second tap pauses and keeps the clip")
    controls.onToggle(Self.finished)
    #expect(controls.playback(Self.finished).isPlaying, "and the third resumes it")

    controls.onSeek(Self.finished, 1)
    #expect(player.position == 1)

    controls.onPlay(Self.finished, .full)
    #expect(await eventually { controls.playback(Self.finished).choice == .full && player.isPlaying })

    player.stop()
    #expect(controls.playback(Self.finished) == .idle)
  }

  @Test("the toolbar's speaker and the inline player share one clip: starting the recording ends the reply")
  func oneClipAtATime() async {
    let (controls, player) = await controls()
    controls.onToggle(Self.finished)
    #expect(await eventually { player.isReplyCurrent(Self.finished) })
    player.toggle(Self.finished, .recording, request: nil)
    #expect(controls.playback(Self.finished) == .idle)
  }
}
