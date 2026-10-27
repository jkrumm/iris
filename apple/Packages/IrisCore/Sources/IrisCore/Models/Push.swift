import Foundation

/// The `aps.content-state` of a Live Activity update or end push. The server never sends `inputName`
/// (the device knows it), so the client declares it optional; it is omitted when `nil`. `routeChip` and
/// `headline` are omitted, not `null`, while unknown.
public struct LiveActivityContentState: Codable, Hashable, Sendable {
  public var phase: LiveActivityPhase
  public var routeChip: String?
  public var headline: String?
  public var hasReply: Bool
  public var inputName: String?

  public init(
    phase: LiveActivityPhase,
    routeChip: String? = nil,
    headline: String? = nil,
    hasReply: Bool,
    inputName: String? = nil
  ) {
    self.phase = phase
    self.routeChip = routeChip
    self.headline = headline
    self.hasReply = hasReply
    self.inputName = inputName
  }
}

/// The whole alert push body. `memo` is the id the app opens on tap.
public struct PushAlert: Codable, Hashable, Sendable {
  public struct Aps: Codable, Hashable, Sendable {
    public struct Alert: Codable, Hashable, Sendable {
      public var title: String
      public var body: String

      public init(title: String, body: String) {
        self.title = title
        self.body = body
      }
    }

    public var alert: Alert
    public var mutableContent: Int
    public var category: String
    public var threadID: String
    public var sound: String

    public init(alert: Alert, mutableContent: Int = 1, category: String, threadID: String, sound: String) {
      self.alert = alert
      self.mutableContent = mutableContent
      self.category = category
      self.threadID = threadID
      self.sound = sound
    }

    private enum CodingKeys: String, CodingKey {
      case alert
      case mutableContent = "mutable-content"
      case category
      case threadID = "thread-id"
      case sound
    }
  }

  public var aps: Aps
  public var memo: String

  public init(aps: Aps, memo: String) {
    self.aps = aps
    self.memo = memo
  }
}
