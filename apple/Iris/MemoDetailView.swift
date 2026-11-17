import IrisCore
import IrisUI
import SwiftUI

/// The detail of a memo that is a document (Transcribe mode, or a deleted memo), top to bottom: headline with the kind chip and one
/// meta line (day, time, cost) and a prominent Copy transcript button, what was said as a bubble with the compact recording player inside it (a pending bubble while the
/// transcript is on its way), then the icon-only retry at the bottom. Details (step waterfall, copy rows, ids) open as a sheet from
/// the toolbar button; a failed memo shows its error in the header and its retry at the bottom without opening anything. A Hermes memo opens the conversation screen instead. It reloads when `refreshToken` changes (History bumps
/// it on a `memo.updated` event).
struct MemoDetailView: View {
  @State private var model: MemoDetailModel
  @State private var playback: MemoPlayback
  @State private var isRecordingExpanded = false
  @State private var showsDetails = false
  private let refreshToken: () -> Int
  /// The transcript is copied, not reread: the bubble shows this many lines, then Show all.
  private static let transcriptLineLimit = 8

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
        MemoDetailFailureToast(model: model)
        MemoDetailActions(model: model)
      }
      .floatingBarBackdrop(edge: .bottom)
    }
    .navigationTitle(String(localized: "Memo", comment: "Navigation title of the memo detail"))
    .reportsScreen("memo.detail")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarVisibility(.hidden, for: .tabBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(
          String(localized: "Details", comment: "Toolbar button that opens a memo's details"),
          systemImage: "info.circle"
        ) {
          showsDetails = true
        }
        .accessibilityIdentifier("memo.details.open")
      }
    }
    .sheet(isPresented: $showsDetails) {
      MemoDetailsSheet(
        memos: [model.memo], selectedID: model.memo.id, showsPlayers: false, makeDetail: { _ in model },
        memoRevision: { _ in refreshToken() })
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
        Text(verbatim: model.metaLine)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
      }
      if memo.state == .failed, let error = memo.error {
        Text(verbatim: error)
          .themeFont(.callout)
          .foregroundStyle(Theme.Status.bad)
      }
      if memo.plainTranscript != nil {
        copyTranscriptButton
          .padding(.top, Theme.Spacing.sm)
      }
    }
  }

  /// The reason most people open a transcript: one prominent button that copies it, confirms in place and taps the haptic.
  private var copyTranscriptButton: some View {
    let isCopied = model.copied == .transcript
    return Button {
      model.copy(.transcript)
    } label: {
      Label(
        isCopied
          ? String(localized: "Copied", comment: "Detail: confirmation after Copy")
          : String(localized: "Copy transcript", comment: "Detail: copies the transcript as plain text"),
        systemImage: isCopied ? "checkmark" : "doc.on.doc"
      )
      .contentTransition(.symbolEffect(.replace))
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.primary)
    .controlSize(.large)
    .animation(.snappy(duration: 0.25), value: isCopied)
    .sensoryFeedback(.success, trigger: model.copyCount)
    .accessibilityIdentifier("detail.copy")
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
          hasFooter: model.audioRequest != nil, collapsedLineLimit: Self.transcriptLineLimit
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
    MemoRecordingPlayer(playback: playback, isExpanded: $isRecordingExpanded)
  }
}
