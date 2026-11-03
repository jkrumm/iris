import IrisCore
import IrisUI
import SwiftUI

extension RouteDestination {
  /// The route's dot: the same colours as the dot on a list row.
  var dotColor: Color {
    switch self {
    case .hermes: Theme.Accent.tint
    case .journal: Theme.Status.good
    case .herdr: Theme.Ink.secondary
    }
  }

  var title: String {
    switch self {
    case .hermes: String(localized: "Hermes", comment: "Route name")
    case .journal: String(localized: "Journal", comment: "Route name")
    case .herdr: String(localized: "Tabs", comment: "Route name for memos sent to a herdr tab")
    }
  }
}
