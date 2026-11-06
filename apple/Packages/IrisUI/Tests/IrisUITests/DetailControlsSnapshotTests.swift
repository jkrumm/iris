#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct DetailControlsSnapshotTests {
    /// The player as it sits in the user's bubble footer, on the bubble's own surface.
    private func player(position: Double, isPlaying: Bool, isEnabled: Bool = true, isExpanded: Bool) -> some View {
      MemoPlayerBar(
        position: position, duration: 38, isPlaying: isPlaying, isEnabled: isEnabled, isExpanded: .constant(isExpanded),
        onToggle: {}, onSeek: { _ in }, onSkipBack: {}
      )
      .padding(Theme.Spacing.lg)
      .environment(\.locale, Locale(identifier: "en"))
    }

    @Test("the collapsed player: play, 'Recording 0:38' and a chevron on one line", .tags(.snapshot))
    func playerCollapsed() {
      SnapshotSupport.assertLightAndDark(
        player(position: 0, isPlaying: false, isExpanded: false), width: 390, height: 80)
    }

    @Test("the opened player paused part-way: play, timeline with times, 10 s back, chevron", .tags(.snapshot))
    func playerPaused() {
      SnapshotSupport.assertLightAndDark(
        player(position: 12, isPlaying: false, isExpanded: true), width: 390, height: 90)
    }

    @Test("the opened player while playing shows pause", .tags(.snapshot))
    func playerPlaying() {
      SnapshotSupport.assertLightAndDark(
        player(position: 26, isPlaying: true, isExpanded: true), width: 390, height: 90)
    }

    @Test("a player with nothing loaded renders dimmed", .tags(.snapshot))
    func playerDisabled() {
      SnapshotSupport.assertLightAndDark(
        player(position: 0, isPlaying: false, isEnabled: false, isExpanded: false), width: 390, height: 80)
    }

    @Test("the reply's play control: idle and while it speaks", .tags(.snapshot))
    func replyPlay() {
      let view = VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        ReplyPlayButton(isPlaying: false, onToggle: {})
        ReplyPlayButton(isPlaying: true, onToggle: {})
      }
      .padding(Theme.Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Pinned: the strings come from the catalog, and the simulator's own language must not decide the reference.
      .environment(\.locale, Locale(identifier: "en"))
      SnapshotSupport.assertLightAndDark(view, width: 390, height: 130)
    }

    private func actions(canReply: Bool, retry: Bool) -> some View {
      DetailActionBar(
        canReply: canReply,
        retryOptions: retry
          ? [DetailRetryOption(id: "act", title: "Act"), DetailRetryOption(id: "summarize", title: "Summarize")] : [],
        primaryRetryID: retry ? "summarize" : nil, onReply: {}, onRetry: { _ in }
      )
      .padding(Theme.Spacing.lg)
    }

    @Test("the bottom actions on a finished memo: no retry button, reply only", .tags(.snapshot))
    func actionsDone() {
      SnapshotSupport.assertLightAndDark(actions(canReply: true, retry: false), width: 390, height: 96)
    }

    @Test("the bottom actions on a failed memo: retry is live", .tags(.snapshot))
    func actionsFailed() {
      SnapshotSupport.assertLightAndDark(actions(canReply: false, retry: true), width: 390, height: 96)
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
