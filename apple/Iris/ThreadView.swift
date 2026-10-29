import CoreGraphics
import IrisCore
import IrisUI
import SwiftUI

/// One conversation as a rendered document: a turn per question and answer, an answer still on its way as a pending
/// turn with the pipeline's dashes, and a bar at the bottom to reply by text or hold to talk. It reloads when
/// `refreshToken` changes (History bumps a memo's revision on its `memo.updated` event), and the reply replaces the
/// pending turn with a short fade.
struct ThreadView: View {
  @State private var model: ThreadModel
  @State private var composer: ComposerRequest?
  @State private var zoomed: ZoomedImage?
  private let refreshToken: (_ threadId: String, _ memoIDs: [String]) -> Int
  private let makeComposer: (ComposerRequest) -> ComposerModel
  private let onSent: (Memo) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  private struct ZoomedImage: Identifiable {
    let id = UUID()
    let image: CGImage
  }

  /// - Parameters:
  ///   - refreshToken: Folds what History knows of this thread (its memos' revisions, its memo count) into one number the screen reloads on.
  ///   - makeComposer: Builds the sheet model of a typed reply.
  ///   - onSent: Told of every memo this screen creates (History lists it at once).
  init(
    model: ThreadModel, refreshToken: @escaping (_ threadId: String, _ memoIDs: [String]) -> Int = { _, _ in 0 },
    makeComposer: @escaping (ComposerRequest) -> ComposerModel, onSent: @escaping (Memo) -> Void = { _ in }
  ) {
    _model = State(initialValue: model)
    self.refreshToken = refreshToken
    self.makeComposer = makeComposer
    self.onSent = onSent
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
          header
          ForEach(model.turns) { turn in
            view(for: turn)
              .id(turn.id)
              .transition(.opacity)
          }
          Color.clear.frame(height: 1).id(Self.bottom)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.lg)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: model.turns)
      }
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .onChange(of: model.turns.last?.id) {
        withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
      }
    }
    .accessibilityIdentifier("thread.view")
    .takeBanner()
    .background(Theme.Surface.background)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .overlay { placeholder }
    .safeAreaInset(edge: .bottom) { replyBar.disabled(!model.canReply) }
    .overlay(alignment: .bottom) { failureToast }
    .navigationTitle(String(localized: "Conversation", comment: "Navigation title of a thread"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbarVisibility(.hidden, for: .tabBar)
    .task(id: refreshToken(model.route.id, model.memoIDs)) { await model.load() }
    .onDisappear { cancelVoice() }
    .onChange(of: scenePhase) {
      // `.inactive` too (Control Center, a call, a system alert): the finger is gone either way.
      if scenePhase != .active { cancelVoice() }
    }
    .sheet(item: $composer) { request in
      ComposerView(
        model: makeComposer(request),
        onSent: { memo in
          model.didSend(memo)
          onSent(memo)
        },
        onQueued: { model.didQueue() })
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
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.sm) {
        RouteChip(
          label: model.kind == .chat
            ? String(localized: "Chat", comment: "Thread kind") : String(localized: "Hermes", comment: "Thread kind"),
          systemImage: model.kind == .chat ? "bubble.left.and.bubble.right" : "arrow.triangle.branch")
        if model.detail != nil {
          Text(verbatim: ThreadCopy.turnCount(model.turnCount))
            .themeFont(.footnote)
            .foregroundStyle(Theme.Ink.muted)
        }
      }
      Text(verbatim: model.title)
        .themeFont(.title, weight: .bold)
        .foregroundStyle(Theme.Ink.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
  }

  @ViewBuilder private func view(for turn: ThreadModel.Turn) -> some View {
    switch turn.content {
    case .user(let text):
      UserTurnView(text: text, time: time(turn.date))
    case .assistant(let markdown, let mermaid):
      AssistantTurnView(
        markdown: markdown, time: time(turn.date), mermaid: mermaid,
        onOpenImage: { zoomed = ZoomedImage(image: $0) })
    case .pending(let progress, let caption):
      PendingTurnView(progress: progress, caption: caption)
    case .failed(let message):
      Text(verbatim: message)
        .themeFont(.callout)
        .foregroundStyle(Theme.Status.bad)
        .accessibilityIdentifier("thread.turn.failed")
    }
  }

  @ViewBuilder private var placeholder: some View {
    if model.detail == nil {
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
    ThreadReplyBar(
      holdStartedAt: model.voiceStartedAt, isVoiceAvailable: model.canRecordVoice,
      onType: { composer = .reply(toThread: model.route.id, kind: model.kind) },
      onHoldBegan: { model.beginVoice() },
      onHoldEnded: { cancelled in
        Task {
          if let memo = await model.endVoice(cancelled: cancelled) { onSent(memo) }
        }
      })
  }

  @ViewBuilder private var failureToast: some View {
    if let failure = model.failure {
      ToastBanner(message: failure.message)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, 96)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("thread.toast")
    }
  }

  /// A hold that loses its finger (the screen goes away, the app backgrounds) never gets an `onEnded`: stop it here.
  private func cancelVoice() {
    guard model.voiceStartedAt != nil else { return }
    Task { await model.endVoice(cancelled: true) }
  }

  private func time(_ date: Date?) -> String {
    guard let date else { return "" }
    return Calendar.current.isDateInToday(date)
      ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
  }
}
