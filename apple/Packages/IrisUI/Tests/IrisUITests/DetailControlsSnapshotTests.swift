#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct DetailControlsSnapshotTests {
    private func player(position: Double, isPlaying: Bool, isEnabled: Bool = true) -> some View {
      MemoPlayerBar(
        position: position, duration: 38, isPlaying: isPlaying, isEnabled: isEnabled, onToggle: {}, onSeek: { _ in },
        onSkipBack: {}
      )
      .padding(Theme.Spacing.lg)
    }

    @Test("the player paused part-way: play left, timeline, one 10 s-back icon right", .tags(.snapshot))
    func playerPaused() {
      SnapshotSupport.assertLightAndDark(player(position: 12, isPlaying: false), width: 390, height: 110)
    }

    @Test("the player while playing shows pause", .tags(.snapshot))
    func playerPlaying() {
      SnapshotSupport.assertLightAndDark(player(position: 26, isPlaying: true), width: 390, height: 110)
    }

    @Test("a player with nothing loaded renders dimmed", .tags(.snapshot))
    func playerDisabled() {
      SnapshotSupport.assertLightAndDark(
        player(position: 0, isPlaying: false, isEnabled: false), width: 390, height: 110)
    }

    private func actions(canPlay: Bool, retry: Bool) -> some View {
      DetailActionBar(
        isPlayingReply: false, canPlayReply: canPlay, canReply: canPlay,
        retryOptions: retry
          ? [DetailRetryOption(id: "act", title: "Act"), DetailRetryOption(id: "summarize", title: "Summarize")] : [],
        primaryRetryID: retry ? "summarize" : nil, onPlayReply: {}, onReply: {}, onRetry: { _ in }
      )
      .padding(Theme.Spacing.lg)
    }

    @Test("the bottom actions on a finished memo: retry is disabled", .tags(.snapshot))
    func actionsDone() {
      SnapshotSupport.assertLightAndDark(actions(canPlay: true, retry: false), width: 390, height: 96)
    }

    @Test("the bottom actions on a failed memo: retry is live", .tags(.snapshot))
    func actionsFailed() {
      SnapshotSupport.assertLightAndDark(actions(canPlay: false, retry: true), width: 390, height: 96)
    }

    @Test("the step-progress dashes: none, some and all steps done", .tags(.snapshot))
    func dashes() {
      let dashes = VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        StepProgressDashes(progress: StepProgress(completed: 0, total: 5))
        StepProgressDashes(progress: StepProgress(completed: 3, total: 5))
        StepProgressDashes(progress: StepProgress(completed: 5, total: 5))
      }
      .padding(Theme.Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      SnapshotSupport.assertLightAndDark(dashes, width: 160, height: 80)
    }
  }
#endif
