import Foundation

/// What a thread is: a side-effect-free `chat`, or a normal task conversation with Hermes. A kind this build does
/// not know decodes to `.unknown` instead of failing the whole page; `.unknown` is not in `allCases` and is not a filter to send.
public enum ThreadKind: String, Codable, Hashable, Sendable, CaseIterable {
  case chat
  case hermes
  case unknown

  public static var allCases: [ThreadKind] { [.chat, .hermes] }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = ThreadKind(rawValue: raw) ?? .unknown
  }
}

/// A Hermes session that one or more memos ran in. Named `MemoThread` because `Foundation.Thread` exists.
public struct MemoThread: Codable, Hashable, Sendable, Identifiable {
  /// The Hermes session id, which is also `Memo.threadId` of every memo in it.
  public var id: String
  public var kind: ThreadKind
  /// The first words of the thread's first transcript.
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var lastMemoId: String?

  public init(id: String, kind: ThreadKind, title: String, createdAt: Date, updatedAt: Date, lastMemoId: String? = nil)
  {
    self.id = id
    self.kind = kind
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastMemoId = lastMemoId
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, title, createdAt, updatedAt, lastMemoId
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(title, forKey: .title)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(lastMemoId, forKey: .lastMemoId)
  }
}

/// `GET /v1/threads`: one page, newest update first. `nextCursor` is `nil` on the last page.
public struct ThreadPage: Codable, Hashable, Sendable {
  public var items: [MemoThread]
  public var nextCursor: String?

  public init(items: [MemoThread], nextCursor: String? = nil) {
    self.items = items
    self.nextCursor = nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case items, nextCursor
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(items, forKey: .items)
    try container.encode(nextCursor, forKey: .nextCursor)
  }
}

public enum ThreadMessageRole: String, Codable, Hashable, Sendable, CaseIterable {
  case user
  case assistant
}

/// One turn of a thread's conversation, built by the server from its own memos: a memo's transcript (`user`) or its
/// reply (`assistant`, markdown). `createdAt` is when the memo was made, or when its reply arrived.
public struct ThreadMessage: Codable, Hashable, Sendable {
  public var memoId: String
  public var role: ThreadMessageRole
  public var content: String
  public var createdAt: Date

  public init(memoId: String, role: ThreadMessageRole, content: String, createdAt: Date) {
    self.memoId = memoId
    self.role = role
    self.content = content
    self.createdAt = createdAt
  }
}

/// `GET /v1/threads/:id`: the thread, the memos that ran in it (oldest first) and the conversation they make up.
/// Iris's own record: it never depends on Hermes being reachable.
public struct ThreadDetail: Codable, Hashable, Sendable, Identifiable {
  public var thread: MemoThread
  public var memos: [Memo]
  public var messages: [ThreadMessage]

  public var id: String { thread.id }

  public init(thread: MemoThread, memos: [Memo], messages: [ThreadMessage]) {
    self.thread = thread
    self.memos = memos
    self.messages = messages
  }
}

/// Query of `GET /v1/threads`.
public struct ListThreadsQuery: Codable, Hashable, Sendable {
  public var kind: ThreadKind?
  public var limit: Int?
  public var cursor: String?

  public init(kind: ThreadKind? = nil, limit: Int? = nil, cursor: String? = nil) {
    self.kind = kind
    self.limit = limit
    self.cursor = cursor
  }

  public var queryItems: [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let kind { items.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
    if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
    if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
    return items
  }
}
