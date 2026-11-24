import CoreGraphics
import IrisCore
import IrisUI
import SwiftUI

/// One conversation as a rendered document: a turn per question and answer, an answer still on its way as a pending
/// turn with the pipeline's dashes, and a bar at the bottom to reply by text or hold to talk. The toolbar's Details button opens
/// the details sheet on the newest answer (earlier ones one step away), a bubble's context menu on its own memo, and a failed
/// turn has its Retry under it. It reloads when `refreshToken` changes (History bumps a memo's revision on its
/// `memo.updated` event), and the reply replaces the pending turn with a short fade.
struct ThreadView: View {
  @State private var model: ThreadModel
  @State private var zoomed: ZoomedImage?
  @State private var details: DetailsTarget?
  /// The shared speech player and media routes, through the detail model the app builds for the anchor: what the answers' play
  /// controls speak with.
  @State private var voice: MemoDetailModel?
  /// A reply was started from this screen's controls: leaving stops it, as it does on the Details screen.
  @State private var startedReply = false
  @State private var artifactBudget = ArtifactIslandBudget()
  private let refreshToken: (_ threadID: String?, _ memoIDs: [String]) -> Int
  private let makeDetail: (Memo) -> MemoDetailModel
  private let memoRevision: (String) -> Int
  private let liveEvents: () -> AsyncStream<ServerEvent>
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @Environment(ConversationRouter.self) private var router: ConversationRouter?
  @Environment(ConversationPresence.self) private var presence: ConversationPresence?
  /// Counts the keyboard requests of a link or notification (the reply bar focuses its field on each).
  @State private var keyboardRequest = 0

  private struct ZoomedImage: Identifiable {
    let id = UUID()
    let image: CGImage
  }

  private struct PresenceKey: Equatable {
    let threadID: String?
    let memoIDs: [String]
  }

  /// The memo the Details sheet opens on; the sheet steps through all the conversation's memos.
  private struct DetailsTarget: Identifiable {
    let memoID: String
    var id: String { memoID }
  }

  /// - Parameters:
  ///   - refreshToken: Folds what History knows of this conversation (its memos' revisions, its memo count) into one number the screen reloads on.
  ///   - makeDetail: Builds the model of a memo's Details sheet, and the Retry of a failed turn.
  ///   - memoRevision: History's revision of one memo, which the Details sheet reloads on.
  ///   - liveEvents: A stream of the live events (`ready`, `memo.delta`, `memo.activity`) while the screen is up; the default ends at once.
  ///   - onSent: Told of every memo this screen creates (History lists it at once).
  init(
    model: ThreadModel, refreshToken: @escaping (_ threadID: String?, _ memoIDs: [String]) -> Int = { _, _ in 0 },
    makeDetail: @escaping (Memo) -> MemoDetailModel, memoRevision: @escaping (String) -> Int = { _ in 0 },
    onSent: @escaping (Memo) -> Void = { _ in },
    liveEvents: @escaping () -> AsyncStream<ServerEvent> = { AsyncStream { $0.finish() } }
  ) {
    model.onSent = onSent
    _model = State(initialValue: model)
    self.refreshToken = refreshToken
    self.makeDetail = makeDetail
    self.memoRevision = memoRevision
    self.liveEvents = liveEvents
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.turnGap) {
          header
          ConversationTurnList(
            turns: model.turns, style: .phone, dayTitle: { HistoryDaySection.title(of: $0) },
            onOpenImage: { zoomed = ZoomedImage(image: $0) },
            onDetails: { details = DetailsTarget(memoID: $0) },
            onRetry: { id in
              guard let memo = model.memo(id: id) else { return }
              Task { await model.retry(makeDetail(memo)) }
            },
            reply: replyControls)
          Color.clear.frame(height: 1).id(Self.bottom)
        }
        .environment(\.artifactIslandBudget, artifactBudget)
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .padding(.top, Theme.Spacing.inset)
        .padding(.bottom, Theme.Spacing.lg)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: model.turns.map(\.id))
      }
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      // Sticks to the bottom while the content grows, unless the user scrolled up.
      .defaultScrollAnchor(.bottom, for: .sizeChanges)
      // The memo, not the turn: pending, streaming and the reply of one memo never pull a user who scrolled up.
      .onChange(of: model.turns.last?.memoID ?? model.turns.last?.id) {
        withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
      }
    }
    .accessibilityIdentifier("thread.view")
    .takeBanner()
    .background(Theme.Surface.background)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .overlay { placeholder }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: Theme.Spacing.barGap) {
        failureToast
        replyBar
      }
      .floatingBarBackdrop(edge: .bottom)
    }
    // Solid behind the status bar and the inline navigation bar: scrolled text never ghosts through the glass.
    .statusBarScrim()
    .navigationTitle(String(localized: "Conversation", comment: "Navigation title of a thread"))
    .reportsScreen("thread")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarVisibility(.hidden, for: .tabBar)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(
          String(localized: "Details", comment: "Toolbar button that opens a memo's details"),
          systemImage: "info.circle"
        ) {
          if let newest = model.memos.last { details = DetailsTarget(memoID: newest.id) }
        }
        .accessibilityIdentifier("thread.details")
      }
    }
    .task(id: refreshToken(model.threadID, model.memoIDs)) { await model.load() }
    .task {
      for await event in liveEvents() { await model.apply(event) }
    }
    .onAppear {
      model.reclaimHeld()
      if voice == nil { voice = makeDetail(model.anchor) }
    }
    // A link or notification opened this conversation with an input forward. `.voice` is Part B's: the router's pending request
    // carries it and the take starts there; here it opens like `.none`.
    .onChange(of: router?.focusRevision, initial: true) {
      guard router?.takeFocus(forAnyOf: Set(model.memoIDs)) == .keyboard else { return }
      keyboardRequest += 1
    }
    .onChange(of: PresenceKey(threadID: model.threadID, memoIDs: model.memoIDs), initial: true) {
      presence?.show(anchorID: model.anchor.id, threadID: model.threadID, memoIDs: model.memoIDs)
    }
    .onDisappear {
      stopReplyStartedHere()
      presence?.hide(anchorID: model.anchor.id)
      cancelVoice()
      model.handOver()
    }
    .onChange(of: scenePhase) {
      // `.inactive` too (Control Center, a call, a system alert): the finger is gone either way.
      if scenePhase != .active { cancelVoice() }
    }
    .sheet(item: $details) { target in
      MemoDetailsSheet(
        memos: model.memos, selectedID: target.memoID, makeDetail: makeDetail, memoRevision: memoRevision)
    }
    .fullScreenCover(item: $zoomed) { item in
      ZoomableImageView(
        image: item.image, title: String(localized: "Diagram", comment: "Title of the full diagram view"),
        onClose: { zoomed = nil })
    }
  }

  private static let bottom = "thread.bottom"

  /// The inline player of each finished answer that can speak: the summary or the full reply, through the app's one player.
  private var replyControls: ReplyControls? {
    guard let voice else { return nil }
    let speech = voice.speech
    return ReplyControls(
      playback: { id in
        guard speech.memoID == id else { return .idle }
        let player = speech.player
        return ReplyPlayback(
          isActive: player.isLoaded || player.isLoading, isPlaying: player.isPlaying, isLoading: player.isLoading,
          position: player.position, duration: player.duration, choice: speech.variant.map(ReplyPlayChoice.init))
      },
      canPlay: { id in model.memo(id: id).map { voice.media.speech(for: $0) != nil } ?? false },
      onToggle: { id in
        guard let memo = model.memo(id: id) else { return }
        startedReply = true
        // What the player holds for this memo pauses or resumes in its own form; nothing held starts the summary.
        let variant: SpeechVariant? = speech.memoID == id ? speech.variant : SpeechVariant.summary
        Task { await speech.toggle(memo, source: voice.media, variant: variant) }
      },
      onPlay: { id, choice in
        guard let memo = model.memo(id: id) else { return }
        startedReply = true
        Task { await speech.toggle(memo, source: voice.media, variant: SpeechVariant(choice)) }
      },
      onSeek: { id, seconds in
        guard speech.memoID == id else { return }
        speech.player.seek(to: seconds)
      })
  }

  // MARK: Sections

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
      Text(verbatim: model.title)
        .themeFont(.title, weight: .bold)
        .foregroundStyle(Theme.Ink.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: Theme.Spacing.sm) {
        KindChip(
          label: String(localized: "Thread", comment: "Kind chip of a conversation screen"),
          systemImage: "bubble.left.and.bubble.right")
        if model.turnCount > 0 {
          Text(verbatim: ThreadCopy.turnCount(model.turnCount))
            .themeFont(.footnote)
            .foregroundStyle(Theme.Ink.muted)
        }
        if let first = model.turns.first?.date {
          Text(verbatim: "· \(HistoryDaySection.title(of: first))")
            .themeFont(.footnote)
            .foregroundStyle(Theme.Ink.muted)
        }
      }
    }
  }

  /// Only when there is nothing to show: the anchor's own turns stand in for a thread that has not loaded.
  @ViewBuilder private var placeholder: some View {
    if model.detail == nil && model.turns.isEmpty {
      if model.loadFailed {
        ContentUnavailableView {
          Label(
            String(localized: "Could not load the conversation", comment: "Thread error title"),
            systemImage: "exclamationmark.triangle")
        } actions: {
          Button(String(localized: "Try again", comment: "Retries loading a thread")) {
            Task { await model.load() }
          }
        }
      } else {
        ProgressView()
      }
    }
  }

  private var replyBar: some View {
    @Bindable var bar = model.replyBar
    return ThreadReplyBar(
      text: $bar.draft, holdStartedAt: bar.voiceStartedAt,
      isVoiceAvailable: model.canRecordVoice, isTextEnabled: model.canType,
      onSend: { Task { await model.sendDraft() } },
      onHoldBegan: { model.beginVoice() },
      onHoldEnded: { cancelled in Task { await model.endVoice(cancelled: cancelled) } },
      focusRequest: keyboardRequest)
  }

  @ViewBuilder private var failureToast: some View {
    if let failure = model.failure {
      ToastBanner(message: failure.message)
        .padding(.horizontal, Theme.Spacing.barInset)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("thread.toast")
    }
  }

  /// Leaving the conversation ends a reply its own controls started (any answer of the thread), never one the app started by
  /// itself (the auto-read).
  private func stopReplyStartedHere() {
    guard startedReply, let speech = voice?.speech else { return }
    startedReply = false
    if let id = speech.memoID, model.memoIDs.contains(id) { speech.stop(memoID: id) }
  }

  /// A hold that loses its finger (the screen goes away, the app backgrounds) never gets an `onEnded`: stop it here.
  private func cancelVoice() {
    guard model.replyBar.voiceStartedAt != nil else { return }
    Task { await model.endVoice(cancelled: true) }
  }
}
