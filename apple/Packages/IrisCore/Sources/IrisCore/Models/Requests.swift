import Foundation

public struct CreateMemoRequest: Codable, Hashable, Sendable {
  public var id: String
  public var mode: MemoMode
  public var startedAt: Date

  public init(id: String, mode: MemoMode, startedAt: Date) {
    self.id = id
    self.mode = mode
    self.startedAt = startedAt
  }
}

public struct CompleteMemoRequest: Codable, Hashable, Sendable {
  public var segmentCount: Int

  public init(segmentCount: Int) {
    self.segmentCount = segmentCount
  }
}

public struct RetryMemoRequest: Codable, Hashable, Sendable {
  public var from: MemoStep

  public init(from: MemoStep) {
    self.from = from
  }
}

/// Body of `POST /v1/memos/:id/route`. `tab` is required for `herdr` and rejected for the others; it is
/// omitted when `nil`.
public struct RouteRequest: Codable, Hashable, Sendable {
  public var destination: RouteDestination
  public var tab: String?

  public init(destination: RouteDestination, tab: String? = nil) {
    self.destination = destination
    self.tab = tab
  }
}

public struct ActivityTokenRequest: Codable, Hashable, Sendable {
  /// The Live Activity push token, hex-encoded (at most 1024 characters).
  public var token: String

  public init(token: String) {
    self.token = token
  }
}

/// Query of `GET /v1/memos`.
public struct ListMemosQuery: Codable, Hashable, Sendable {
  public var limit: Int?
  public var cursor: String?

  public init(limit: Int? = nil, cursor: String? = nil) {
    self.limit = limit
    self.cursor = cursor
  }

  public var queryItems: [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
    if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
    return items
  }
}

/// Query of `GET /v1/memos/:id/result`. `wait` is the long-poll budget in seconds (the server caps it).
public struct MemoResultQuery: Codable, Hashable, Sendable {
  public var wait: Double?

  public init(wait: Double? = nil) {
    self.wait = wait
  }

  public var queryItems: [URLQueryItem] {
    guard let wait else { return [] }
    return [URLQueryItem(name: "wait", value: String(wait))]
  }
}
