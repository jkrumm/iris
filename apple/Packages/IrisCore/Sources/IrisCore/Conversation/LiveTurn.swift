import Foundation

/// What is known of a reply while `act` runs: the text streamed so far and the tools started. Display only: never logged,
/// stored or sent to telemetry.
public struct LiveTurn: Equatable, Sendable {
  public var attempt: Int
  /// The highest `seq` applied; 0 when none.
  public var seq: Int
  public var text: String
  /// The tools started in this attempt, in order (a tool may repeat).
  public var tools: [String]
  /// A delta was missed (the first one seen was not `seq` 1, or one was skipped): `text` has a hole until a seed fills it.
  public var hasGap: Bool

  public init(attempt: Int, seq: Int = 0, text: String = "", tools: [String] = [], hasGap: Bool = false) {
    self.attempt = attempt
    self.seq = seq
    self.text = text
    self.tools = tools
    self.hasGap = hasGap
  }

  /// The text to show: nothing while it has a hole.
  public var shownText: String { hasGap ? "" : text }
  public var currentTool: String? { tools.last }
}

/// The live turns of the memos a screen follows, folded from `memo.delta` / `memo.activity` and seeded from a memo detail's
/// `partialReply`. `attempt` is a per-memo in-memory counter that restarts at 1 after a server restart, so a (re)connect
/// (`.ready`) forgets everything and the caller seeds again.
public struct LiveTurns: Equatable, Sendable {
  private var turns: [String: LiveTurn] = [:]

  public init() {}

  public func turn(for memoID: String) -> LiveTurn? { turns[memoID] }

  public mutating func reset() { turns = [:] }

  public mutating func drop(memoID: String) { turns[memoID] = nil }

  public mutating func apply(_ event: ServerEvent) {
    switch event {
    case .ready:
      reset()
    case .memoDelta(let delta):
      apply(delta)
    case .memoActivity(let activity):
      apply(activity)
    case .memoUpdated, .memoDone:
      break
    }
  }

  public mutating func seed(memoID: String, partial: PartialReply?) {
    guard let partial else { return }
    guard var turn = turns[memoID] else {
      turns[memoID] = LiveTurn(attempt: partial.attempt, seq: partial.seq, text: partial.text)
      return
    }
    guard turn.attempt == partial.attempt else {
      turns[memoID] = LiveTurn(attempt: partial.attempt, seq: partial.seq, text: partial.text)
      return
    }
    guard partial.seq >= turn.seq else { return }
    turn.text = partial.text
    turn.seq = partial.seq
    turn.hasGap = false
    turns[memoID] = turn
  }

  private mutating func apply(_ delta: MemoDelta) {
    guard var turn = turns[delta.id], turn.attempt == delta.attempt else {
      turns[delta.id] = LiveTurn(
        attempt: delta.attempt, seq: delta.seq, text: delta.text, hasGap: delta.seq != 1)
      return
    }
    guard delta.seq > turn.seq else { return }
    if delta.seq != turn.seq + 1 { turn.hasGap = true }
    turn.text += delta.text
    turn.seq = delta.seq
    turns[delta.id] = turn
  }

  private mutating func apply(_ activity: MemoActivity) {
    guard var turn = turns[activity.id], turn.attempt == activity.attempt else {
      turns[activity.id] = LiveTurn(attempt: activity.attempt, tools: [activity.tool])
      return
    }
    turn.tools.append(activity.tool)
    turns[activity.id] = turn
  }
}
