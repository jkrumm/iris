import Foundation
import IrisCore
import IrisUI
import SwiftUI

/// How a memo reads in a list row: one place for the headline fallback, the state wording and the status color.
extension Memo {
  var rowHeadline: String {
    if let headline = summary?.headline { return headline }
    if let transcript { return transcript }
    if state == .failed, let error { return error }
    return String(localized: "Processing…", comment: "Row headline while the memo has no transcript yet")
  }

  var routeLabel: String {
    guard let route else { return mode.rawValue.capitalized }
    return route.capitalized
  }

  var relativeTime: String {
    createdAt.formatted(.relative(presentation: .named))
  }
}

extension MemoState {
  var label: String {
    switch self {
    case .receiving: String(localized: "Receiving", comment: "Memo state")
    case .received: String(localized: "Received", comment: "Memo state")
    case .transcribed: String(localized: "Transcribed", comment: "Memo state")
    case .routed: String(localized: "Routed", comment: "Memo state")
    case .needsRoute: String(localized: "Needs a route", comment: "Memo state")
    case .acted: String(localized: "Acted", comment: "Memo state")
    case .summarized: String(localized: "Summarized", comment: "Memo state")
    case .notified: String(localized: "Done", comment: "Memo state")
    case .failed: String(localized: "Failed", comment: "Memo state")
    }
  }

  var color: Color {
    switch self {
    case .notified: Theme.Status.good
    case .needsRoute: Theme.Status.warn
    case .failed: Theme.Status.bad
    default: Theme.Status.neutral
    }
  }
}
