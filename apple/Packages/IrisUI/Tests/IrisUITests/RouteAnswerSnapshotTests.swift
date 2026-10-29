#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  /// The route sheet's panel (answer a parked memo, correct a finished one) and the microphone rule list, light and dark.
  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct RouteAnswerSnapshotTests {
    private static let destinations = [
      ChipChoice(id: "hermes", title: "Hermes"), ChipChoice(id: "journal", title: "Journal"),
      ChipChoice(id: "herdr", title: "Tab", systemImage: "terminal"),
    ]
    private static let labels = RouteAnswerLabels(
      destination: "Send it to", tab: "Tab", loadingTabs: "Looking for live tabs…")
    private static let tabs = [
      RouteAnswerTab(id: "t1", title: "dotfiles", subtitle: "dotfiles · working"),
      RouteAnswerTab(id: "t2", title: "iris · w16", subtitle: "iris · idle"),
    ]

    private func panel(
      reason: String? = nil, selection: String, suggestion: String? = nil, tabs: RouteAnswerTabs = .notNeeded,
      tab: String? = nil, note: String? = nil, failure: String? = nil, submit: String = "Send", canSubmit: Bool = true
    ) -> some View {
      RouteAnswerPanel(
        reason: reason, destinations: Self.destinations, selection: .constant(selection), suggestionText: suggestion,
        tabs: tabs, tabSelection: .constant(tab), note: note, failure: failure, labels: Self.labels,
        submitTitle: submit, canSubmit: canSubmit, onSubmit: {}
      )
      .padding(Theme.Spacing.lg)
    }

    @Test("a parked memo: the reason, the suggestion preselected", .tags(.snapshot))
    func parkedWithSuggestion() {
      let view = panel(
        reason: "Not sure whether this is a journal entry or a request for Hermes.", selection: "journal",
        suggestion: "Suggested: Journal")
      SnapshotSupport.assertLightAndDark(view, width: 390, height: 330)
    }

    @Test("herdr asks for a tab and keeps Send off until one is picked", .tags(.snapshot))
    func herdrTabs() {
      let picked = panel(
        reason: "Which agent should get this?", selection: "herdr", tabs: .loaded(Self.tabs), tab: "t2")
      SnapshotSupport.assertLightAndDark(picked, width: 390, height: 520)
    }

    @Test("herdr unreachable: the message replaces the tab list", .tags(.snapshot))
    func herdrUnavailable() {
      let view = panel(
        selection: "herdr", tabs: .unavailable("herdr is not reachable, so a tab cannot be picked."), canSubmit: false)
      SnapshotSupport.assertLightAndDark(view, width: 390, height: 290)
    }

    @Test("a correction after act says it is only logged; a refusal shows in red", .tags(.snapshot))
    func correctionWithRefusal() {
      let view = panel(
        selection: "journal",
        note: "The memo was already sent. This is only logged, to teach Iris; nothing is sent again.",
        failure: "Journal is not available on the server right now. Pick another destination.",
        submit: "Log correction")
      SnapshotSupport.assertLightAndDark(view, width: 390, height: 400)
    }

    @Test("the microphone rule of a route: Automatic, built-in and a headset", .tags(.snapshot))
    func micRules() {
      let list = MicRuleList(
        routeTitle: "AirPods Pro, Car", routeCaption: "Recording starts with the microphone you pick for this route.",
        choices: [
          MicRuleChoice(id: nil, title: "Automatic"), MicRuleChoice(id: "built-in", title: "iPhone Microphone"),
          MicRuleChoice(id: "airpods", title: "AirPods Pro"),
        ], selection: "built-in", onPick: { _ in }
      )
      .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(list, width: 390, height: 210)
    }
  }
#endif
