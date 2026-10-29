import SwiftUI

/// A live herdr tab the user can pick as the destination of a memo.
public struct RouteAnswerTab: Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var subtitle: String

  public init(id: String, title: String, subtitle: String) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
  }
}

/// What the tab list under the destination chips shows.
public enum RouteAnswerTabs: Equatable, Sendable {
  /// The chosen destination takes no tab.
  case notNeeded
  case loading
  case loaded([RouteAnswerTab])
  /// The herd could not be read (or has no tab); the message says so, and herdr cannot be sent to.
  case unavailable(String)
}

/// The copy of a ``RouteAnswerPanel``; the app passes it localized.
public struct RouteAnswerLabels: Sendable {
  public var destination: String
  public var tab: String
  public var loadingTabs: String

  public init(destination: String, tab: String, loadingTabs: String) {
    self.destination = destination
    self.tab = tab
    self.loadingTabs = loadingTabs
  }
}

/// Where should this memo go: why it parked, the destination chips (the model's suggestion preselected by the caller), the
/// herdr tab list, and one send button. The same panel answers a parked memo and corrects a decision after `act`; a
/// correction carries a `note` that says it is only logged.
public struct RouteAnswerPanel: View {
  private let reason: String?
  private let destinations: [ChipChoice<String>]
  private let suggestionText: String?
  private let tabs: RouteAnswerTabs
  private let note: String?
  private let failure: String?
  private let labels: RouteAnswerLabels
  private let submitTitle: String
  private let canSubmit: Bool
  private let isSubmitting: Bool
  private let onSubmit: () -> Void
  @Binding private var selection: String
  @Binding private var tabSelection: String?

  public init(
    reason: String?, destinations: [ChipChoice<String>], selection: Binding<String>, suggestionText: String? = nil,
    tabs: RouteAnswerTabs, tabSelection: Binding<String?>, note: String? = nil, failure: String? = nil,
    labels: RouteAnswerLabels, submitTitle: String, canSubmit: Bool, isSubmitting: Bool = false,
    onSubmit: @escaping () -> Void
  ) {
    self.reason = reason
    self.destinations = destinations
    self.suggestionText = suggestionText
    self.tabs = tabs
    self.note = note
    self.failure = failure
    self.labels = labels
    self.submitTitle = submitTitle
    self.canSubmit = canSubmit
    self.isSubmitting = isSubmitting
    self.onSubmit = onSubmit
    _selection = selection
    _tabSelection = tabSelection
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
      if let reason { reasonRow(reason) }
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        DetailSectionLabel(labels.destination)
        ChoiceChips(choices: destinations, selection: $selection)
          .disabled(isSubmitting)
          .accessibilityIdentifier("route.destinations")
        if let suggestionText {
          Label(suggestionText, systemImage: "sparkles")
            .themeFont(.footnote)
            .foregroundStyle(Theme.Ink.muted)
            .accessibilityIdentifier("route.suggestion")
        }
      }
      tabList
      if let note {
        Text(verbatim: note)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
          .accessibilityIdentifier("route.note")
      }
      if let failure {
        Text(verbatim: failure)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Status.bad)
          .accessibilityIdentifier("route.error")
      }
      Button(action: onSubmit) {
        HStack(spacing: Theme.Spacing.sm) {
          if isSubmitting { ProgressView() }
          Text(verbatim: submitTitle)
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(!canSubmit || isSubmitting)
      .accessibilityIdentifier("route.submit")
    }
  }

  private func reasonRow(_ reason: String) -> some View {
    Label {
      Text(verbatim: reason)
    } icon: {
      Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.Status.warn)
    }
    .themeFont(.callout)
    .foregroundStyle(Theme.Ink.secondary)
    .accessibilityIdentifier("route.reason")
  }

  @ViewBuilder private var tabList: some View {
    switch tabs {
    case .notNeeded:
      EmptyView()
    case .loading:
      HStack(spacing: Theme.Spacing.sm) {
        ProgressView()
        Text(verbatim: labels.loadingTabs)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
      }
    case .unavailable(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .themeFont(.footnote)
        .foregroundStyle(Theme.Status.warn)
        .accessibilityIdentifier("route.tabs.unavailable")
    case .loaded(let tabs):
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        DetailSectionLabel(labels.tab)
        VStack(spacing: 0) {
          ForEach(tabs) { tab in
            if tab.id != tabs.first?.id { Divider().overlay(Theme.Surface.hairline) }
            tabRow(tab)
          }
        }
        .detailCard()
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("route.tabs")
    }
  }

  private func tabRow(_ tab: RouteAnswerTab) -> some View {
    Button {
      tabSelection = tab.id
    } label: {
      HStack(spacing: Theme.Spacing.md) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: tab.title)
            .themeFont(.callout, weight: .medium)
            .foregroundStyle(Theme.Ink.primary)
          Text(verbatim: tab.subtitle)
            .themeFont(.footnote)
            .foregroundStyle(Theme.Ink.muted)
        }
        Spacer(minLength: Theme.Spacing.sm)
        if tabSelection == tab.id {
          Image(systemName: "checkmark")
            .foregroundStyle(Theme.Accent.tint)
            .accessibilityHidden(true)
        }
      }
      .padding(Theme.Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(isSubmitting)
    .accessibilityAddTraits(tabSelection == tab.id ? .isSelected : [])
    .accessibilityIdentifier("route.tab")
  }
}
