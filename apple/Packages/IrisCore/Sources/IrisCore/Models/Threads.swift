import Foundation

/// A Hermes session that one or more memos ran in. Named `MemoThread` because `Foundation.Thread` exists.
public struct MemoThread: Codable, Hashable, Sendable, Identifiable {
  /// The Hermes session id, which is also `Memo.threadId` of every memo in it.
  public var id: String
  /// Wire passthrough ("hermes", "chat" on old rows); the app ignores it.
  public var kind: String
  /// The first words of the thread's first transcript.
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var lastMemoId: String?

  public init(id: String, kind: String, title: String, createdAt: Date, updatedAt: Date, lastMemoId: String? = nil) {
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
