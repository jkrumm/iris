import Foundation

/// In-memory store: the test fake, also usable as a throwaway store.
public actor InMemoryOutboxStore: OutboxStore {
  private var record: OutboxRecord
  public private(set) var saveCount = 0

  public init(record: OutboxRecord = OutboxRecord()) {
    self.record = record
  }

  public func load() -> OutboxRecord { record }

  public func save(_ record: OutboxRecord) {
    self.record = record
    saveCount += 1
  }
}

/// Production store: one JSON file, replaced atomically on every save.
public struct JSONFileOutboxStore: OutboxStore {
  private let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() async throws -> OutboxRecord {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return OutboxRecord() }
    return try JSONDecoder().decode(OutboxRecord.self, from: Data(contentsOf: fileURL))
  }

  public func save(_ record: OutboxRecord) async throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
  }
}
