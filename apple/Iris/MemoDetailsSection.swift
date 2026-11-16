import IrisCore
import IrisUI
import SwiftUI

/// Details of one memo: the line that reads the run's total time and cost; opened it shows every step (duration, cost,
/// attempts, the failed step's retry), the copy rows, the tools Hermes used and the ids. The shared ``MemoDetailsContent`` draws
/// it, the Mac's popover too; this is the iPhone's model behind it. The Details sheet shows it for the transcript screen and for
/// each answer of a conversation.
struct MemoDetailsSection: View {
  let model: MemoDetailModel

  var body: some View {
    if model.memo.state.isResultReady {
      content(now: .now)
    } else {
      // A running step's bar grows with the clock.
      TimelineView(.periodic(from: .now, by: 1)) { context in
        content(now: context.date)
      }
    }
  }

  private func content(now: Date) -> some View {
    let memo = model.memo
    return MemoDetailsContent(
      rows: model.rows(now: now),
      // Details collapse before the steps have loaded too: the line never goes away for want of a total.
      totalValue: model.totalValue(now: now) ?? "", copyRows: copyRows, tools: memo.actions, memoID: memo.id,
      threadID: memo.threadId, device: memo.device, segmentCount: memo.segmentCount,
      onRetry: model.retry(stepID:))
  }

  /// One row each for the transcript and the reply the memo has.
  private var copyRows: [MemoDetailsContent.CopyRow] {
    var rows: [MemoDetailsContent.CopyRow] = []
    if model.memo.plainTranscript != nil {
      rows.append(
        MemoDetailsContent.CopyRow(
          id: "transcript",
          title: String(localized: "Copy transcript", comment: "Detail: copies the transcript as plain text"),
          isCopied: model.copied == .transcript, action: { model.copy(.transcript) }))
    }
    if model.memo.plainReply != nil {
      rows.append(
        MemoDetailsContent.CopyRow(
          id: "reply", title: String(localized: "Copy reply", comment: "Detail: copies the reply as plain text"),
          isCopied: model.copied == .reply, action: { model.copy(.reply) }))
    }
    return rows
  }
}

extension MemoDetailModel {
  /// Retries from the step a Details row or the action bar names.
  func retry(stepID: String) {
    guard let step = MemoStep(rawValue: stepID) else { return }
    Task { await retry(from: step) }
  }
}

/// The bottom bar of a memo's detail: the retry choices of the memo's failed or finished steps. The memo detail screen and a
/// conversation's Details sheet show the same one.
struct MemoDetailActions: View {
  let model: MemoDetailModel

  var body: some View {
    DetailActionBar(
      retryOptions: model.retrySteps.map { DetailRetryOption(id: $0.rawValue, title: $0.title) },
      primaryRetryID: model.primaryRetryStep?.rawValue,
      onRetry: model.retry(stepID:)
    )
    .frame(maxWidth: .infinity)
    .padding(.vertical, Theme.Spacing.sm)
  }
}

/// The toast of a failed retry above the action bar.
struct MemoDetailFailureToast: View {
  let model: MemoDetailModel

  var body: some View {
    if let failure = model.failure {
      ToastBanner(message: failure.message)
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("detail.toast")
    }
  }
}

/// The recording's player bar, wired to a memo's playback.
struct MemoRecordingPlayer: View {
  let playback: MemoPlayback
  @Binding var isExpanded: Bool

  var body: some View {
    let audio = playback.recording
    MemoPlayerBar(
      position: audio.position, duration: audio.duration, isPlaying: audio.isPlaying, isEnabled: audio.isLoaded,
      isExpanded: $isExpanded,
      onToggle: playback.toggleRecording,
      onSeek: { audio.seek(to: $0) },
      onSkipBack: { audio.skipBack() })
  }
}
