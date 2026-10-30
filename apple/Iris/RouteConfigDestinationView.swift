import IrisCore
import IrisUI
import SwiftUI

/// One destination: what it does, how to send a memo there, and its target (for herdr the live tabs). Read-only: the
/// server registers destinations, so an unavailable one says what the server is missing instead of offering a switch.
struct RouteConfigDestinationView: View {
  let destination: RouteConfigDestination
  let tabs: [HerdTab]

  var body: some View {
    List {
      Section {
        Text(verbatim: destination.explanation)
          .themeFont(.callout)
          .foregroundStyle(Theme.Ink.secondary)
        if let reason = destination.unavailableReason {
          Label {
            Text(verbatim: reason)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.warn)
          }
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.secondary)
          .accessibilityIdentifier("routes.destination.unavailable")
        }
      }
      .listRowBackground(Theme.Surface.panel)

      Section {
        LabeledContent(String(localized: "Say first", comment: "Routes destination row")) {
          Text(verbatim: destination.spokenPrefixes.map { "“\($0)”" }.joined(separator: ", "))
            .foregroundStyle(Theme.Ink.secondary)
        }
        LabeledContent(String(localized: "Record mode", comment: "Routes destination row")) {
          Text(verbatim: destination.modes.joined(separator: ", "))
            .foregroundStyle(Theme.Ink.secondary)
        }
      } header: {
        Text("Send a memo here", comment: "Routes section")
      } footer: {
        Text(
          "A mode you pick wins over spoken words. With neither, Iris decides, and asks you when it is under 80 % sure.",
          comment: "Routes destination hint")
      }
      .listRowBackground(Theme.Surface.panel)

      if destination.kind == .herdr, destination.isAvailable { liveTabs }
    }
    .accessibilityIdentifier("routes.destination.view")
    .scrollContentBackground(.hidden)
    .background(Theme.Surface.background)
    .navigationTitle(destination.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  /// The tabs herdr has open right now (`GET /v1/herd`); a spoken "tab <name>" must match exactly one label or repo.
  private var liveTabs: some View {
    Section {
      ForEach(tabs) { tab in
        HStack(spacing: Theme.Spacing.md) {
          Image(systemName: "rectangle.on.rectangle")
            .foregroundStyle(Theme.Ink.muted)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: tab.label)
            Text(verbatim: tab.repo)
              .themeFont(.footnote)
              .foregroundStyle(Theme.Ink.muted)
          }
          Spacer(minLength: Theme.Spacing.sm)
          Text(verbatim: tab.agentState.label)
            .themeFont(.footnote)
            .foregroundStyle(Theme.Ink.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    } header: {
      Text("Live tabs", comment: "Routes section")
    } footer: {
      Text(
        "Read from herdr each time. A tab that closes before the memo arrives sends it back for a new answer.",
        comment: "Routes live tabs hint")
    }
    .listRowBackground(Theme.Surface.panel)
  }
}
