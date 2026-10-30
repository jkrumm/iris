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
      Section {
        NavigationLink {
          RouteConfigReviewView(micRules: micRules)
        } label: {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("Routes", comment: "Settings row")
              Text("Where memos can go, and the microphone per audio route", comment: "Settings row detail")
                .themeFont(.footnote)
                .foregroundStyle(Theme.Ink.muted)
            }
          } icon: {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.Accent.tint)
          }
        }
        .accessibilityIdentifier("settings.routes")
      }
      .listRowBackground(Theme.Surface.panel)
    }
  }
}
