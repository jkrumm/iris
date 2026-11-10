import CoreGraphics
import IrisCore
import IrisUI
import SwiftUI

/// One conversation as a rendered document: a turn per question and answer, an answer still on its way as a pending
/// turn with the pipeline's dashes, and a bar at the bottom to reply by text or hold to talk. A Details button after each
/// memo opens that memo's details sheet. It reloads when `refreshToken` changes (History bumps a memo's revision on its
/// `memo.updated` event), and the reply replaces the pending turn with a short fade.
struct ThreadView: View {
  @State private var model: ThreadModel
  @State private var zoomed: ZoomedImage?
  @State private var details: DetailsTarget?
  private let refreshToken: (_ threadID: String?, _ memoIDs: [String]) -> Int
  private let makeDetail: (Memo) -> MemoDetailModel
  private let memoRevision: (String) -> Int
  private let liveEvents: () -> AsyncStream<ServerEvent>
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  private struct ZoomedImage: Identifiable {
    let id = UUID()
    let image: CGImage
  }

  private struct DetailsTarget: Identifiable {
    let memo: Memo
    var id: String { memo.id }
  }

  /// - Parameters:
  ///   - refreshToken: Folds what History knows of this conversation (its memos' revisions, its memo count) into one number the screen reloads on.
  ///   - makeDetail: Builds the model of a memo's Details sheet.
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
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.inset) {
          header
          ConversationTurnList(
            turns: model.turns, style: .phone, dayTitle: { HistoryDaySection.title(of: $0) },
            onOpenImage: { zoomed = ZoomedImage(image: $0) },
            onDetails: { id in
              if let memo = model.memo(id: id) { details = DetailsTarget(memo: memo) }
            })
          Color.clear.frame(height: 1).id(Self.bottom)
        }
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
    .task(id: refreshToken(model.threadID, model.memoIDs)) { await model.load() }
    .task {
      for await event in liveEvents() { await model.apply(event) }
    }
    .onAppear { model.reclaimHeld() }
    .onDisappear {
      cancelVoice()
      model.handOver()
    }
    .onChange(of: scenePhase) {
      // `.inactive` too (Control Center, a call, a system alert): the finger is gone either way.
      if scenePhase != .active { cancelVoice() }
    }
    .sheet(item: $details) { target in
      BuiltOnce(make: { makeDetail(target.memo) }) { detail in
        MemoDetailsSheet(model: detail, refreshToken: { memoRevision(target.id) })
      }
      .id(target.id)
    }
    .fullScreenCover(item: $zoomed) { item in
      ZoomableImageView(
        image: item.image, title: String(localized: "Diagram", comment: "Title of the full diagram view"),
        onClose: { zoomed = nil })
    }
  }

  private static let bottom = "thread.bottom"

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
      onHoldEnded: { cancelled in Task { await model.endVoice(cancelled: cancelled) } })
  }

  @ViewBuilder private var failureToast: some View {
    if let failure = model.failure {
      ToastBanner(message: failure.message)
        .padding(.horizontal, Theme.Spacing.barInset)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("thread.toast")
    }
  }

  /// A hold that loses its finger (the screen goes away, the app backgrounds) never gets an `onEnded`: stop it here.
  private func cancelVoice() {
    guard model.replyBar.voiceStartedAt != nil else { return }
    Task { await model.endVoice(cancelled: true) }
  }
}
