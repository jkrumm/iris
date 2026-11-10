import Foundation

/// Decides when a growing reply reaches the screen: tokens arrive faster than a layout pass is worth, so text is published
/// at once when 80 ms passed since the last publish, or when it brought a new line and 16 ms passed; otherwise the caller
/// is told when to publish. Pure: the caller supplies the timestamps (a `Duration` since any fixed origin) and does the
/// waiting.
struct StreamBuffer {
  enum Decision: Equatable {
    case publish(String)
    case wait(until: Duration)
  }

  static let interval = Duration.milliseconds(80)
  static let lineInterval = Duration.milliseconds(16)

  private(set) var published = ""
  private var lastPublish: Duration?

  mutating func offer(_ text: String, at now: Duration) -> Decision {
    guard let last = lastPublish else { return publish(text, at: now) }
    if text == published { return .publish(text) }
    let elapsed = now - last
    if elapsed >= Self.interval { return publish(text, at: now) }
    if hasNewline(since: published, in: text) {
      if elapsed >= Self.lineInterval { return publish(text, at: now) }
      return .wait(until: last + Self.lineInterval)
    }
    return .wait(until: last + Self.interval)
  }

  /// Publishes `text` now, whatever the clock says (the deadline of a `wait` has come).
  mutating func publish(_ text: String, at now: Duration) -> Decision {
    published = text
    lastPublish = now
    return .publish(text)
  }

  private func hasNewline(since published: String, in text: String) -> Bool {
    guard text.utf8.starts(with: published.utf8) else { return true }
    return text.utf8.dropFirst(published.utf8.count).contains(UInt8(ascii: "\n"))
  }
}
