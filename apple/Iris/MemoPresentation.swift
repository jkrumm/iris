import Foundation
import IrisCore
import IrisUI
import SwiftUI

/// How a memo reads in a list row: one place for the headline fallback, the state wording and the status color.
extension Memo {
  var rowHeadline: String {
    if let headline = summary?.headline { return headline }
    if let transcript { return Self.clipped(transcript) }
    if state == .failed, let error { return error }
    return String(localized: "Processing…", comment: "Row headline while the memo has no transcript yet")
  }

  /// The longest a transcript reads as a headline: the server's own clip for an alert (`transcriptSummary`).
  static let headlineLimit = 60

  /// `text` on one line, cut to ``headlineLimit`` characters with an ellipsis when it is longer.
  static func clipped(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard line.count > headlineLimit else { return line }
    return line.prefix(headlineLimit).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// A step that failed for good but that the memo does not need: `notified` with no summary (the server skips a failed
  /// `summarize` and finishes the memo). Only `summarize` is optional.
  func isSkippedOptionalStep(_ step: MemoStep) -> Bool {
    step == .summarize && state == .notified && summary == nil
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

  /// The icon on the detail's chip: a transcript-only memo has no route to show a branch for.
  var routeChipIcon: String {
    mode == .transcribe ? "text.alignleft" : "arrow.triangle.branch"
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
    let total = PipelineSteps.shown(for: mode).count
    let completed =
      switch state {
      case .receiving, .received, .failed: 0
      case .transcribed, .needsRoute: 1
      case .routed: 2
      case .acted: 3
      case .summarized: 4
      case .notified: total
      }
    return StepProgress(completed: completed, total: total)
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

  /// The steps a memo of `mode` goes through: a transcript-only memo skips route, act and summarize.
  static func shown(for mode: MemoMode) -> [MemoStep] {
    mode == .transcribe ? [.transcribe, .notify] : shown
  }

  /// The steps `memo` goes through: a typed memo has no recording, so it skips transcribe.
  static func applicable(to memo: Memo) -> [MemoStep] {
    let steps = shown(for: memo.mode)
    return memo.isTyped ? steps.filter { $0 != .transcribe } : steps
  }
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

// MARK: Plain text

/// What Copy puts on the pasteboard: text with no markup and no style, the same words the screen shows.
extension Memo {
  /// The transcript as spoken, trimmed; nil when there is none.
  var plainTranscript: String? {
    transcript.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// The reply (Hermes's markdown) as plain text: emphasis, code marks, heading marks and fences are gone, list items
  /// keep their bullet or number, a link keeps its address in brackets, table cells are tab-separated.
  var plainReply: String? {
    replyText.map(PlainMarkdown.text(from:)).flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// Markdown to plain text through Foundation's block-aware parse: blocks are separated by a blank line (list items and
/// table rows by a single line break), everything else is the characters the reader sees.
nonisolated enum PlainMarkdown {
  static func text(from markdown: String) -> String {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
    guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
      return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var output = ""
    var previous: Block?
    var link: (url: String, label: String)?
    // A link's address follows the whole linked text, once, however many styled runs the label has.
    func closeLink() {
      if let link, link.url != link.label { output += " (\(link.url))" }
      link = nil
    }
    for run in parsed.runs {
      let block = Block(run.presentationIntent?.components ?? [])
      if block != previous {
        closeLink()
        if let previous {
          while output.hasSuffix("\n") { output.removeLast() }  // a code block carries its own last line break
          output += block.separator(after: previous)
        }
        output += block.marker
        previous = block
      }
      let piece = String(parsed[run.range].characters)
      if run.link?.absoluteString != link?.url {
        closeLink()
        if let url = run.link?.absoluteString { link = (url, "") }
      }
      link?.label += piece
      output += piece
    }
    closeLink()
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The block a run sits in: the identities of its enclosing blocks tell two blocks apart; the rest is what the
  /// separator and the list marker need.
  private struct Block: Equatable {
    let identities: [Int]
    let rowIdentity: Int?
    let isCell: Bool
    let listOrdinal: Int?
    let isOrdered: Bool

    init(_ components: [PresentationIntent.IntentType]) {
      identities = components.map(\.identity)
      var row: Int?
      var cell = false
      var ordinal: Int?
      var ordered: Bool?
      // Innermost first: the nearest list item and list decide the marker of a nested item.
      for component in components {
        switch component.kind {
        case .tableRow, .tableHeaderRow: row = component.identity
        case .tableCell: cell = true
        case .listItem(let value): ordinal = ordinal ?? value
        case .orderedList: ordered = ordered ?? true
        case .unorderedList: ordered = ordered ?? false
        default: break
        }
      }
      rowIdentity = row
      isCell = cell
      listOrdinal = ordinal
      isOrdered = ordered ?? false
    }

    /// A tab between the cells of a row, a line break between rows and between list items, a blank line otherwise
    /// (so a list or a table starts after a blank line).
    func separator(after previous: Block) -> String {
      if isCell, let rowIdentity, rowIdentity == previous.rowIdentity { return "\t" }
      if isCell && previous.isCell || listOrdinal != nil && previous.listOrdinal != nil { return "\n" }
      return "\n\n"
    }

    var marker: String {
      guard let listOrdinal else { return "" }
      return isOrdered ? "\(listOrdinal). " : "- "
    }
  }
}
