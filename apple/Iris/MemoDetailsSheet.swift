import IrisCore
import IrisUI
import SwiftUI

/// The sheet of a memo's details, opened from the toolbar of the transcript screen and of a conversation. It shows one memo's
/// Details (kind chip and meta line, the error of a failed memo, the recording and reply players, step waterfall with Retry rows,
/// copy rows, ids, and the retry bar). A conversation hands over all its memos, oldest first, and the sheet opens on one of them
/// (the newest answer from the toolbar, the turn's own from its context menu); Previous and Next in the toolbar step between
/// them. Each memo reloads when its revision (`memoRevision`, History's) changes.
struct MemoDetailsSheet: View {
  private let memos: [Memo]
  @State private var selected: Int
  private let makeDetail: (Memo) -> MemoDetailModel
  private let memoRevision: (String) -> Int
  /// The transcript screen has the recording's player on screen already.
  private let showsPlayers: Bool
  @Environment(\.dismiss) private var dismiss

  /// - Parameters:
  ///   - memos: The memos to step through, oldest first; never empty.
  ///   - selectedID: The memo the sheet opens on; the newest when it is not among `memos`.
  init(
    memos: [Memo], selectedID: String?, showsPlayers: Bool = true, makeDetail: @escaping (Memo) -> MemoDetailModel,
    memoRevision: @escaping (String) -> Int = { _ in 0 }
  ) {
    self.memos = memos
    _selected = State(initialValue: memos.firstIndex { $0.id == selectedID } ?? max(memos.count - 1, 0))
    self.showsPlayers = showsPlayers
    self.makeDetail = makeDetail
    self.memoRevision = memoRevision
  }

  var body: some View {
    NavigationStack {
      if memos.indices.contains(selected) {
        page(of: memos[selected])
      }
    }
  }

  private func page(of memo: Memo) -> some View {
    BuiltOnce(make: { makeDetail(memo) }) { detail in
      MemoDetailsPage(model: detail, refreshToken: { memoRevision(memo.id) }, showsPlayers: showsPlayers)
    }
    .id(memo.id)
    .navigationTitle(String(localized: "Details", comment: "Title of a memo's details sheet"))
    .navigationSubtitle(position)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if memos.count > 1 {
        ToolbarItemGroup(placement: .topBarLeading) {
          Button(
            String(localized: "Earlier answer", comment: "Details sheet: shows the previous memo"),
            systemImage: "chevron.up"
          ) {
            selected -= 1
          }
          .disabled(selected == 0)
          .accessibilityIdentifier("memo.details.previous")
          Button(
            String(localized: "Later answer", comment: "Details sheet: shows the next memo"),
            systemImage: "chevron.down"
          ) {
            selected += 1
          }
          .disabled(selected == memos.count - 1)
          .accessibilityIdentifier("memo.details.next")
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(String(localized: "Done", comment: "Closes the details sheet")) { dismiss() }
          .accessibilityIdentifier("memo.details.done")
      }
    }
  }

  /// "Answer 2 of 3" under the title when there is more than one; nothing for a single memo.
  private var position: String {
    guard memos.count > 1 else { return "" }
    return String(
      localized: "Answer \(selected + 1) of \(memos.count)",
      comment: "Details sheet subtitle: which memo of the conversation")
  }
}

/// One memo's page of the Details sheet.
private struct MemoDetailsPage: View {
  @State private var model: MemoDetailModel
  @State private var playback: MemoPlayback
  @State private var isRecordingExpanded = false
  private let refreshToken: () -> Int
  private let showsPlayers: Bool

  init(model: MemoDetailModel, refreshToken: @escaping () -> Int, showsPlayers: Bool) {
    _model = State(initialValue: model)
    _playback = State(
      initialValue: MemoPlayback(
        memoID: model.memo.id, recordingDuration: model.memo.audioSeconds ?? 0, speech: model.speech))
    self.refreshToken = refreshToken
    self.showsPlayers = showsPlayers
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.sectionTop) {
        header
        if showsPlayers { players }
        MemoDetailsSection(model: model)
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
          MemoDetailFailureToast(model: model)
          actions
        }
        .floatingBarBackdrop(edge: .bottom)
      }
    }
    .task(id: refreshToken()) { await model.load() }
    .task(id: model.audioRequest) { if showsPlayers { await playback.recording.load(model.audioRequest) } }
    .onAppear { if showsPlayers { playback.attach() } }
    .onDisappear { if showsPlayers { playback.teardown() } }
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
      MemoRecordingPlayer(playback: playback, isExpanded: $isRecordingExpanded)
    }
    if model.canPlayReply {
      ReplyPlayButton(
        isPlaying: playback.isReplyPlaying,
        onPlay: { choice in
          Task { await playback.toggleReply(model.memo, source: model.media, variant: SpeechVariant(choice)) }
        },
        onStop: { playback.speech.pause() })
    }
  }

  @ViewBuilder private var actions: some View {
    if !model.retrySteps.isEmpty {
      MemoDetailActions(model: model)
    }
  }
}
