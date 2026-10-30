import IrisCore
import IrisUI
import SwiftUI

/// Settings → Routes (Wave 17 I6, a render for the owner's review, fake data only). Two things were both called "routes"
/// and are kept apart here: where a memo goes (the server's destinations, read-only on the phone) and how the phone listens
/// (the microphone rule per audio route, the one thing that is configured on the device).
struct RouteConfigReviewView: View {
  let micRules: MicRulesModel

  private let destinations = RouteConfigDestination.sample
  private let tabs = SampleData.herd.tabs

  var body: some View {
    List {
      Section {
        ForEach(destinations) { destination in
          NavigationLink {
            RouteConfigDestinationView(destination: destination, tabs: tabs)
          } label: {
            RouteConfigDestinationRow(destination: destination, tabCount: tabs.count)
          }
          .accessibilityIdentifier("routes.destination.\(destination.kind.rawValue)")
        }
      } header: {
        Text("Destinations", comment: "Routes section")
      } footer: {
        Text(
          "Where a memo can be sent. The server decides what exists; say a destination first, pick a mode, or let Iris choose when it is sure enough. Otherwise the memo waits for your answer.",
          comment: "Routes destinations hint")
      }
      .listRowBackground(Theme.Surface.panel)

      Section {
        NavigationLink {
          RouteConfigAudioView(micRules: micRules)
        } label: {
          Label {
            VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
              Text(verbatim: micRules.routeTitle)
              Text(verbatim: micSummary)
                .themeFont(.footnote)
                .foregroundStyle(Theme.Ink.muted)
            }
          } icon: {
            Image(systemName: "mic").foregroundStyle(Theme.Accent.tint)
          }
        }
        .accessibilityIdentifier("routes.audio")
      } header: {
        Text("Audio routes", comment: "Routes section")
      } footer: {
        Text(
          "Which microphone recording starts with, per audio route such as the car's Bluetooth. Kept on this device.",
          comment: "Routes audio hint")
      }
      .listRowBackground(Theme.Surface.panel)
    }
    .accessibilityIdentifier("routes.view")
    .scrollContentBackground(.hidden)
    .background(Theme.Surface.background)
    .navigationTitle(String(localized: "Routes", comment: "Navigation title"))
    .navigationBarTitleDisplayMode(.inline)
  }

  /// The active route's rule in a line: the mic it uses, or that the system picks.
  private var micSummary: String {
    let choice = micRules.choices.first { $0.id == micRules.selection }?.title ?? ""
    return String(
      localized: "Now connected · \(choice)", comment: "Routes audio summary, the placeholder is a microphone")
  }
}

/// A destination in the overview: dot, name and what lands where, the status on the trailing edge.
private struct RouteConfigDestinationRow: View {
  let destination: RouteConfigDestination
  let tabCount: Int

  var body: some View {
    HStack(spacing: Theme.Spacing.md) {
      Image(systemName: destination.systemImage)
        .foregroundStyle(Theme.Accent.tint)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
        Text(verbatim: destination.title)
        Text(verbatim: destination.summary)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
      }
      Spacer(minLength: Theme.Spacing.sm)
      HStack(spacing: Theme.Spacing.xs) {
        Circle()
          .fill(destination.isAvailable ? Theme.Status.good : Theme.Status.warn)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
        Text(verbatim: destination.status(tabCount: tabCount))
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
