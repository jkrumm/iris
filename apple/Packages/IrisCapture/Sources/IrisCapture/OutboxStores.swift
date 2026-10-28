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

  /// A file that cannot be read or decoded is an error, never an empty queue: the queued memos and takes in it (and the
  /// segment files they own) stay on disk untouched, and the app says its outbox cannot be opened. A build that reads a
  /// newer build's file (an enum case it does not know) gets the same refusal instead of dropping the queue.
  public func load() async throws -> OutboxRecord {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return OutboxRecord() }
    let data = try Data(contentsOf: fileURL)
    do {
      return try JSONDecoder().decode(OutboxRecord.self, from: data)
    } catch {
      Log.outbox.error("outbox file cannot be decoded, left untouched: \(String(describing: error), privacy: .public)")
      throw OutboxStoreError.undecodable
    }
  }

  public func save(_ record: OutboxRecord) async throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
  }
}

public enum OutboxStoreError: Error, Sendable, Equatable {
  /// The saved queue is there but this build cannot read it; it is left as it is.
  case undecodable
}
