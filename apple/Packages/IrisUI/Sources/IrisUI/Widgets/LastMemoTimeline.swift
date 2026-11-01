import Foundation

/// What the last-memo widget's timeline holds, decided here so it is unit tested and the extension only maps it onto
/// WidgetKit types (`TimelineEntry`, `TimelineEntryRelevance`, `Timeline(policy: .never)`).
public struct LastMemoTimelinePlan: Equatable, Sendable {
  /// Smart Stack relevance of an entry (iPhone reads the entry's, the provider-level `relevance()` is watchOS).
  public struct Relevance: Equatable, Sendable {
    public var score: Float
    public var duration: TimeInterval
  }

  public struct Entry: Equatable, Sendable {
    public var date: Date
    public var content: LastMemoWidgetContent
    public var relevance: Relevance?
  }

  /// In date order; the first is the current one.
  public var entries: [Entry]
  // No reload date: the policy is `.never`. The app reloads the timeline on every change it sees; the one change nobody
  // announces, an in-flight state going stale, is the second entry.

  /// The current entry for `snapshot` at `now`, and for an in-flight snapshot a second one at its `staleAt` that reads
  /// `idle`, so a widget never claims a memo is still processing for a day. A settled snapshot has one entry.
  public init(snapshot: LastMemoSnapshot?, now: Date) {
    let current = Entry(
      date: now, content: LastMemoWidgetContent(snapshot, at: now),
      relevance: snapshot.flatMap { $0.isStale(at: now) ? nil : Self.relevance($0) })
    guard let staleAt = snapshot?.staleAt, staleAt > now else {
      entries = [current]
      return
    }
    entries = [current, Entry(date: staleAt, content: .idle, relevance: nil)]
  }

  /// A parked or failed memo asks for attention for an hour, a running or just-finished one for a while.
  static func relevance(_ snapshot: LastMemoSnapshot) -> Relevance {
    switch snapshot.phase {
    case .needsRoute: Relevance(score: 100, duration: 60 * 60)
    case .failed: Relevance(score: 60, duration: 60 * 60)
    case .processing: Relevance(score: 40, duration: 10 * 60)
    case .done: Relevance(score: 20, duration: 15 * 60)
    }
  }
}
