import IrisCore
import IrisUI
import SwiftUI

/// What a conversation's turn keeps of the plain memo detail: the sheet of one memo's details. Kind chip and meta line, the
/// error of a failed memo, the recording and reply players, Details (step waterfall with Retry rows, copy rows, ids) and the
/// retry bar. It reloads when `refreshToken` changes (History's revision of the memo).
struct MemoDetailsSheet: View {
  @State private var model: MemoDetailModel
  @State private var playback: MemoPlayback
  @State private var isRecordingExpanded = false
  @Environment(\.dismiss) private var dismiss
  private let refreshToken: () -> Int

  init(model: MemoDetailModel, refreshToken: @escaping () -> Int = { 0 }) {
    _model = State(initialValue: model)
    _playback = State(
      initialValue: MemoPlayback(
        memoID: model.memo.id, recordingDuration: model.memo.audioSeconds ?? 0, speech: model.speech))
    self.refreshToken = refreshToken
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.sectionTop) {
          header
          players
          MemoDetailsSection(model: model, onRetry: retry)
        }
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.xl)
      }
      .accessibilityIdentifier("memo.details")
      .background(Theme.Surface.background)
      .scrollEdgeEffectStyle(.soft, for: .bottom)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if !model.retrySteps.isEmpty || model.failure != nil {
          VStack(spacing: Theme.Spacing.sm) {
            failureToast
            actions
          }
          .floatingBarBackdrop(edge: .bottom)
        }
      }
      .navigationTitle(String(localized: "Details", comment: "Title of a memo's details sheet"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(String(localized: "Done", comment: "Closes the details sheet")) { dismiss() }
            .accessibilityIdentifier("memo.details.done")
        }
      }
    }
    .task(id: refreshToken()) { await model.load() }
    .task(id: model.audioRequest) { await playback.recording.load(model.audioRequest) }
    .onAppear { playback.attach() }
    .onDisappear { playback.teardown() }
  }

  private var header: some View {
    let memo = model.memo
    return VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
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

  @ViewBuilder private var players: some View {
    if model.audioRequest != nil {
      let audio = playback.recording
      MemoPlayerBar(
        position: audio.position, duration: audio.duration, isPlaying: audio.isPlaying, isEnabled: audio.isLoaded,
        isExpanded: $isRecordingExpanded,
        onToggle: playback.toggleRecording,
        onSeek: { audio.seek(to: $0) },
        onSkipBack: { audio.skipBack() })
    }
    if model.canPlayReply {
      ReplyPlayButton(isPlaying: playback.isReplyPlaying) {
        Task { await playback.toggleReply(model.memo, source: model.media) }
      }
    }
  }

  @ViewBuilder private var actions: some View {
    if !model.retrySteps.isEmpty {
      DetailActionBar(
        retryOptions: model.retrySteps.map { DetailRetryOption(id: $0.rawValue, title: $0.title) },
        primaryRetryID: model.primaryRetryStep?.rawValue,
        onRetry: retry
      )
      .frame(maxWidth: .infinity)
      .padding(.vertical, Theme.Spacing.sm)
    }
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
