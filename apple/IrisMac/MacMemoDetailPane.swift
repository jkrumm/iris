import IrisCore
import IrisUI
import SwiftUI

/// The main window's detail column. A memo in a Hermes session is a chat: the headline and one quiet metadata line, the
/// conversation as bubbles, Details (steps, ids) in a disclosure group, and the composer pinned at the foot to reply. A memo
/// without one (a transcript, one that failed before `act`) keeps the document layout: reply, summary and transcript as plain sections
/// with small uppercase labels, and no composer. Actions sit in the window toolbar. It reloads when `refreshToken` changes (the
/// window's list bumps a memo's revision on its `memo.updated` event, for any memo of the open conversation), so a running turn
/// becomes its answer in place.
struct MacMemoDetailPane: View {
  let root: MacCompositionRoot
  let player: MacAudioPlayer
  @State private var model: MacMemoDetailModel
  @State private var zoomed: MacZoomedDiagram?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let bottom = "mac.detail.bottom"

  init(root: MacCompositionRoot, model: MacMemoDetailModel, player: MacAudioPlayer) {
    self.root = root
    self.player = player
    _model = State(initialValue: model)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        content
          .frame(maxWidth: Theme.Spacing.macReadableWidth, alignment: .leading)
          .padding(Theme.Spacing.macDetailMargin)
          .frame(maxWidth: .infinity)
      }
      // A conversation opens at its newest turn; a document at its top.
      .defaultScrollAnchor(model.isChat ? UnitPoint.bottom : UnitPoint.top, for: .initialOffset)
      .onChange(of: model.turns.last?.id) {
        withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
      }
    }
    .background(Theme.Surface.background)
    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
    .toolbar { toolbar }
    .task(id: refreshToken) { await model.load() }
    // A memo opened from the popover or a banner may be past the window's filter or pages: the list takes it in, so its actions find it.
    .task(id: model.memo?.id) {
      guard let memo = model.memo else { return }
      await root.ensureHeld(memo)
    }
    .sheet(item: $zoomed) { item in
      MacDiagramSheet(image: item.image, onClose: { zoomed = nil })
    }
    .accessibilityIdentifier("mac.detail")
  }

  /// The open memo's revision, the revisions of every memo of its conversation and how many the list holds of it, and the stream's
  /// returns: any of them moving reloads the pane.
  private var refreshToken: Int {
    let history = root.windowHistory
    var token = history.revision(of: model.memoID) + root.reconnects
    if let thread = model.thread {
      token += thread.memos.reduce(0) { $0 + history.revision(of: $1.id) }
    }
    if let threadId = model.memo?.threadId {
      token += history.memos.count { $0.threadId == threadId }
    }
    return token
  }

  @ViewBuilder private var content: some View {
    if let memo = model.memo {
      VStack(alignment: .leading, spacing: Theme.Spacing.macSectionGap) {
        MacMemoHeader(memo: memo, totals: totals, showsError: !model.isChat)
        if let failure = player.failure, player.failedMemoID == memo.id {
          Label(failure, systemImage: "speaker.slash")
            .macFont(.body)
            .foregroundStyle(Theme.Status.bad)
            .accessibilityIdentifier("mac.detail.player-failure")
        }
        if model.isChat {
          chat(memo)
        } else {
          MacMemoSections(model: model)
        }
        if let failure = model.failure {
          Text(verbatim: failure).macFont(.body).foregroundStyle(Theme.Status.bad)
            .accessibilityIdentifier("mac.detail.failure")
        }
        Color.clear.frame(height: 1).id(Self.bottom)
      }
    } else if model.loadFailed {
      ContentUnavailableView(
        String(localized: "Could not load the memo", comment: "Detail error title"),
        systemImage: "exclamationmark.triangle")
    } else {
      ProgressView().frame(maxWidth: .infinity).padding(Theme.Spacing.xl)
    }
  }

  /// The conversation as bubbles, what Hermes used, and the steps.
  @ViewBuilder private func chat(_ memo: Memo) -> some View {
    MacConversationView(
      turns: model.turns, onCopy: { model.copyTurn($0) }, onOpenImage: { zoomed = MacZoomedDiagram(image: $0) }
    )
    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: model.turns)
    // Only a conversation of several memos is worth a warning; a memo alone in its session has its own turns to show.
    if model.threadFailed && model.isConversation {
      Label(
        String(localized: "Could not load the conversation", comment: "Detail: a thread could not be read"),
        systemImage: "exclamationmark.triangle"
      )
      .macFont(.body)
      .foregroundStyle(Theme.Status.warn)
      .accessibilityIdentifier("mac.detail.conversation-error")
    }
    MacActionsLine(memo: memo)
    MacMemoDetails(model: model)
  }

  /// The composer of the memo's conversation, pinned to the foot of the pane.
  @ViewBuilder private var composer: some View {
    if model.isChat, let threadId = model.replyThreadID {
      MacComposerBar(root: root, model: root.composer(for: threadId))
    }
  }

  private var totals: WaterfallBuilder.Totals? {
    model.detail.flatMap { WaterfallBuilder.totals(for: $0, now: .now) }
  }

  // MARK: Toolbar

  /// The memo as the list has it (a flag toggled a moment ago shows at once), else the detail's.
  private var liveMemo: Memo? {
    root.windowHistory.memos.first { $0.id == model.memoID } ?? model.memo
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    if let memo = liveMemo {
      let actions = MacMemoActions(root: root, model: root.windowHistory)
      ToolbarItemGroup(placement: .primaryAction) {
        playButtons(memo)
        copyMenu
        retryControl
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button(
          memo.favorite
            ? String(localized: "Unfavorite", comment: "Context menu")
            : String(localized: "Favorite", comment: "Context menu"),
          systemImage: memo.favorite ? "star.fill" : "star"
        ) { actions.toggleFavorite(memo) }
        .help(
          memo.favorite
            ? String(localized: "Unfavorite", comment: "Context menu")
            : String(localized: "Favorite", comment: "Context menu"))
        Button(
          memo.archived
            ? String(localized: "Unarchive", comment: "Context menu")
            : String(localized: "Archive", comment: "Context menu"),
          systemImage: memo.archived ? "tray.and.arrow.up" : "archivebox"
        ) { actions.toggleArchived(memo) }
        if memo.state.isDeletable {
          Button(String(localized: "Delete", comment: "Context menu"), systemImage: "trash") { actions.delete(memo) }
            .disabled(root.deletingIDs.contains(memo.id))
        }
      }
    }
  }

  @ViewBuilder private func playButtons(_ memo: Memo) -> some View {
    let source = root.mediaSource
    if let request = source.audio(for: memo) {
      let playing = player.isCurrent(memo.id, .recording)
      Button(
        playing
          ? String(localized: "Stop recording", comment: "Detail toolbar: stops the recording")
          : String(localized: "Play recording", comment: "Detail toolbar: plays the recording"),
        systemImage: playing ? "stop.fill" : "play.fill"
      ) { player.toggle(memo.id, .recording, request: request) }
      .help(String(localized: "Play recording", comment: "Detail toolbar: plays the recording"))
      .accessibilityIdentifier("mac.detail.play-recording")
    }
    if let request = source.speech(for: memo) {
      let playing = player.isCurrent(memo.id, .reply)
      Button(
        playing
          ? String(localized: "Stop reply", comment: "Detail toolbar: stops the spoken reply")
          : String(localized: "Play reply", comment: "Detail toolbar: plays the spoken reply"),
        systemImage: playing ? "stop.circle.fill" : "speaker.wave.2"
      ) { player.toggle(memo.id, .reply, request: request) }
      .help(String(localized: "Play reply", comment: "Detail toolbar: plays the spoken reply"))
      .accessibilityIdentifier("mac.detail.play-reply")
    }
  }

  @ViewBuilder private var copyMenu: some View {
    if let memo = model.memo, memo.transcript != nil || memo.replyText != nil {
      Menu {
        if memo.transcript != nil {
          Button(String(localized: "Copy transcript", comment: "Detail toolbar menu")) { model.copy(.transcript) }
        }
        if memo.replyText != nil {
          Button(String(localized: "Copy reply", comment: "Detail toolbar menu")) { model.copy(.reply) }
        }
      } label: {
        Label(
          model.copied == nil
            ? String(localized: "Copy", comment: "Detail: copies the section as plain text")
            : String(localized: "Copied", comment: "Detail: confirmation after Copy"),
          systemImage: model.copied == nil ? "doc.on.doc" : "checkmark")
      }
      .accessibilityIdentifier("mac.detail.copy")
    }
  }

  @ViewBuilder private var retryControl: some View {
    let steps = model.retrySteps
    if steps.count == 1, let step = steps.first {
      Button(
        String(localized: "Retry", comment: "Detail toolbar: retries a failed step"), systemImage: "arrow.clockwise"
      ) { Task { await model.retry(from: step) } }
      .help(String(localized: "Retry from \(step.title)", comment: "Button on the step a memo failed at"))
      .disabled(model.isRetrying)
      .accessibilityIdentifier("mac.detail.retry")
    } else if steps.count > 1 {
      Menu {
        ForEach(steps, id: \.self) { step in
          Button(String(localized: "Retry from \(step.title)", comment: "Button on the step a memo failed at")) {
            Task { await model.retry(from: step) }
          }
        }
      } label: {
        Label(
          String(localized: "Retry", comment: "Detail toolbar: retries a failed step"), systemImage: "arrow.clockwise")
      }
      .disabled(model.isRetrying)
      .accessibilityIdentifier("mac.detail.retry")
    }
  }
}

/// The headline (18 pt semibold, selectable) and one quiet line under it: what it is, when, how long, what it cost.
private struct MacMemoHeader: View {
  let memo: Memo
  let totals: WaterfallBuilder.Totals?
  /// A chat shows a failure as its failed turn, so the header does not repeat it.
  let showsError: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.macHeaderGap) {
      Text(verbatim: memo.rowHeadline)
        .macFont(.title, weight: .semibold)
        .foregroundStyle(Theme.Ink.primary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: Theme.Spacing.snug) {
        KindChip(label: memo.kindLabel, systemImage: memo.kindIcon)
          .accessibilityIdentifier("mac.detail.kind")
        Text(verbatim: metadata).lineLimit(1)
      }
      .macFont(.caption)
      .foregroundStyle(Theme.Ink.muted)
      if showsError, memo.state == .failed, let error = memo.error {
        Text(verbatim: error).macFont(.body).foregroundStyle(Theme.Status.bad)
          .textSelection(.enabled)
      }
    }
  }

  private var metadata: String {
    [
      memo.createdAt.formatted(date: .abbreviated, time: .shortened),
      memo.audioSeconds.map(DurationText.string(seconds:)),
      totals?.costUsd.map { StepText.dollars($0) },
    ]
    .compactMap { $0 }.joined(separator: " · ")
  }
}
