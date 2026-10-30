import IrisCore
import IrisUI
import SwiftUI

/// The memo detail: headline, the recording's player, the step waterfall (collapsed to its total), transcript and reply
/// with a Copy button each, and the icon-only actions at the bottom. It reloads when `refreshToken` changes (History bumps it on a `memo.updated` event).
struct MemoDetailView: View {
  @State private var model: MemoDetailModel
  @State private var playback: MemoPlayback
  private let refreshToken: () -> Int
  private let onReply: (Memo) -> Void
  private let makeRouteAnswer: ((Memo) -> RouteAnswerModel)?
  private let onRouted: (Memo) -> Void
  @State private var routing: Memo?

  /// - Parameters:
  ///   - onReply: The reply hook: History opens the composer from here, continuing `memo.threadId`.
  ///   - makeRouteAnswer: Builds the route sheet's model (answer a parked memo, correct a finished one); nil hides both.
  ///   - onRouted: Told the memo the server answered with, so History shows it at once.
  init(
    model: MemoDetailModel, refreshToken: @escaping () -> Int = { 0 }, onReply: @escaping (Memo) -> Void = { _ in },
    makeRouteAnswer: ((Memo) -> RouteAnswerModel)? = nil, onRouted: @escaping (Memo) -> Void = { _ in }
  ) {
    _model = State(initialValue: model)
    _playback = State(
      initialValue: MemoPlayback(
        memoID: model.memo.id, recordingDuration: model.memo.audioSeconds ?? 0, speech: model.speech))
    self.refreshToken = refreshToken
    self.onReply = onReply
    self.makeRouteAnswer = makeRouteAnswer
    self.onRouted = onRouted
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        header
        routeCard
        if model.audioRequest != nil { player }
        steps
        transcript
        reply
        footer
      }
      .padding(.horizontal, Theme.Spacing.lg)
      .padding(.top, Theme.Spacing.sm)
      .padding(.bottom, Theme.Spacing.xl)
    }
    .accessibilityIdentifier("memo.detail")
    .takeBanner()
    .background(Theme.Surface.background)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaInset(edge: .bottom) { actions }
    .overlay(alignment: .bottom) { failureToast }
    .navigationTitle(String(localized: "Memo", comment: "Navigation title of the memo detail"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbarVisibility(.hidden, for: .tabBar)
    .toolbar {
      if let route = model.memo.threadRoute {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink(value: route) {
            Label(
              String(localized: "Conversation", comment: "Opens the thread this memo belongs to"),
              systemImage: "bubble.left.and.bubble.right")
          }
          .accessibilityIdentifier("detail.conversation")
        }
      }
    }
    .routeAnswerSheet(
      item: $routing, make: makeRouteAnswer,
      onRouted: { routed in
        onRouted(routed)
        Task { await model.didRoute(routed) }
      }
    )
    .task(id: refreshToken()) { await model.load() }
    .task(id: model.audioRequest) { await playback.recording.load(model.audioRequest) }
    .onAppear { playback.attach() }
    // The sheet is hosted here: a screen covered by it is still on screen, so its players stay.
    .onDisappear { if routing == nil { playback.teardown() } }
  }

  // MARK: Sections

  private var header: some View {
    let memo = model.memo
    return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.sm) {
        RouteChip(label: memo.routeLabel, systemImage: memo.routeChipIcon)
        Text(verbatim: metaLine(memo))
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
        if canCorrectRoute {
          Spacer(minLength: Theme.Spacing.sm)
          Button(String(localized: "Wrong route?", comment: "Corrects the route of a finished memo")) {
            routing = memo
          }
          .buttonStyle(.borderless)
          .themeFont(.footnote, weight: .medium)
          .accessibilityIdentifier("detail.route.correct")
        }
      }
      Text(verbatim: memo.rowHeadline)
        .themeFont(.title, weight: .bold)
        .foregroundStyle(Theme.Ink.primary)
        .fixedSize(horizontal: false, vertical: true)
      if memo.state == .failed, let error = memo.error {
        Text(verbatim: error)
          .themeFont(.callout)
          .foregroundStyle(Theme.Status.bad)
      } else if let detail = memo.summary?.detail {
        Text(verbatim: detail)
          .themeFont(.callout)
          .foregroundStyle(Theme.Ink.secondary)
      }
    }
  }

  /// A finished memo's route can be corrected (the server only logs it); a parked one is answered in ``routeCard``.
  private var canCorrectRoute: Bool {
    makeRouteAnswer != nil && model.memo.state != .needsRoute && RouteAnswerModel.canRoute(model.memo)
  }

  /// Why the memo is parked and the button that answers it.
  @ViewBuilder private var routeCard: some View {
    let memo = model.memo
    if makeRouteAnswer != nil, memo.state == .needsRoute {
      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        Label {
          Text(verbatim: parkReason(memo))
        } icon: {
          Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.Status.warn)
        }
        .themeFont(.callout)
        .foregroundStyle(Theme.Ink.secondary)
        .accessibilityIdentifier("detail.route.reason")
        Button {
          routing = memo
        } label: {
          Label(routeActionTitle(memo), systemImage: "arrow.triangle.branch")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("detail.route.answer")
      }
      .padding(Theme.Spacing.md)
      .detailCard()
    }
  }

  private func parkReason(_ memo: Memo) -> String {
    memo.routeReason ?? String(localized: "Where should this go?", comment: "Detail: parked memo")
  }

  private func routeActionTitle(_ memo: Memo) -> String {
    guard let suggestion = memo.routeSuggestion.flatMap(RouteDestination.init(spoken:)) else {
      return String(localized: "Choose a route…", comment: "Detail action on a parked memo")
    }
    return String(localized: "Route to \(suggestion.title)…", comment: "Detail action with the model's suggestion")
  }

  private func metaLine(_ memo: Memo) -> String {
    [memo.timeText, memo.audioSeconds.map(DurationText.string(seconds:))].compactMap { $0 }.joined(separator: " · ")
  }

  private var player: some View {
    let audio = playback.recording
    return MemoPlayerBar(
      position: audio.position, duration: audio.duration, isPlaying: audio.isPlaying, isEnabled: audio.isLoaded,
      onToggle: playback.toggleRecording,
      onSeek: { audio.seek(to: $0) },
      onSkipBack: { audio.skipBack() })
  }

  @ViewBuilder private var steps: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      DetailSectionLabel(String(localized: "Steps", comment: "Section label of the step waterfall"))
      if model.memo.state.isResultReady {
        waterfall(now: .now)
      } else {
        // A running step's bar grows with the clock.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          waterfall(now: context.date)
        }
      }
    }
  }

  private func waterfall(now: Date) -> some View {
    StepWaterfall(
      rows: model.rows(now: now),
      totalTitle: model.memo.state.isResultReady
        ? String(localized: "Total", comment: "Footer of the step waterfall")
        : String(localized: "Total so far", comment: "Footer of the step waterfall while the memo runs"),
      totalValue: model.totalValue(now: now),
      isExpanded: $model.isWaterfallExpanded,
      onRetry: retry)
  }

  @ViewBuilder private var transcript: some View {
    if let text = model.memo.transcript {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        sectionHeader(String(localized: "Transcript", comment: "Section label of the transcript"), copying: .transcript)
        Text(verbatim: text)
          .themeFont(.callout)
          .foregroundStyle(Theme.Ink.primary)
          .textSelection(.enabled)
          .modifier(TextCard())
          .accessibilityIdentifier("detail.transcript")
      }
    }
  }

  @ViewBuilder private var reply: some View {
    if let text = model.memo.replyText {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        sectionHeader(String(localized: "Reply", comment: "Section label of the reply"), copying: .reply)
        Text(ReplyMarkdown.attributed(text))
          .themeFont(.subheadline)
          .foregroundStyle(Theme.Ink.secondary)
          .tint(Theme.Accent.tint)
          .textSelection(.enabled)
          .modifier(TextCard())
          .accessibilityIdentifier("detail.reply")
      }
    }
  }

  /// The section label with the button that copies the section as plain text.
  private func sectionHeader(_ title: String, copying target: MemoDetailModel.CopyTarget) -> some View {
    let copied = model.copied == target
    let name = target == .transcript ? "transcript" : "reply"
    return HStack(spacing: Theme.Spacing.sm) {
      DetailSectionLabel(title)
      Button {
        model.copy(target)
      } label: {
        Label(
          copied
            ? String(localized: "Copied", comment: "Detail: confirmation after Copy")
            : String(localized: "Copy", comment: "Detail: copies the section as plain text"),
          systemImage: copied ? "checkmark" : "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .themeFont(.caption, weight: .semibold)
      .foregroundStyle(copied ? Theme.Status.good : Theme.Accent.tint)
      .sensoryFeedback(.success, trigger: copied) { _, now in now }
      .accessibilityIdentifier("detail.\(name).copy")
    }
  }

  @ViewBuilder private var footer: some View {
    if let count = model.memo.segmentCount {
      Text(
        verbatim: "\(model.memo.device) · "
          + String(localized: "\(count) segments", comment: "Footer of the memo detail: uploaded recording segments")
      )
      .themeFont(.caption)
      .foregroundStyle(Theme.Ink.faint)
    }
  }

  // MARK: Actions

  private var actions: some View {
    DetailActionBar(
      isPlayingReply: playback.isReplyPlaying,
      canPlayReply: model.canPlayReply,
      canReply: model.canReply,
      retryOptions: model.retrySteps.map { DetailRetryOption(id: $0.rawValue, title: $0.title) },
      primaryRetryID: model.primaryRetryStep?.rawValue,
      onPlayReply: { Task { await playback.toggleReply(model.memo, source: model.media) } },
      onReply: { onReply(model.memo) },
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
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, 96)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("detail.toast")
    }
  }
}

/// The padded panel under a transcript or reply.
private struct TextCard: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Theme.Spacing.md)
      .detailCard()
  }
}
