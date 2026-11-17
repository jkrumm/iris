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
  @Environment(TakeModel.self) private var take: TakeModel?
  private let refreshToken: () -> Int
  /// The transcript is copied, not reread: the bubble shows this many lines, then Show full message.
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
      if model.wholeTranscript != nil {
        copyTranscriptButton
          .padding(.top, Theme.Spacing.sm)
      }
      if let target = model.continuationTarget {
        continueRecordingButton(thread: target)
      }
    }
  }

  /// Records another part of this transcript: a Transcribe take bound to its first part. The new text lands below the earlier
  /// parts once it is transcribed; offline the take waits in the outbox like any other.
  private func continueRecordingButton(thread: String) -> some View {
    Button {
      Task { await take?.start(mode: .transcribe, threadID: thread) }
    } label: {
      Label(
        String(localized: "Continue recording", comment: "Detail: records another part of this transcript"),
        systemImage: MemoMode.transcribe.recordIcon
      )
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(Theme.Accent.tint)
    .controlSize(.large)
    .disabled(take?.canStart != true)
    .accessibilityHint(
      String(localized: "Records more and adds the text below this transcript.", comment: "Detail: hint")
    )
    .accessibilityIdentifier("detail.continue")
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

  /// What was said: one bubble per part of the transcript, oldest first (the open recording's player in its own), or the pending
  /// bubble while the pipeline works. A failed memo has the error in the header, a failed later part under its bubble.
  @ViewBuilder private var conversation: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sectionTop) {
      ForEach(model.parts) { part in
        partView(part)
      }
    }
  }

  @ViewBuilder private func partView(_ part: Memo) -> some View {
    let isOpen = part.id == model.memo.id
    VStack(alignment: .leading, spacing: Theme.Spacing.sectionTop) {
      if let text = part.plainTranscript {
        let showsPlayer = isOpen && model.audioRequest != nil
        UserTurnView(
          text: text, time: part.timeText, identifier: isOpen ? "detail.transcript" : "detail.transcript.part",
          onCopy: { model.copyPart(part) }, hasFooter: showsPlayer, gist: part.transcriptGist,
          collapsedLineLimit: Self.transcriptLineLimit
        ) {
          if showsPlayer { player }
        }
      } else if isOpen, model.audioRequest != nil {
        // Failed or still transcribing: there is a recording to replay but nothing to put in a bubble.
        player
      }
      if part.state == .failed, !isOpen, let error = part.error {
        Text(verbatim: error)
          .themeFont(.callout)
          .foregroundStyle(Theme.Status.bad)
      } else if part.state != .failed, !part.state.isResultReady {
        PendingTurnView(progress: part.stepProgress, caption: part.pendingCaption)
      }
    }
  }

  private var player: some View {
    MemoRecordingPlayer(playback: playback, isExpanded: $isRecordingExpanded)
  }
}
