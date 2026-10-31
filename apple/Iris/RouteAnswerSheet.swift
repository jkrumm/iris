import IrisCore
import IrisUI
import SwiftUI

extension View {
  /// The one wiring of the route sheet: History's rows present it from `RootView` (a `.sheet(item:)` in History's own chain
  /// broke the list's scroll edge, TDD §4 "Presentation hosts"), the memo detail from itself (its players stay up behind it).
  /// With no `make` there is no sheet.
  func routeAnswerSheet(
    item: Binding<Memo?>, make: ((Memo) -> RouteAnswerModel)?, onRouted: @escaping (Memo) -> Void
  ) -> some View {
    sheet(item: item) { memo in
      if let make {
        RouteAnswerSheet(model: make(memo), onRouted: onRouted)
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
      }
    }
  }
}

/// The sheet behind "Route…" on a pinned History row and in the memo detail: answers a parked memo, or corrects the route of
/// a finished one. It closes itself when the server accepts the answer.
struct RouteAnswerSheet: View {
  @State private var model: RouteAnswerModel
  private let onRouted: (Memo) -> Void
  @Environment(\.dismiss) private var dismiss

  init(model: RouteAnswerModel, onRouted: @escaping (Memo) -> Void) {
    _model = State(initialValue: model)
    self.onRouted = onRouted
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.sectionTop) {
          Text(verbatim: model.memo.rowHeadline)
            .themeFont(.callout, weight: .semibold)
            .foregroundStyle(Theme.Ink.primary)
            .lineLimit(3)
          RouteAnswerPanel(
            reason: model.reason, destinations: Self.destinations,
            selection: Binding(get: { model.destination.rawValue }, set: select),
            suggestionText: suggestionText, tabs: model.tabs, tabSelection: $model.tab,
            note: model.kind == .correction ? Self.correctionNote : nil, failure: model.failure, labels: Self.labels,
            submitTitle: model.kind == .answer ? Self.answerTitle : Self.correctionTitle,
            canSubmit: model.canSubmit, isSubmitting: model.isSubmitting
          ) {
            Task { await send() }
          }
        }
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .padding(.vertical, Theme.Spacing.sectionTop)
      }
      .background(Theme.Surface.background)
      .navigationTitle(
        model.kind == .answer
          ? String(localized: "Where should this go?", comment: "Route sheet title for a parked memo")
          : String(localized: "Correct the route", comment: "Route sheet title for a finished memo")
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "Cancel", comment: "Closes the route sheet")) { dismiss() }
            .disabled(model.isSubmitting)
            .accessibilityIdentifier("route.cancel")
        }
      }
      .interactiveDismissDisabled(model.isSubmitting)
    }
    .accessibilityIdentifier("route.sheet")
    .task(id: model.destination) { await model.loadHerd() }
  }

  private func select(_ raw: String) {
    guard let destination = RouteDestination(rawValue: raw) else { return }
    model.destination = destination
  }

  private func send() async {
    guard let memo = await model.submit() else { return }
    onRouted(memo)
    dismiss()
  }

  private var suggestionText: String? {
    guard model.kind == .answer, let suggestion = model.suggestion else { return nil }
    return String(localized: "Suggested: \(suggestion.title)", comment: "Route sheet: the decision model's guess")
  }

  private static let destinations = RouteDestination.allCases.map {
    ChipChoice(id: $0.rawValue, title: $0.title, systemImage: $0.systemImage)
  }

  private static var labels: RouteAnswerLabels {
    RouteAnswerLabels(
      destination: String(localized: "Send it to", comment: "Route sheet section"),
      tab: String(localized: "Tab", comment: "Route sheet section"),
      loadingTabs: String(localized: "Looking for live tabs…", comment: "Route sheet while the herd loads"))
  }

  private static var answerTitle: String { String(localized: "Send", comment: "Route sheet: answers a parked memo") }

  private static var correctionTitle: String {
    String(localized: "Log correction", comment: "Route sheet: corrects a finished memo")
  }

  private static var correctionNote: String {
    String(
      localized: "The memo was already sent. This is only logged, to teach Iris; nothing is sent again.",
      comment: "Route sheet note on a correction")
  }
}
