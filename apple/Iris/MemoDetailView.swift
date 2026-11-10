import IrisCore
import IrisUI
import SwiftUI

/// The detail of a memo that is a document (Transcribe mode, or a deleted memo), top to bottom: headline with the kind chip and one
/// meta line (day, time, cost), what was said as a bubble with the compact recording player inside it (a pending bubble while the
/// transcript is on its way), and Details (step waterfall, copy rows, ids; collapsed, open on a failed memo), then the icon-only
/// retry at the bottom. A Hermes memo opens the conversation screen instead. It reloads when `refreshToken` changes (History bumps
/// it on a `memo.updated` event).
struct MemoDetailView: View {
  @State private var model: MemoDetailModel
  @State private var playback: MemoPlayback
  @State private var isRecordingExpanded = false
  private let refreshToken: () -> Int

  init(model: MemoDetailModel, refreshToken: @escaping () -> Int = { 0 }) {
    _model = State(initialValue: model)
    _playback = State(
      initialValue: MemoPlayback(
        memoID: model.memo.id, recordingDuration: model.memo.audioSeconds ?? 0, speech: model.speech))
    self.refreshToken = refreshToken
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.sectionTop) {
        header
        conversation
        MemoDetailsSection(model: model, onRetry: retry)
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
        Text(verbatim: model.metaLine)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
      }
      if memo.state == .failed, let error = memo.error {
        Text(verbatim: error)
          .themeFont(.callout)
          .foregroundStyle(Theme.Status.bad)
      }
    }
  }

  // MARK: Conversation

  /// What was said: the user's bubble (the transcript, with the recording's player in it), or the pending one while the pipeline
  /// works. A failed memo has the error in the header.
  @ViewBuilder private var conversation: some View {
    let memo = model.memo
    VStack(alignment: .leading, spacing: Theme.Spacing.sectionTop) {
      if let text = memo.plainTranscript {
        UserTurnView(
          text: text, time: memo.timeText, identifier: "detail.transcript", onCopy: { model.copy(.transcript) },
          hasFooter: model.audioRequest != nil
        ) {
          player
        }
      } else if model.audioRequest != nil {
        // Failed or still transcribing: there is a recording to replay but nothing to put in a bubble.
        player
      }
      if memo.state != .failed, !memo.state.isResultReady {
        PendingTurnView(progress: memo.stepProgress, caption: memo.pendingCaption)
      }
    }
  }

  private var player: some View {
    let audio = playback.recording
    return MemoPlayerBar(
      position: audio.position, duration: audio.duration, isPlaying: audio.isPlaying, isEnabled: audio.isLoaded,
      isExpanded: $isRecordingExpanded,
      onToggle: playback.toggleRecording,
      onSeek: { audio.seek(to: $0) },
      onSkipBack: { audio.skipBack() })
  }

  // MARK: Actions

  private var actions: some View {
    DetailActionBar(
      retryOptions: model.retrySteps.map { DetailRetryOption(id: $0.rawValue, title: $0.title) },
      primaryRetryID: model.primaryRetryStep?.rawValue,
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
