import IrisCore
import IrisUI
import SwiftUI

/// The microphone per audio route: the connected route is editable (the rule `MicRulesModel` already keeps), the routes
/// seen before are listed below it. Listing them needs the rule store to remember each route's name when its rule is set;
/// today it keeps only the fingerprint, which is why the rows below are sample data in this render.
struct RouteConfigAudioView: View {
  let micRules: MicRulesModel

  private static let microphones = [
    String(localized: "Automatic", comment: "Mic rule: the system picks"),
    String(localized: "iPhone microphone", comment: "Mic rule sample"),
    String(localized: "AirPods microphone", comment: "Mic rule sample"),
  ]

  @State private var sample: [SampleRule] = [
    SampleRule(route: "AirPods Pro, Car", microphone: Self.microphones[1]),
    SampleRule(route: "Living room speaker", microphone: Self.microphones[0]),
  ]

  var body: some View {
    List {
      Section {
        MicRuleList(
          routeTitle: micRules.routeTitle,
          routeCaption: String(
            localized: "Recording starts with the microphone you pick for this route.",
            comment: "Settings mic rule caption"),
          choices: micRules.choices, selection: micRules.selection
        ) { uid in
          Task { await micRules.pick(uid) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routes.audio.active")
      } header: {
        Text("Connected now", comment: "Routes section")
      }
      .listRowBackground(Theme.Surface.panel)

      Section {
        ForEach($sample) { $rule in
          Picker(selection: $rule.microphone) {
            ForEach(Self.microphones, id: \.self) { Text(verbatim: $0).tag($0) }
          } label: {
            Text(verbatim: rule.route)
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("routes.audio.rule")
        }
      } header: {
        Text("Seen before", comment: "Routes section")
      } footer: {
        Text(
          "A route you have connected to before keeps its rule. Change it here without being connected to it.",
          comment: "Routes audio seen-before hint")
      }
      .listRowBackground(Theme.Surface.panel)
    }
    .accessibilityIdentifier("routes.audio.view")
    .scrollContentBackground(.hidden)
    .background(Theme.Surface.background)
    .navigationTitle(String(localized: "Audio routes", comment: "Navigation title"))
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct SampleRule: Identifiable {
  let route: String
  var microphone: String
  var id: String { route }
}
