import IrisCore
import IrisUI
import SwiftUI

/// The sections under the detail's header, without boxes: a small uppercase label, the content, spacing between. A thread memo shows
/// the conversation (read only) in place of its own reply and transcript, which are a turn of it.
struct MacMemoSections: View {
  let model: MacMemoDetailModel

  var body: some View {
    if let memo = model.memo {
      VStack(alignment: .leading, spacing: Theme.Spacing.macSectionGap) {
        // A thread memo shows the conversation, of which its own reply and transcript are a turn; while the conversation cannot
        // be read, they are all there is.
        let showsOwnTurn = !memo.opensThread || model.threadFailed
        if memo.opensThread { conversation }
        if showsOwnTurn { reply(memo) }
        summary(memo)
        if showsOwnTurn { transcript(memo) }
        steps(memo)
      }
    }
  }

  // MARK: Reply, summary, transcript

  @ViewBuilder private func reply(_ memo: Memo) -> some View {
    if let text = memo.replyText, !text.isEmpty {
      MacSection(String(localized: "Reply", comment: "Section label of the reply")) {
        MessageContentView(markdown: text, textRole: .footnote)
          .accessibilityIdentifier("mac.detail.reply")
      }
    }
  }

  @ViewBuilder private func summary(_ memo: Memo) -> some View {
    if let detail = memo.summary?.detail, !detail.isEmpty {
      MacSection(String(localized: "Summary", comment: "Section label of the summary")) {
        Text(verbatim: detail)
          .macFont(.body)
          .lineSpacing(Theme.Spacing.macLineSpacing)
          .foregroundStyle(Theme.Ink.secondary)
          .textSelection(.enabled)
          .accessibilityIdentifier("mac.detail.summary")
      }
    }
  }

  @ViewBuilder private func transcript(_ memo: Memo) -> some View {
    if let text = memo.transcript {
      MacSection(String(localized: "Transcript", comment: "Section label of the transcript")) {
        Text(verbatim: text)
          .macFont(.body)
          .lineSpacing(Theme.Spacing.macLineSpacing)
          .foregroundStyle(Theme.Ink.primary)
          .textSelection(.enabled)
          .accessibilityIdentifier("mac.detail.transcript")
      }
    }
  }

  // MARK: Conversation

  @ViewBuilder private var conversation: some View {
    if model.thread != nil || !model.threadFailed {
      MacSection(String(localized: "Conversation", comment: "Section label of a thread's turns")) {
        if let thread = model.thread {
          VStack(alignment: .leading, spacing: Theme.Spacing.macSectionGap) {
            ForEach(thread.messages, id: \.self) { message in
              turn(message)
            }
          }
          .accessibilityIdentifier("mac.detail.conversation")
        } else {
          ProgressView().controlSize(.small)
        }
      }
    } else {
      Label(
        String(localized: "Could not load the conversation", comment: "Detail: a thread could not be read"),
        systemImage: "exclamationmark.triangle"
      )
      .macFont(.body)
      .foregroundStyle(Theme.Status.warn)
      .accessibilityIdentifier("mac.detail.conversation-error")
    }
  }

  private func turn(_ message: ThreadMessage) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
      HStack(spacing: Theme.Spacing.snug) {
        Text(
          message.role == .user
            ? String(localized: "You", comment: "Thread turn: the person")
            : String(localized: "Hermes", comment: "Route name")
        )
        .macFont(.caption, weight: .semibold)
        Text(verbatim: message.createdAt.formatted(date: .omitted, time: .shortened))
          .macFont(.caption)
          .foregroundStyle(Theme.Ink.faint)
      }
      .foregroundStyle(message.role == .user ? Theme.Ink.muted : Theme.Accent.tint)
      if message.role == .assistant {
        MessageContentView(markdown: message.content, textRole: .footnote)
      } else {
        Text(verbatim: message.content)
          .macFont(.body)
          .lineSpacing(Theme.Spacing.macLineSpacing)
          .textSelection(.enabled)
      }
    }
  }

  // MARK: Steps

  private func steps(_ memo: Memo) -> some View {
    MacSection(String(localized: "Steps", comment: "Section label of the step waterfall")) {
      if memo.state.isResultReady {
        table(memo, now: .now)
      } else {
        // A running step's time grows with the clock.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          table(memo, now: context.date)
        }
      }
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

/// A section: its small uppercase label, then the content.
struct MacSection<Content: View>: View {
  private let title: String
  private let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.macLabelGap) {
      Text(verbatim: title)
        .macFont(.caption, weight: .semibold)
        .textCase(.uppercase)
        .foregroundStyle(Theme.Ink.muted)
        .accessibilityAddTraits(.isHeader)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
