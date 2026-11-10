import IrisCore
import IrisUI
import SwiftUI

/// Details of one memo: the line that reads the run's total time and cost; opened it shows every step (duration, cost,
/// attempts, the failed step's retry), the copy rows, the tools Hermes used and the ids. Collapsed unless the memo failed
/// (see ``MemoDetailModel/isWaterfallExpanded``). The memo detail screen and a conversation's Details sheet show the same one.
struct MemoDetailsSection: View {
  @Bindable var model: MemoDetailModel
  let onRetry: (String) -> Void

  var body: some View {
    if model.memo.state.isResultReady {
      waterfall(now: .now)
    } else {
      // A running step's bar grows with the clock.
      TimelineView(.periodic(from: .now, by: 1)) { context in
        waterfall(now: context.date)
      }
    }
  }

  private func waterfall(now: Date) -> some View {
    StepWaterfall(
      rows: model.rows(now: now),
      totalTitle: String(localized: "Details", comment: "Section line of the memo detail: steps, cost, ids"),
      // Details collapse before the steps have loaded too: the line never goes away for want of a total.
      totalValue: model.totalValue(now: now) ?? "",
      isExpanded: $model.isWaterfallExpanded,
      onRetry: onRetry
    ) {
      VStack(alignment: .leading, spacing: 0) {
        copyRow(.transcript)
        copyRow(.reply)
        actionsLine
        idsFooter
      }
    }
  }

  /// The ids to quote when something is wrong, then the device and the recording's segments.
  private var idsFooter: some View {
    let memo = model.memo
    return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      idRow(String(localized: "Memo ID", comment: "Detail: label of the memo's id"), memo.id)
      // A memo in its own Hermes session has the memo's id as its thread id: one id says it.
      if let threadId = memo.threadId, threadId != memo.id {
        idRow(String(localized: "Thread ID", comment: "Detail: label of the thread's id"), threadId)
      }
      Text(verbatim: deviceLine(memo))
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.faint)
    }
    .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
    .padding(.vertical, Theme.Spacing.cardInsetVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("detail.ids")
  }

  private func idRow(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
      Text(verbatim: title)
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.muted)
      IDValueField(value)
    }
  }

  private func deviceLine(_ memo: Memo) -> String {
    guard let count = memo.segmentCount else { return memo.device }
    return memo.device + " · "
      + String(localized: "\(count) segments", comment: "Footer of the memo detail: uploaded recording segments")
  }

  /// One row of Details that copies the transcript or the reply as plain text and confirms with "Copied".
  @ViewBuilder private func copyRow(_ target: MemoDetailModel.CopyTarget) -> some View {
    let text = target == .transcript ? model.memo.plainTranscript : model.memo.plainReply
    if text != nil {
      let copied = model.copied == target
      let title =
        target == .transcript
        ? String(localized: "Copy transcript", comment: "Detail: copies the transcript as plain text")
        : String(localized: "Copy reply", comment: "Detail: copies the reply as plain text")
      Button {
        model.copy(target)
      } label: {
        Label(
          copied ? String(localized: "Copied", comment: "Detail: confirmation after Copy") : title,
          systemImage: copied ? "checkmark" : "doc.on.doc"
        )
        .themeFont(.subheadline)
        .foregroundStyle(copied ? Theme.Status.good : Theme.Accent.tint)
        .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
        .padding(.vertical, Theme.Spacing.cardInsetVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .sensoryFeedback(.success, trigger: copied) { _, now in now }
      .accessibilityIdentifier(target == .transcript ? "detail.transcript.copy" : "detail.reply.copy")
      Theme.divider.frame(height: 1)
    }
  }

  /// What Hermes used for the memo, one quiet line in Details; nothing when it used no tool.
  @ViewBuilder private var actionsLine: some View {
    let actions = model.memo.actions
    if !actions.isEmpty {
      let tools = actions.joined(separator: ", ")
      Text(
        verbatim: String(
          localized: "Hermes used: \(tools)", comment: "Detail: the tools Hermes ran for the memo, names are data")
      )
      .themeFont(.caption)
      .foregroundStyle(Theme.Ink.muted)
      .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
      .padding(.vertical, Theme.Spacing.cardInsetVertical)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("detail.actions")
    }
  }
}
