import IrisCore
import IrisUI
import SwiftUI

/// The memo detail, top to bottom: headline with the kind chip and one meta line, the reply, the recording's player, the
/// transcript, and Details (step waterfall, ids; collapsed, open on a failed memo), then the icon-only actions at the
/// bottom. It reloads when `refreshToken` changes (History bumps it on a `memo.updated` event).
struct MemoDetailView: View {
  @State private var model: MemoDetailModel
  @State private var playback: MemoPlayback
  private let refreshToken: () -> Int
  private let onReply: (Memo) -> Void

  /// - Parameters:
  ///   - onReply: The reply hook: History opens the composer from here, continuing `memo.threadId`.
  init(
    model: MemoDetailModel, refreshToken: @escaping () -> Int = { 0 }, onReply: @escaping (Memo) -> Void = { _ in }
  ) {
    _model = State(initialValue: model)
    _playback = State(
      initialValue: MemoPlayback(
        memoID: model.memo.id, recordingDuration: model.memo.audioSeconds ?? 0, speech: model.speech))
    self.refreshToken = refreshToken
    self.onReply = onReply
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.sectionTop) {
        header
        reply
        actionsLine
        if model.audioRequest != nil { player }
        transcript
        details
      }
      .padding(.horizontal, Theme.Spacing.screenMargin)
      .padding(.top, Theme.Spacing.sm)
      .padding(.bottom, Theme.Spacing.xl)
    }
    .accessibilityIdentifier("memo.detail")
    .takeBanner()
    .background(Theme.Surface.background)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: Theme.Spacing.sm) {
        failureToast
        actions
      }
      .floatingBarBackdrop(edge: .bottom)
    }
    .navigationTitle(String(localized: "Memo", comment: "Navigation title of the memo detail"))
    .reportsScreen("memo.detail")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarVisibility(.hidden, for: .tabBar)
    .toolbar {
      if let route = model.memo.threadRoute {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink(value: route) {
            Label(
              String(localized: "Conversation", comment: "Opens the thread this memo belongs to"),
              systemImage: "bubble.left.and.bubble.right")
          }
          .accessibilityIdentifier("detail.conversation")
        }
      }
    }
    .task(id: refreshToken()) { await model.load() }
    .task(id: model.audioRequest) { await playback.recording.load(model.audioRequest) }
    .onAppear { playback.attach() }
    .onDisappear { playback.teardown() }
  }

  // MARK: Sections

  private var header: some View {
    let memo = model.memo
    return VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
      Text(verbatim: memo.rowHeadline)
        .themeFont(.title, weight: .bold)
        .foregroundStyle(Theme.Ink.primary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: Theme.Spacing.sm) {
        KindChip(label: memo.kindLabel, systemImage: memo.kindIcon)
        Text(verbatim: metaLine(memo))
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
      }
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

  /// Time · recording length · what the run cost; the steps' own cost is in Details.
  private func metaLine(_ memo: Memo) -> String {
    [
      memo.timeText, memo.audioSeconds.map(DurationText.string(seconds:)),
      model.totalCostUsd.map { StepText.dollars($0) },
    ]
    .compactMap { $0 }.joined(separator: " · ")
  }

  private var player: some View {
    let audio = playback.recording
    return MemoPlayerBar(
      position: audio.position, duration: audio.duration, isPlaying: audio.isPlaying, isEnabled: audio.isLoaded,
      onToggle: playback.toggleRecording,
      onSeek: { audio.seek(to: $0) },
      onSkipBack: { audio.skipBack() })
  }

  /// Details: the line reads the run's total time and cost; opened it shows every step (duration, cost, attempts, the
  /// failed step's retry) and the ids. Collapsed unless the memo failed (see ``MemoDetailModel/isWaterfallExpanded``).
  @ViewBuilder private var details: some View {
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
      onRetry: retry
    ) {
      idsFooter
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

  @ViewBuilder private var transcript: some View {
    if let text = model.memo.transcript {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        sectionHeader(String(localized: "Transcript", comment: "Section label of the transcript"), copying: .transcript)
        Text(verbatim: text)
          .themeFont(.callout)
          .foregroundStyle(Theme.Ink.primary)
          .textSelection(.enabled)
          .modifier(TextCard())
          .accessibilityIdentifier("detail.transcript")
      }
    }
  }

  @ViewBuilder private var reply: some View {
    if let text = model.memo.replyText {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        sectionHeader(String(localized: "Reply", comment: "Section label of the reply"), copying: .reply)
        Text(ReplyMarkdown.attributed(text))
          .themeFont(.subheadline)
          .foregroundStyle(Theme.Ink.secondary)
          .tint(Theme.Accent.tint)
          .textSelection(.enabled)
          .modifier(TextCard())
          .accessibilityIdentifier("detail.reply")
      }
    }
  }

  /// What Hermes used for the memo, one quiet line under the reply; nothing when it used no tool.
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
      .accessibilityIdentifier("detail.actions")
    }
  }

  /// The section label with the button that copies the section as plain text.
  private func sectionHeader(_ title: String, copying target: MemoDetailModel.CopyTarget) -> some View {
    let copied = model.copied == target
    let name = target == .transcript ? "transcript" : "reply"
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
      .sensoryFeedback(.success, trigger: copied) { _, now in now }
      .accessibilityIdentifier("detail.\(name).copy")
    }
  }

  // MARK: Actions

  private var actions: some View {
    DetailActionBar(
      isPlayingReply: playback.isReplyPlaying,
      canPlayReply: model.canPlayReply,
      canReply: model.canReply,
      retryOptions: model.retrySteps.map { DetailRetryOption(id: $0.rawValue, title: $0.title) },
      primaryRetryID: model.primaryRetryStep?.rawValue,
      onPlayReply: { Task { await playback.toggleReply(model.memo, source: model.media) } },
      onReply: { onReply(model.memo) },
      onRetry: retry
    )
    .frame(maxWidth: .infinity)
    .padding(.vertical, Theme.Spacing.sm)
  }

  private func retry(_ stepID: String) {
    guard let step = MemoStep(rawValue: stepID) else { return }
    Task { await model.retry(from: step) }
  }

  @ViewBuilder private var failureToast: some View {
    if let failure = model.failure {
      ToastBanner(message: failure.message)
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("detail.toast")
    }
  }
}

/// The padded panel under a transcript or reply.
private struct TextCard: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
      .padding(.vertical, Theme.Spacing.cardInsetVertical)
      .detailCard()
  }
}
