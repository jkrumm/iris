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

/// Body of `PATCH /v1/memos/:id`: the flags to change, at least one (the server answers 400 for none). A `nil` flag is
/// omitted and left as it is.
public struct SetFlagsRequest: Codable, Hashable, Sendable {
  public var done: Bool?
  public var favorite: Bool?
  public var archived: Bool?

  public init(done: Bool? = nil, favorite: Bool? = nil, archived: Bool? = nil) {
    self.done = done
    self.favorite = favorite
    self.archived = archived
  }
}

/// Query of `GET /v1/memos`. `q` searches the transcript and summary headline (case, umlaut and prefix insensitive,
/// terms ANDed, at most 200 characters); `route` and `state` filter exactly. `favorite` keeps the favorites, `archived`
/// lists only the archived memos (they are hidden otherwise), `kind` keeps the memos whose thread has that kind (the
/// Chats filter). The server accepts `favorite` and `archived` only as `true`, so `false` sends nothing. All combine.
public struct ListMemosQuery: Hashable, Sendable {
  public var limit: Int?
  public var cursor: String?
  public var q: String?
  public var route: RouteDestination?
  public var state: MemoState?
  public var favorite: Bool
  public var archived: Bool
  public var kind: ThreadKind?

  public init(
    limit: Int? = nil, cursor: String? = nil, q: String? = nil, route: RouteDestination? = nil,
    state: MemoState? = nil, favorite: Bool = false, archived: Bool = false, kind: ThreadKind? = nil
  ) {
    self.limit = limit
    self.cursor = cursor
    self.q = q
    self.route = route
    self.state = state
    self.favorite = favorite
    self.archived = archived
    self.kind = kind
  }

  public var queryItems: [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
    if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
    if let q { items.append(URLQueryItem(name: "q", value: q)) }
    if let route { items.append(URLQueryItem(name: "route", value: route.rawValue)) }
    if let state { items.append(URLQueryItem(name: "state", value: state.rawValue)) }
    if favorite { items.append(URLQueryItem(name: "favorite", value: "true")) }
    if archived { items.append(URLQueryItem(name: "archived", value: "true")) }
    if let kind, kind != .unknown { items.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
    return items
  }
}

/// The query as the contract fixtures spell it: the values of the query string, so a flag is the string `"true"`.
extension ListMemosQuery: Codable {
  private enum CodingKeys: String, CodingKey {
    case limit, cursor, q, route, state, favorite, archived, kind
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      limit: try container.decodeIfPresent(Int.self, forKey: .limit),
      cursor: try container.decodeIfPresent(String.self, forKey: .cursor),
      q: try container.decodeIfPresent(String.self, forKey: .q),
      route: try container.decodeIfPresent(RouteDestination.self, forKey: .route),
      state: try container.decodeIfPresent(MemoState.self, forKey: .state),
      favorite: try Self.decodeFlag(container, .favorite),
      archived: try Self.decodeFlag(container, .archived),
      kind: try container.decodeIfPresent(ThreadKind.self, forKey: .kind))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(limit, forKey: .limit)
    try container.encodeIfPresent(cursor, forKey: .cursor)
    try container.encodeIfPresent(q, forKey: .q)
    try container.encodeIfPresent(route, forKey: .route)
    try container.encodeIfPresent(state, forKey: .state)
    if favorite { try container.encode("true", forKey: .favorite) }
    if archived { try container.encode("true", forKey: .archived) }
    try container.encodeIfPresent(kind, forKey: .kind)
  }

  private static func decodeFlag(
    _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
  ) throws -> Bool {
    guard let value = try container.decodeIfPresent(String.self, forKey: key) else { return false }
    guard value == "true" else {
      throw DecodingError.dataCorruptedError(
        forKey: key, in: container, debugDescription: "a flag filter is only ever \"true\"")
    }
    return true
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
