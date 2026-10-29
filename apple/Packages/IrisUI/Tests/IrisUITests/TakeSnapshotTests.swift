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

    private func screen(paused: Bool, notice: String? = nil) -> some View {
      TakeScreen(
        isPaused: paused, start: CaptureSamples.start, frozenAt: CaptureSamples.now, modeLabel: "Auto",
        inputName: "iPhone Microphone", levels: CaptureSamples.levels, notice: notice, labels: CaptureSamples.labels,
        onMinimize: {}, onPickInput: {}, onTogglePause: {}, onStop: {}, onDiscard: {})
    }

    @Test("the take screen while recording", .tags(.snapshot))
    func screenRecording() {
      SnapshotSupport.assertLightAndDark(screen(paused: false), width: 390, height: 780)
    }

    @Test("the take screen while paused, with a notice", .tags(.snapshot))
    func screenPaused() {
      SnapshotSupport.assertLightAndDark(
        screen(paused: true, notice: "The recording is paused by a call."), width: 390, height: 780)
    }
  }
#endif
