import Foundation

/// What the widgets know about the newest memo, and all they are allowed to know: the state, the route chip and the
/// headline (≤ 60 characters). Never the transcript, the reply, the park reason or an error text; a Lock Screen widget is
/// readable without unlocking the phone. The app writes it into the App Group container (``LastMemoSnapshotStoring``), the
/// widget extension reads it; the extension has no network and no Keychain token, so this file is its only source.
public struct LastMemoSnapshot: Codable, Equatable, Sendable {
  /// The four phases the server pushes to the Live Activity; the client-only ones (recording, uploading) are the take
  /// screen's business, a memo is `processing` from the first segment on.
  public enum Phase: String, Codable, Sendable, CaseIterable {
    case processing, needsRoute, done, failed

    /// Parked or finished: nothing further happens without the user, so the state never goes stale.
    public var isSettled: Bool { self != .processing }
  }

  /// The longest a headline gets (the same bound as the Live Activity's and the server's alert headline).
  public static let headlineLimit = 60
  /// The longest a route chip gets (a tab name is user-chosen).
  public static let routeChipLimit = 24
  /// An in-flight memo whose last update is older than this shows no state: the app is not running to say it finished, and
  /// the server's own hang guard is 30 minutes.
  public static let staleAfter: TimeInterval = 30 * 60

  /// The memo's id (a UUID; it is also the trace id). The writer uses it to drop the snapshot of a deleted memo.
  public let memoID: String
  /// When the memo was created: the writer only ever replaces the snapshot with a memo that is not older.
  public let createdAt: Date
  public let phase: Phase
  public let routeChip: String?
  public let headline: String?
  /// When the app last saw this memo change, or, while it is in flight, last confirmed it is still running: the age the
  /// widget shows and where the staleness clock of an in-flight state starts. A settled state keeps its first stamp.
  public let updatedAt: Date

  public init(
    memoID: String, createdAt: Date, phase: Phase, routeChip: String? = nil, headline: String? = nil, updatedAt: Date
  ) {
    self.memoID = memoID
    self.createdAt = createdAt
    self.phase = phase
    self.routeChip = Self.line(routeChip, limit: Self.routeChipLimit)
    self.headline = Self.line(headline, limit: Self.headlineLimit)
    self.updatedAt = updatedAt
  }

  /// A file somebody edited by hand is capped the same way a built value is.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      memoID: try container.decode(String.self, forKey: .memoID),
      createdAt: try container.decode(Date.self, forKey: .createdAt),
      phase: try container.decode(Phase.self, forKey: .phase),
      routeChip: try container.decodeIfPresent(String.self, forKey: .routeChip),
      headline: try container.decodeIfPresent(String.self, forKey: .headline),
      updatedAt: try container.decode(Date.self, forKey: .updatedAt))
  }

  /// Omitted, never null, like the Live Activity's optional fields.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(memoID, forKey: .memoID)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(phase, forKey: .phase)
    try container.encodeIfPresent(routeChip, forKey: .routeChip)
    try container.encodeIfPresent(headline, forKey: .headline)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  private enum CodingKeys: String, CodingKey {
    case memoID, createdAt, phase, routeChip, headline, updatedAt
  }

  /// `text` on one line, cut to `limit` characters (the last one an ellipsis); empty reads as absent.
  static func line(_ text: String?, limit: Int) -> String? {
    guard let text else { return nil }
    let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !line.isEmpty else { return nil }
    guard line.count > limit else { return line }
    return line.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// The same memo in the same state with the same words: a repeated event changes nothing a widget could show except
  /// its age, so it costs no reload.
  func showsSameAs(_ other: LastMemoSnapshot) -> Bool {
    memoID == other.memoID && phase == other.phase && routeChip == other.routeChip && headline == other.headline
  }

  /// When an in-flight snapshot goes stale if nobody refreshes it; `nil` for a settled one, which never does. The one
  /// source of the rule: ``isStale(at:)`` and the idle entry of the timeline both read it.
  public var staleAt: Date? {
    phase.isSettled ? nil : updatedAt.addingTimeInterval(Self.staleAfter)
  }

  /// An in-flight snapshot nobody has refreshed for ``staleAfter``.
  public func isStale(at now: Date) -> Bool {
    guard let staleAt else { return false }
    return now > staleAt
  }
}
