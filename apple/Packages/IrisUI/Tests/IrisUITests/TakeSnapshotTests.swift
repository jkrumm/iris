#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct TakeSnapshotTests {
    private func banner(paused: Bool = false, detail: String? = nil) -> some View {
      TakeBanner(
        isPaused: paused, start: CaptureSamples.start, frozenAt: CaptureSamples.now,
        title: "Auto · iPhone Microphone", detail: detail, stopLabel: "Stop", openHint: "Opens the recording",
        onOpen: {}, onStop: {}
      )
      .padding(Theme.Spacing.lg)
    }

    @Test("the banner of a running take", .tags(.snapshot))
    func bannerRecording() {
      SnapshotSupport.assertLightAndDark(banner(), width: 390, height: 84)
    }

    @Test("the banner of a paused take with earlier memos still sending", .tags(.snapshot))
    func bannerPaused() {
      SnapshotSupport.assertLightAndDark(banner(paused: true, detail: "2 sending"), width: 390, height: 96)
    }

    private func screen(paused: Bool, notice: String? = nil, preview: LiveTranscriptText? = nil) -> some View {
      TakeScreen(
        isPaused: paused, start: CaptureSamples.start, frozenAt: CaptureSamples.now, modeLabel: "Auto",
        inputName: "iPhone Microphone", levels: CaptureSamples.levels, notice: notice, preview: preview,
        labels: CaptureSamples.labels,
        onMinimize: {}, onPickInput: {}, onTogglePause: {}, onStop: {}, onDiscard: {})
    }

    @Test("the take screen while recording", .tags(.snapshot))
    func screenRecording() {
      SnapshotSupport.assertLightAndDark(screen(paused: false), width: 390, height: 780)
    }

    @Test(
      "the take screen with the live transcript: settled text primary, still-changing text secondary", .tags(.snapshot))
    func screenWithPreview() {
      let preview = LiveTranscriptText(
        finalized: "Remind me to call the dentist on Monday. And move the Thursday meeting to the afternoon.",
        volatile: "Also tell Anna the")
      SnapshotSupport.assertLightAndDark(screen(paused: false, preview: preview), width: 390, height: 780)
    }

    @Test("the take screen with a long live transcript keeps the newest lines in view", .tags(.snapshot))
    func screenWithLongPreview() {
      let sentence = "The quarterly numbers look better than last time, so the plan stays as it is."
      let preview = LiveTranscriptText(
        finalized: Array(repeating: sentence, count: 6).joined(separator: " "), volatile: "Next we should")
      SnapshotSupport.assertLightAndDark(screen(paused: false, preview: preview), width: 390, height: 780)
    }

    @Test("the take screen while paused, with a notice", .tags(.snapshot))
    func screenPaused() {
      SnapshotSupport.assertLightAndDark(
        screen(paused: true, notice: "The recording is paused by a call."), width: 390, height: 780)
    }
  }
#endif
