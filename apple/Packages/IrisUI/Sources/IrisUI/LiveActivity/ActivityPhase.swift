import SwiftUI

/// The phases a memo's Live Activity goes through. IrisUI has no dependency on `IrisCore`: the widget maps its own phase
/// onto this one.
public enum ActivityPhase: String, Sendable, CaseIterable {
  case recording, paused, uploading, processing, needsRoute, done, failed

  /// The four stages of a memo, as the activity shows them: record, upload, process, done. `nil` when the phase is
  /// outside the sequence (a failure shows no progress).
  public var stage: Int? {
    switch self {
    case .recording, .paused: 0
    case .uploading: 1
    case .processing, .needsRoute: 2
    case .done: 3
    case .failed: nil
    }
  }

  var symbol: String {
    switch self {
    case .recording: "mic.fill"
    case .paused: "pause.fill"
    case .uploading: "arrow.up"
    case .processing: "waveform"
    case .needsRoute: "arrow.triangle.branch"
    case .done: "checkmark"
    case .failed: "exclamationmark.triangle.fill"
    }
  }

  /// Phases that count up from the start of the memo.
  var showsTimer: Bool { self == .recording || self == .processing }
}

/// Everything the Live Activity views show, as plain values: the widget builds it from `ContentState` and the attributes,
/// the snapshot tests build it directly. Strings are localized by the caller.
public struct ActivityPresentation: Equatable, Sendable {
  public var phase: ActivityPhase
  public var phaseTitle: String
  public var modeLabel: String
  public var subtitle: String?
  public var inputName: String?
  public var routeChip: String?
  public var headline: String?
  /// A line about another memo that is still on its way ("1 earlier memo is still sending").
  public var note: String?
  public var start: Date
  /// Stops the timer at this instant (the snapshot tests).
  public var timerFrozenAt: Date?

  public init(
    phase: ActivityPhase, phaseTitle: String, modeLabel: String, subtitle: String? = nil, inputName: String? = nil,
    routeChip: String? = nil, headline: String? = nil, note: String? = nil, start: Date, timerFrozenAt: Date? = nil
  ) {
    self.phase = phase
    self.phaseTitle = phaseTitle
    self.modeLabel = modeLabel
    self.subtitle = subtitle
    self.inputName = inputName
    self.routeChip = routeChip
    self.headline = headline
    self.note = note
    self.start = start
    self.timerFrozenAt = timerFrozenAt
  }
}
