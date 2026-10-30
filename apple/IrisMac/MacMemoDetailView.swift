import IrisCore
import IrisUI
import SwiftUI

/// The detail panel's window content: the memo `root` was last asked to open.
struct MacMemoDetailPanel: View {
  let root: MacCompositionRoot

  var body: some View {
    Group {
      if let id = root.detailMemoID {
        // A new id is a new memo: the view and its model start over.
        MacMemoDetailView(model: root.detailModel(for: id), refreshToken: { root.history.revision(of: id) })
          .id(id)
      } else {
        ContentUnavailableView(
          String(localized: "No memo selected", comment: "Detail panel without a memo"), systemImage: "waveform")
      }
    }
    .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 640)
    .background(Theme.Surface.background)
  }
}

/// One memo, read on the Mac: headline, the step waterfall (collapsed to its total), transcript and reply with a Copy button
/// each. It reloads when `refreshToken` changes (History bumps it on a `memo.updated` event).
struct MacMemoDetailView: View {
  @State private var model: MacMemoDetailModel
  private let refreshToken: () -> Int

  init(model: MacMemoDetailModel, refreshToken: @escaping () -> Int = { 0 }) {
    _model = State(initialValue: model)
    self.refreshToken = refreshToken
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        if let memo = model.memo {
          header(memo)
          routeCard(memo)
          steps(memo)
          transcript(memo)
          reply(memo)
          footer(memo)
        } else if model.loadFailed {
          ContentUnavailableView(
            String(localized: "Could not load the memo", comment: "Detail error title"),
            systemImage: "exclamationmark.triangle")
        } else {
          ProgressView().frame(maxWidth: .infinity)
        }
        if let failure = model.failure {
          Text(verbatim: failure)
            .themeFont(.footnote)
            .foregroundStyle(Theme.Status.bad)
            .accessibilityIdentifier("mac.detail.failure")
        }
      }
      .padding(Theme.Spacing.lg)
    }
    .accessibilityIdentifier("mac.detail")
    .task(id: refreshToken()) { await model.load() }
  }

  // MARK: Sections

  private func header(_ memo: Memo) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.sm) {
        RouteChip(label: memo.routeLabel, systemImage: memo.routeChipIcon)
        Text(
          verbatim: [memo.timeText, memo.audioSeconds.map(DurationText.string(seconds:))].compactMap { $0 }.joined(
            separator: " · ")
        )
        .themeFont(.footnote)
        .foregroundStyle(Theme.Ink.muted)
      }
      Text(verbatim: memo.rowHeadline)
        .themeFont(.title, weight: .bold)
        .foregroundStyle(Theme.Ink.primary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      if memo.state == .failed, let error = memo.error {
        Text(verbatim: error)
          .themeFont(.callout)
          .foregroundStyle(Theme.Status.bad)
      } else if let detail = memo.summary?.detail {
        Text(verbatim: detail)
          .themeFont(.callout)
          .foregroundStyle(Theme.Ink.secondary)
      }
    }
  }

  /// Why the memo is parked. Answering it stays on the phone until the Mac gets the route sheet.
  @ViewBuilder private func routeCard(_ memo: Memo) -> some View {
    if memo.state == .needsRoute {
      Label {
        Text(verbatim: memo.routeReason ?? String(localized: "Where should this go?", comment: "Detail: parked memo"))
      } icon: {
        Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.Status.warn)
      }
      .themeFont(.callout)
      .foregroundStyle(Theme.Ink.secondary)
      .padding(Theme.Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .detailCard()
      .accessibilityIdentifier("mac.detail.route.reason")
    }
  }

  private func steps(_ memo: Memo) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      DetailSectionLabel(String(localized: "Steps", comment: "Section label of the step waterfall"))
      if memo.state.isResultReady {
        waterfall(memo, now: .now)
      } else {
        // A running step's bar grows with the clock.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          waterfall(memo, now: context.date)
        }
      }
    }
  }

  private func waterfall(_ memo: Memo, now: Date) -> some View {
    StepWaterfall(
      rows: model.rows(now: now),
      totalTitle: memo.state.isResultReady
        ? String(localized: "Total", comment: "Footer of the step waterfall")
        : String(localized: "Total so far", comment: "Footer of the step waterfall while the memo runs"),
      totalValue: model.totalValue(now: now),
      isExpanded: $model.isWaterfallExpanded,
      onRetry: retry)
  }

  @ViewBuilder private func transcript(_ memo: Memo) -> some View {
    if let text = memo.transcript {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        sectionHeader(String(localized: "Transcript", comment: "Section label of the transcript"), copying: .transcript)
        Text(verbatim: text)
          .themeFont(.callout)
          .foregroundStyle(Theme.Ink.primary)
          .textSelection(.enabled)
          .modifier(TextCard())
          .accessibilityIdentifier("mac.detail.transcript")
      }
    }
  }

  @ViewBuilder private func reply(_ memo: Memo) -> some View {
    if let text = memo.replyText {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        sectionHeader(String(localized: "Reply", comment: "Section label of the reply"), copying: .reply)
        Text(ReplyMarkdown.attributed(text))
          .themeFont(.subheadline)
          .foregroundStyle(Theme.Ink.secondary)
          .tint(Theme.Accent.tint)
          .textSelection(.enabled)
          .modifier(TextCard())
          .accessibilityIdentifier("mac.detail.reply")
      }
    }
  }

  /// The section label with the button that copies the section as plain text.
  private func sectionHeader(_ title: String, copying target: MacMemoDetailModel.CopyTarget) -> some View {
    let copied = model.copied == target
    return HStack(spacing: Theme.Spacing.sm) {
      DetailSectionLabel(title)
      Button {
        model.copy(target)
      } label: {
        Label(
          copied
            ? String(localized: "Copied", comment: "Detail: confirmation after Copy")
            : String(localized: "Copy", comment: "Detail: copies the section as plain text"),
          systemImage: copied ? "checkmark" : "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .themeFont(.caption, weight: .semibold)
      .foregroundStyle(copied ? Theme.Status.good : Theme.Accent.tint)
      .accessibilityIdentifier("mac.detail.\(target == .transcript ? "transcript" : "reply").copy")
    }
  }

  @ViewBuilder private func footer(_ memo: Memo) -> some View {
    if let count = memo.segmentCount {
      Text(
        verbatim: "\(memo.device) · "
          + String(localized: "\(count) segments", comment: "Footer of the memo detail: uploaded recording segments")
      )
      .themeFont(.caption)
      .foregroundStyle(Theme.Ink.faint)
    }
  }

  private func retry(_ stepID: String) {
    guard let step = MemoStep(rawValue: stepID) else { return }
    Task { await model.retry(from: step) }
  }
}

/// The padded panel under a transcript or reply.
private struct TextCard: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Theme.Spacing.md)
      .detailCard()
  }
}
