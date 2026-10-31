import IrisUI
import SwiftUI

/// The Settings entry of the route configuration render (Wave 17 I6). It exists only under `-IrisRouteConfigReview`, the
/// launch argument of `RouteConfigReviewUITests`: the surface is a design render for
/// the owner's async review and is not part of the app until it is approved.
struct RouteConfigEntry: View {
  let micRules: MicRulesModel

  static let launchArgument = "-IrisRouteConfigReview"

  var body: some View {
    if ProcessInfo.processInfo.arguments.contains(Self.launchArgument) {
      SettingsGroup {
        NavigationLink {
          RouteConfigReviewView(micRules: micRules)
        } label: {
          SettingsLinkRow(
            systemImage: "arrow.triangle.branch", title: String(localized: "Routes", comment: "Settings row"),
            detail: String(
              localized: "Where memos can go, and the microphone per audio route", comment: "Settings row detail"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.routes")
      }
    }
  }
}
