import Foundation

/// One step of the waterfall, already worded: the view draws what it is given. `start` and `length` are fractions of
/// the whole run (0...1), so each bar begins where the previous step ended and its width is proportional to its duration.
public struct StepWaterfallRow: Identifiable, Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case waiting, running, done, failed
  }

  /// A "faster / slower than usual" tag; only ever set where the stats baseline has enough samples.
  public struct Badge: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
      case faster, slower
    }

    public var text: String
    public var tone: Tone

    public init(text: String, tone: Tone) {
      self.text = text
      self.tone = tone
    }
  }

  public var id: String
  public var title: String
  public var phase: Phase
  /// The one `duration · cost` chip. For a waiting step the plain "waiting" word, drawn without a chip.
  public var metric: String?
  public var badge: Badge?
  /// "2 attempts": only set when the server tried the step more than once.
  public var attempts: String?
  public var error: String?
  /// A failed step the memo does not need (a failed summary on a finished memo): the row reads as a warning, not as the
  /// memo's failure.
  public var isOptional: Bool
  /// What the row says about an optional step ("the memo is done without it"); shown whenever it is set.
  public var optionalNote: String?
  /// The title of the [Retry from step] button; set on the step the memo failed at.
  public var retryTitle: String?
  public var start: Double
  public var length: Double

  public init(
    id: String,
    title: String,
    phase: Phase,
    metric: String? = nil,
    badge: Badge? = nil,
    attempts: String? = nil,
    error: String? = nil,
    isOptional: Bool = false,
    optionalNote: String? = nil,
    retryTitle: String? = nil,
    start: Double = 0,
    length: Double = 0
  ) {
    self.id = id
    self.title = title
    self.phase = phase
    self.metric = metric
    self.badge = badge
    self.attempts = attempts
    self.error = error
    self.isOptional = isOptional
    self.optionalNote = optionalNote
    self.retryTitle = retryTitle
    self.start = min(max(start, 0), 1)
    self.length = min(max(length, 0), 1 - self.start)
  }
}
