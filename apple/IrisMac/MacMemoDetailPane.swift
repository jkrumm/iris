import IrisCore
import IrisUI
import SwiftUI

/// The main window's detail column. A Hermes memo is a chat (`Memo.isConversation`): the headline and one quiet metadata line, the
/// conversation as bubbles and the composer pinned at the foot to reply. A
/// transcribe-mode memo keeps the document layout: reply, summary and transcript as plain sections
/// with small uppercase labels, and no composer. Actions sit in the window toolbar, Details (steps, copy rows, ids, per answer) in a
/// popover from its Details button. It reloads when `refreshToken` changes (the
/// window's list bumps a memo's revision on its `memo.updated` event, for any memo of the open conversation), so a running turn
/// becomes its answer in place.
struct MacMemoDetailPane: View {
  let root: MacCompositionRoot
  let player: MacAudioPlayer
  @State private var model: MacMemoDetailModel
  @State private var zoomed: MacZoomedDiagram?
  @State private var artifactBudget = ArtifactIslandBudget()
  @Environment(\.openWindow) private var openWindow
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
          .environment(\.artifactIslandBudget, artifactBudget)
          .environment(\.openArtifact, OpenArtifactAction { openWindow(id: MacWindowID.artifact, value: $0) })
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
    // The running turn streams in: the window's list multicasts the stream's tool and text events.
    .task {
      for await event in root.windowHistory.liveEvents() { await model.apply(event) }
    }
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

  /// The open memo's revision, the revisions of every memo of its conversation and the list's activity of the thread (a turn another
  /// device adds), and the stream's returns: any of them moving reloads the pane.
  private var refreshToken: Int {
    let history = root.windowHistory
    var token = history.revision(of: model.memoID) + root.reconnects
    if let thread = model.thread {
      token += thread.memos.reduce(0) { $0 + history.revision(of: $1.id) }
    }
    // A transcript's first part has no thread until something continues it: its own id names the thread then.
    if let threadId = model.memo?.threadId ?? model.memo?.transcriptThreadID {
      token = token &+ history.threadActivity(threadId)
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

  /// The conversation as bubbles.
  @ViewBuilder private func chat(_ memo: Memo) -> some View {
    MacConversationView(
      turns: model.turns, onCopy: { model.copyTurn($0) }, onOpenImage: { zoomed = MacZoomedDiagram(image: $0) }
    )
    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: model.turns)
    // Only a conversation of several memos is worth a warning; a memo alone in its session has its own turns to show.
    if model.threadFailed && model.continuesThread {
      Label(
        String(localized: "Could not load the conversation", comment: "Detail: a thread could not be read"),
        systemImage: "exclamationmark.triangle"
      )
      .macFont(.body)
      .foregroundStyle(Theme.Status.warn)
      .accessibilityIdentifier("mac.detail.conversation-error")
    }
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

  /// The list's row of the open memo: for a conversation its newest memo (the state and the thread's favorite), which the flags act on.
  private var listRow: Memo? {
    model.memo.flatMap { root.windowHistory.row(for: $0) }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    if let memo = liveMemo {
      let bar = MacDetailToolbar(root: root, model: model, player: player, memo: memo, row: listRow)
      ToolbarItemGroup(placement: .primaryAction) { bar.primary }
      ToolbarItemGroup(placement: .primaryAction) { bar.flags }
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
