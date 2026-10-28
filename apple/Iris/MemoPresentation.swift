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

  /// Where the memo went (the tab name for a herdr tab); the mode only before it is routed.
  var routeLabel: String {
    switch route {
    case nil: mode.rawValue.capitalized
    case "tab", "herdr":
      destinationRef ?? String(localized: "Tab", comment: "Route name for a herdr tab without a name")
    case let route?: route.capitalized
    }
  }

  /// The route's dot on a History row.
  var routeDotColor: Color {
    switch route {
    case "hermes": Theme.Accent.tint
    case "journal": Theme.Status.good
    case "tab", "herdr": Theme.Ink.secondary
    default: Theme.Ink.faint
    }
  }

  /// Parked at `needs_route` and not yet handled: pinned above the list and tinted.
  var isOpenNeedsRoute: Bool { state == .needsRoute && !done }

  var relativeTime: String {
    createdAt.formatted(.relative(presentation: .named))
  }

  /// The clock time on a History row; the day sits in the section header.
  var timeText: String {
    createdAt.formatted(date: .omitted, time: .shortened)
  }

  /// Settled memos show the route and the audio length, memos that need the user show the coloured state, memos the
  /// pipeline is still driving show the route and "Acting". The list wire carries no cost.
  var rowStatus: HistoryRowStatus {
    switch state {
    case .needsRoute:
      .alert(label: String(localized: "Needs route", comment: "History row status"), color: Theme.Status.warn)
    case .failed:
      .alert(
        label: failedStep.map { String(localized: "Failed · \($0.rawValue)", comment: "History row status") }
          ?? String(localized: "Failed", comment: "History row status"),
        color: Theme.Status.bad)
    case .notified:
      .settled(route: routeLabel, dot: routeDotColor, duration: audioSeconds.map(DurationText.string(seconds:)))
    default:
      .inFlight(
        route: routeLabel, dot: routeDotColor, label: String(localized: "Acting", comment: "History row status"),
        progress: stepProgress)
    }
  }

  /// How many of the pipeline's steps the memo's state says are done: the list wire carries no step timeline, and
  /// the state is enough for the dashes on an in-flight row.
  var stepProgress: StepProgress {
    let completed =
      switch state {
      case .receiving, .received, .failed: 0
      case .transcribed, .needsRoute: 1
      case .routed: 2
      case .acted: 3
      case .summarized: 4
      case .notified: PipelineSteps.shown.count
      }
    return StepProgress(completed: completed, total: PipelineSteps.shown.count)
  }

  /// The grey line under the headline: what to do about a failure or a parked memo, else the summary's first line.
  var rowSecondary: String? {
    switch state {
    case .failed:
      let retry = failedStep.map { String(localized: "retry from \($0.rawValue)", comment: "History row hint") }
      let parts = [error == rowHeadline ? nil : error, retry].compactMap { $0 }
      return parts.isEmpty ? nil : parts.joined(separator: " — ")
    case .needsRoute:
      return String(localized: "Tap to decide", comment: "History row hint on a memo that needs a route")
    default:
      return summary?.detail.split(whereSeparator: \.isNewline).first.map(String.init)
    }
  }
}

/// The steps the UI shows, in order: the timeline's handler steps (`ingest` is the upload, not a step of work).
nonisolated enum PipelineSteps {
  static let shown: [MemoStep] = [.transcribe, .route, .act, .summarize, .notify]
}

extension MemoStep {
  var title: String {
    switch self {
    case .ingest: String(localized: "Upload", comment: "Pipeline step")
    case .transcribe: String(localized: "Transcribe", comment: "Pipeline step")
    case .route: String(localized: "Route", comment: "Pipeline step")
    case .act: String(localized: "Act", comment: "Pipeline step")
    case .summarize: String(localized: "Summarize", comment: "Pipeline step")
    case .notify: String(localized: "Notify", comment: "Pipeline step")
    }
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

/// "38 s", "2 min 12 s", "41 min", "1 h 5 min": the audio lengths on History.
enum DurationText {
  static func string(seconds: Double) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total) s" }
    let minutes = total / 60
    if minutes < 60 {
      let rest = total % 60
      return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
    let rest = minutes % 60
    return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
  }
}
