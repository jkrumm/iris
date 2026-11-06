import IrisCore
import IrisUI
import SwiftUI

/// The Decisions tab: the health line of the factory on top, then one card per open ask. The card shows the ask's own words
/// (`short`, `summary`), never an id or an Issue number; an answerable one takes an option tap (confirmed) or typed text.
struct DecisionsView: View {
  @Bindable var model: DecisionsModel
  /// How often the board reloads while the tab is on screen.
  var pollInterval: Duration = .seconds(15)

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HealthLine(items: model.health, count: model.board?.counts.health ?? 0)
            if let notice = model.notice { NoticeBar(notice: notice, onDismiss: model.dismissNotice) }
            content
          }
          .padding(.horizontal, Theme.Spacing.screenMargin)
          .padding(.top, Theme.Spacing.sectionTop)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.highlightedAskID, initial: true) { scroll(proxy) }
        .onChange(of: model.board) { scroll(proxy) }
      }
      .accessibilityIdentifier("decisions.view")
      // The Record accessory floats over the scroll's end: the last card stops above it.
      .contentMargins(.bottom, Theme.Spacing.gutter, for: .scrollContent)
      .takeBanner()
      .background(Theme.Surface.background)
      .toolbarVisibility(.hidden, for: .navigationBar)
      .statusBarScrim()
      .refreshable { await model.load() }
      .task {
        while !Task.isCancelled {
          await model.load()
          try? await Task.sleep(for: pollInterval)
        }
      }
      .task(id: model.highlightedAskID) {
        guard model.highlightedAskID != nil else { return }
        try? await Task.sleep(for: .seconds(4))
        if !Task.isCancelled { model.clearHighlight() }
      }
    }
  }

  private func scroll(_ proxy: ScrollViewProxy) {
    guard let id = model.highlightedAskID, model.asks.contains(where: { $0.id == id }) else { return }
    withAnimation { proxy.scrollTo(id, anchor: .center) }
  }

  @ViewBuilder private var content: some View {
    if model.board == nil {
      switch model.loadProblem {
      case .unreachable:
        ContentUnavailableView(
          String(localized: "Factory unreachable", comment: "Decisions error title"), systemImage: "wifi.slash",
          description: Text("Decisions load as soon as it answers.", comment: "Decisions unreachable description")
        )
        .overlay(alignment: .bottom) { retry }
        .accessibilityIdentifier("decisions.unreachable")
      case .failed:
        ContentUnavailableView(
          String(localized: "Could not load decisions", comment: "Decisions error title"),
          systemImage: "exclamationmark.triangle"
        )
        .overlay(alignment: .bottom) { retry }
        .accessibilityIdentifier("decisions.error")
      case nil:
        ProgressView().frame(maxWidth: .infinity, minHeight: 240)
      }
    } else {
      if model.loadProblem == .unreachable { staleBar }
      if model.asks.isEmpty {
        ContentUnavailableView(
          String(localized: "Nothing waits for you", comment: "Decisions empty title"), systemImage: "checkmark.bubble",
          description: Text("Open questions from the factory show up here.", comment: "Decisions empty description")
        )
        .accessibilityIdentifier("decisions.empty")
      } else {
        ForEach(model.asks) { ask in
          DecisionCard(ask: ask, state: model.answers[ask.id], isHighlighted: model.highlightedAskID == ask.id) {
            text in
            Task { await model.answer(askID: ask.id, text: text) }
          }
          .id(ask.id)
        }
      }
    }
  }

  private var retry: some View {
    Button(String(localized: "Try again", comment: "Retries the stats load")) { Task { await model.load() } }
      .buttonStyle(.bordered)
      .offset(y: 48)
  }

  /// The board on screen is old: the last load could not reach the factory.
  private var staleBar: some View {
    Label(String(localized: "Factory unreachable", comment: "Decisions error title"), systemImage: "wifi.slash")
      .themeFont(.footnote)
      .foregroundStyle(Theme.Status.warn)
      .accessibilityIdentifier("decisions.unreachable")
  }
}

/// "All clear", or the count and each item's `short`; a tap on an item shows its `summary`.
private struct HealthLine: View {
  let items: [FactoryHealthItem]
  let count: Int
  @State private var expanded: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      if items.isEmpty {
        Label(
          String(localized: "All clear", comment: "Decisions health line: nothing needs a look"),
          systemImage: "checkmark.circle"
        )
        .themeFont(.subheadline)
        .foregroundStyle(Theme.Ink.muted)
      } else {
        Label {
          Text("Needs a look (\(count))", comment: "Decisions health line: the number of items; each follows")
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .themeFont(.subheadline, weight: .semibold)
        .foregroundStyle(Theme.Status.warn)
        ForEach(items) { item in
          Button {
            if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
          } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
              Text(verbatim: item.short)
                .themeFont(.footnote, weight: .medium)
                .foregroundStyle(Theme.Ink.primary)
              if expanded.contains(item.id) {
                Text(verbatim: item.summary)
                  .themeFont(.footnote)
                  .foregroundStyle(Theme.Ink.secondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("decisions.health")
  }
}

private struct NoticeBar: View {
  let notice: DecisionsModel.Notice
  let onDismiss: () -> Void

  var body: some View {
    HStack {
      switch notice {
      case .alreadyAnswered:
        Text("Already answered", comment: "Decisions notice: the ask was answered elsewhere")
      }
      Spacer()
      Button(action: onDismiss) { Image(systemName: "xmark") }
        .accessibilityLabel(String(localized: "Dismiss", comment: "Closes a notice"))
    }
    .themeFont(.footnote)
    .foregroundStyle(Theme.Ink.secondary)
    .padding(Theme.Spacing.sm)
    .background(Theme.Surface.subtle, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    .accessibilityIdentifier("decisions.notice")
  }
}

private struct DecisionCard: View {
  let ask: FactoryAsk
  let state: DecisionsModel.AnswerState?
  let isHighlighted: Bool
  let onAnswer: (String) -> Void

  @State private var text = ""
  /// The option tapped and not yet confirmed.
  @State private var pendingOption: String?

  private var isSending: Bool { state == .sending }
  private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
        Text(verbatim: ask.short)
          .themeFont(.callout, weight: .semibold)
          .foregroundStyle(Theme.Ink.primary)
        Text(verbatim: ask.summary)
          .themeFont(.subheadline)
          .foregroundStyle(Theme.Ink.secondary)
        HStack(spacing: Theme.Spacing.xs) {
          Text(ask.at, format: .relative(presentation: .named))
          if ask.stale { Text("Stale", comment: "Decisions card: an old ask").foregroundStyle(Theme.Status.warn) }
        }
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.muted)
      }
      .opacity(ask.stale ? 0.55 : 1)
      if ask.answerable { answerControls }
    }
    .padding(Theme.Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.Surface.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.card)
        .stroke(isHighlighted ? Theme.Accent.tint : Theme.Surface.border, lineWidth: isHighlighted ? 2 : 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("decisions.card")
  }

  @ViewBuilder private var answerControls: some View {
    if let option = pendingOption {
      HStack {
        Text("Send “\(option)”?", comment: "Decisions card: confirms a tapped option; the argument is the option")
          .themeFont(.subheadline)
          .foregroundStyle(Theme.Ink.primary)
        Spacer()
        Button(String(localized: "Cancel", comment: "Drops the tapped option")) { pendingOption = nil }
          .buttonStyle(.bordered)
        Button(String(localized: "Send", comment: "Sends the answer")) {
          pendingOption = nil
          onAnswer(option)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("decisions.confirm")
      }
      .disabled(isSending)
    } else if !ask.options.isEmpty {
      HStack {
        ForEach(ask.options, id: \.self) { option in
          Button {
            pendingOption = option
          } label: {
            Text(verbatim: option)
          }
          .buttonStyle(.bordered)
          .disabled(isSending)
        }
      }
      .accessibilityIdentifier("decisions.options")
    }
    HStack(alignment: .bottom) {
      TextField(
        String(localized: "Answer", comment: "Placeholder of the free-text answer"), text: $text, axis: .vertical
      )
      .textFieldStyle(.roundedBorder)
      .lineLimit(1...4)
      .disabled(isSending)
      .accessibilityIdentifier("decisions.field")
      Button {
        onAnswer(trimmed)
      } label: {
        Image(systemName: "arrow.up.circle.fill").font(.title2)
      }
      .accessibilityLabel(String(localized: "Send", comment: "Sends the answer"))
      .disabled(isSending || trimmed.count < 2)
      .accessibilityIdentifier("decisions.send")
    }
    status
  }

  @ViewBuilder private var status: some View {
    switch state {
    case .sending:
      HStack(spacing: Theme.Spacing.xs) {
        ProgressView()
        Text("Sending…", comment: "Decisions card: the answer is on its way")
      }
      .themeFont(.footnote)
      .foregroundStyle(Theme.Ink.muted)
    case .failed(let failure):
      Text(verbatim: message(for: failure))
        .themeFont(.footnote)
        .foregroundStyle(Theme.Status.bad)
        .accessibilityIdentifier("decisions.error")
    case nil:
      EmptyView()
    }
  }

  private func message(for failure: DecisionsModel.AnswerFailure) -> String {
    switch failure {
    case .unreachable:
      String(localized: "Could not reach the factory. Send again.", comment: "Decisions card: answer failed offline")
    case .closed:
      String(localized: "This question is no longer open.", comment: "Decisions card: the ask takes no answer any more")
    case .other:
      String(localized: "The answer was not sent. Send again.", comment: "Decisions card: answer failed")
    }
  }
}
