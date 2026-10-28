import IrisCore
import IrisUI
import SwiftUI

/// The memo detail: headline, the recording's player, the step waterfall, transcript and reply, and the icon-only
/// actions at the bottom. It reloads when `refreshToken` changes (History bumps it on a `memo.updated` event).
struct MemoDetailView: View {
  @State private var model: MemoDetailModel
  @State private var playback: MemoPlayback
  private let refreshToken: () -> Int
  private let onReply: (Memo) -> Void

  /// - Parameter onReply: The reply hook: History opens the composer from here, continuing `memo.threadId`.
  init(model: MemoDetailModel, refreshToken: @escaping () -> Int = { 0 }, onReply: @escaping (Memo) -> Void = { _ in })
  {
    _model = State(initialValue: model)
    _playback = State(initialValue: MemoPlayback(recordingDuration: model.memo.audioSeconds ?? 0))
    self.refreshToken = refreshToken
    self.onReply = onReply
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        header
        if model.audioRequest != nil { player }
        steps
        transcript
        reply
        footer
      }
      .padding(.horizontal, Theme.Spacing.lg)
      .padding(.top, Theme.Spacing.sm)
      .padding(.bottom, Theme.Spacing.xl)
    }
    .accessibilityIdentifier("memo.detail")
    .background(Theme.Surface.background)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaInset(edge: .bottom) { actions }
    .overlay(alignment: .bottom) { failureToast }
    .navigationTitle(String(localized: "Memo", comment: "Navigation title of the memo detail"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbarVisibility(.hidden, for: .tabBar)
    .task(id: refreshToken()) { await model.load() }
    .task(id: model.audioRequest) { await playback.recording.load(model.audioRequest) }
    .task(id: model.failure) {
      guard model.failure != nil, (try? await Task.sleep(for: .seconds(4))) != nil else { return }
      model.dismissFailure()
    }
    .onDisappear { playback.teardown() }
  }

  // MARK: Sections

  private var header: some View {
    let memo = model.memo
    return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.sm) {
        RouteChip(label: memo.routeLabel, systemImage: "arrow.triangle.branch")
        Text(verbatim: metaLine(memo))
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
      }
      Text(verbatim: memo.rowHeadline)
        .themeFont(.title, weight: .bold)
        .foregroundStyle(Theme.Ink.primary)
        .fixedSize(horizontal: false, vertical: true)
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

  private func metaLine(_ memo: Memo) -> String {
    [memo.timeText, memo.audioSeconds.map(DurationText.string(seconds:))].compactMap { $0 }.joined(separator: " · ")
  }

  private var player: some View {
    let audio = playback.recording
    return MemoPlayerBar(
      position: audio.position, duration: audio.duration, isPlaying: audio.isPlaying, isEnabled: audio.isLoaded,
      onToggle: playback.toggleRecording,
      onSeek: { audio.seek(to: $0) },
      onSkipBack: { audio.skipBack() })
  }

  @ViewBuilder private var steps: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      DetailSectionLabel(String(localized: "Steps", comment: "Section label of the step waterfall"))
      if model.memo.state.isResultReady {
        waterfall(now: .now)
      } else {
        // A running step's bar grows with the clock.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          waterfall(now: context.date)
        }
      }
    }
  }

  private func waterfall(now: Date) -> some View {
    StepWaterfall(
      rows: model.rows(now: now),
      totalTitle: model.memo.state.isResultReady
        ? String(localized: "Total", comment: "Footer of the step waterfall")
        : String(localized: "Total so far", comment: "Footer of the step waterfall while the memo runs"),
      totalValue: model.totalValue(now: now),
      onRetry: retry)
  }

  @ViewBuilder private var transcript: some View {
    if let text = model.memo.transcript {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        DetailSectionLabel(String(localized: "Transcript", comment: "Section label of the transcript"))
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
        DetailSectionLabel(String(localized: "Reply", comment: "Section label of the reply"))
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

  @ViewBuilder private var footer: some View {
    if let count = model.memo.segmentCount {
      Text(
        verbatim: "\(model.memo.device) · "
          + String(localized: "\(count) segments", comment: "Footer of the memo detail: uploaded recording segments")
      )
      .themeFont(.caption)
      .foregroundStyle(Theme.Ink.faint)
    }
  }

  // MARK: Actions

  private var actions: some View {
    DetailActionBar(
      isPlayingReply: playback.reply.isPlaying,
      canPlayReply: model.canPlayReply,
      canReply: model.canReply,
      retryOptions: model.retrySteps.map { DetailRetryOption(id: $0.rawValue, title: $0.title) },
      primaryRetryID: model.primaryRetryStep?.rawValue,
      onPlayReply: { Task { await playback.toggleReply(loading: model.speechRequest) } },
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
      ToastBanner(message: failure)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, 96)
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
      .padding(Theme.Spacing.md)
      .detailCard()
  }
}
