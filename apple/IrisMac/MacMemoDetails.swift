import IrisCore
import IrisUI
import SwiftUI

/// The detail's closing disclosure: the step table and the ids, collapsed unless the memo failed. The document layout and the chat
/// share it, so Retry from a failed step works in both.
struct MacMemoDetails: View {
  @Bindable var model: MacMemoDetailModel

  var body: some View {
    if let memo = model.memo {
      details(memo)
    }
  }

  private func details(_ memo: Memo) -> some View {
    DisclosureGroup(isExpanded: $model.isWaterfallExpanded) {
      VStack(alignment: .leading, spacing: Theme.Spacing.macSectionGap) {
        if memo.state.isResultReady {
          table(memo, now: .now)
        } else {
          // A running step's time grows with the clock.
          TimelineView(.periodic(from: .now, by: 1)) { context in
            table(memo, now: context.date)
          }
        }
        ids(memo)
      }
      .padding(.top, Theme.Spacing.macLabelGap)
    } label: {
      Text(verbatim: String(localized: "Details", comment: "Section label of the memo detail: steps, cost, ids"))
        .macFont(.caption, weight: .semibold)
        .textCase(.uppercase)
        .foregroundStyle(Theme.Ink.muted)
        .accessibilityAddTraits(.isHeader)
    }
    .accessibilityIdentifier("mac.detail.details")
  }

  /// The ids to quote when something is wrong, and the device.
  private func ids(_ memo: Memo) -> some View {
    Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.lg, verticalSpacing: Theme.Spacing.snug) {
      idRow(String(localized: "Memo ID", comment: "Detail: label of the memo's id"), memo.id)
      // A memo in its own Hermes session has the memo's id as its thread id: one id says it.
      if let threadId = memo.threadId, threadId != memo.id {
        idRow(String(localized: "Thread ID", comment: "Detail: label of the thread's id"), threadId)
      }
      idRow(String(localized: "Device", comment: "Detail: label of the recording device"), memo.device)
    }
    .macFont(.caption)
    .accessibilityIdentifier("mac.detail.ids")
  }

  private func idRow(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(verbatim: title).foregroundStyle(Theme.Ink.muted)
      Text(verbatim: value).monospaced().foregroundStyle(Theme.Ink.secondary).textSelection(.enabled)
    }
  }

  private func table(_ memo: Memo, now: Date) -> some View {
    let rows = model.rows(now: now)
    let totals = model.detail.flatMap { WaterfallBuilder.totals(for: $0, now: now) }
    return Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.lg, verticalSpacing: Theme.Spacing.snug) {
      GridRow {
        header(String(localized: "Step", comment: "Steps table column"))
        header(String(localized: "Status", comment: "Steps table column"))
        header(String(localized: "Time", comment: "Steps table column")).gridColumnAlignment(.trailing)
        header(String(localized: "Cost", comment: "Steps table column")).gridColumnAlignment(.trailing)
      }
      ForEach(rows) { row in
        Divider().overlay(Theme.Surface.hairline).gridCellUnsizedAxes(.horizontal)
        stepRow(row)
        if row.error != nil || row.optionalNote != nil || row.retryTitle != nil {
          GridRow {
            stepDetail(row).gridCellColumns(4)
          }
        }
      }
      if let totals {
        Divider().overlay(Theme.Surface.hairline).gridCellUnsizedAxes(.horizontal)
        GridRow {
          Text(
            memo.state.isResultReady
              ? String(localized: "Total", comment: "Footer of the step waterfall")
              : String(localized: "Total so far", comment: "Footer of the step waterfall while the memo runs")
          )
          .macFont(.body, weight: .semibold)
          Color.clear.frame(width: 0, height: 0)
          Text(verbatim: StepText.duration(milliseconds: totals.milliseconds)).monospacedDigit()
          Text(verbatim: totals.costUsd.map { StepText.dollars($0) } ?? "")
            .monospacedDigit()
        }
        .macFont(.body)
      }
    }
    .accessibilityIdentifier("mac.detail.steps")
  }

  private func header(_ title: String) -> some View {
    Text(verbatim: title).macFont(.caption).foregroundStyle(Theme.Ink.faint)
  }

  private func stepRow(_ row: StepWaterfallRow) -> some View {
    let parts = (row.metric ?? "").components(separatedBy: " · ")
    return GridRow {
      HStack(spacing: Theme.Spacing.snug) {
        Text(verbatim: row.title)
        if let attempts = row.attempts { Text(verbatim: attempts).foregroundStyle(Theme.Ink.faint).macFont(.caption) }
        if let badge = row.badge {
          Text(verbatim: badge.text).macFont(.caption)
            .foregroundStyle(badge.tone == .faster ? Theme.Status.good : Theme.Status.warn)
        }
      }
      HStack(spacing: Theme.Spacing.xs) {
        Circle().fill(color(row)).frame(width: Theme.Spacing.macDot, height: Theme.Spacing.macDot)
          .accessibilityHidden(true)
        Text(verbatim: word(row.phase)).foregroundStyle(Theme.Ink.muted)
      }
      Text(verbatim: row.phase == .waiting ? "" : parts.first ?? "").monospacedDigit()
        .foregroundStyle(row.phase == .waiting ? Theme.Ink.faint : Theme.Ink.primary)
      Text(verbatim: parts.count > 1 ? parts[1] : "").monospacedDigit().foregroundStyle(Theme.Ink.secondary)
    }
    .macFont(.body)
  }

  private func stepDetail(_ row: StepWaterfallRow) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
      if let error = row.error {
        Text(verbatim: error).foregroundStyle(row.isOptional ? Theme.Status.warn : Theme.Status.bad)
          .textSelection(.enabled)
      }
      if let note = row.optionalNote { Text(verbatim: note).foregroundStyle(Theme.Ink.muted) }
      if row.retryTitle != nil, let step = MemoStep(rawValue: row.id), model.retrySteps.contains(step) {
        Button(String(localized: "Retry from \(step.title)", comment: "Button on the step a memo failed at")) {
          Task { await model.retry(from: step) }
        }
        .controlSize(.small)
        .disabled(model.isRetrying)
        .accessibilityIdentifier("mac.detail.step-retry")
      }
    }
    .macFont(.caption)
  }

  private func color(_ row: StepWaterfallRow) -> Color {
    switch row.phase {
    case .done: Theme.Status.good
    case .running: Theme.Accent.tint
    case .failed: row.isOptional ? Theme.Status.warn : Theme.Status.bad
    case .waiting: Theme.Ink.faint
    }
  }

  private func word(_ phase: StepWaterfallRow.Phase) -> String {
    switch phase {
    case .done: String(localized: "Done", comment: "Context menu")
    case .running: String(localized: "Running", comment: "Step status")
    case .failed: String(localized: "Failed", comment: "History row status")
    case .waiting: String(localized: "Waiting", comment: "Step status")
    }
  }
}
