import Foundation

public struct CreateMemoRequest: Codable, Hashable, Sendable {
  public var id: String
  public var mode: MemoMode
  public var startedAt: Date
  /// Continues this thread (`MemoThread.id`): the memo is delivered into its Hermes session. Omitted when `nil`;
  /// an unknown thread is a 404 and another thread on a replay a 409.
  public var threadId: String?

  public init(id: String, mode: MemoMode, startedAt: Date, threadId: String? = nil) {
    self.id = id
    self.mode = mode
    self.startedAt = startedAt
    self.threadId = threadId
  }
}

/// Body of `POST /v1/memos/text`. The server trims `text` and answers 400 when it is empty or longer than
/// `maxTextCharacters` Unicode code points (`unicodeScalars`, not Swift `Character`s) once trimmed.
public struct CreateTextMemoRequest: Codable, Hashable, Sendable {
  /// The server's limit on the trimmed text, in Unicode code points.
  public static let maxTextCharacters = 20_000

  public var id: String
  public var mode: MemoMode
  public var startedAt: Date
  public var text: String
  /// As on `CreateMemoRequest`: continues this thread; omitted when `nil`.
  public var threadId: String?

  public init(id: String, mode: MemoMode, startedAt: Date, text: String, threadId: String? = nil) {
    self.id = id
    self.mode = mode
    self.startedAt = startedAt
    self.text = text
    self.threadId = threadId
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

/// Query of `GET /v1/memos`. `q` searches the transcript and summary headline (case, umlaut and prefix insensitive,
/// terms ANDed, at most 200 characters); `route` and `state` filter exactly. All combine.
public struct ListMemosQuery: Codable, Hashable, Sendable {
  public var limit: Int?
  public var cursor: String?
  public var q: String?
  public var route: RouteDestination?
  public var state: MemoState?

  public init(
    limit: Int? = nil, cursor: String? = nil, q: String? = nil, route: RouteDestination? = nil,
    state: MemoState? = nil
  ) {
    self.limit = limit
    self.cursor = cursor
    self.q = q
    self.route = route
    self.state = state
  }

  public var queryItems: [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
    if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
    if let q { items.append(URLQueryItem(name: "q", value: q)) }
    if let route { items.append(URLQueryItem(name: "route", value: route.rawValue)) }
    if let state { items.append(URLQueryItem(name: "state", value: state.rawValue)) }
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
