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

  /// A file that cannot be decoded is moved aside (`<name>.corrupt`) and the queue starts empty: an unreadable
  /// queue must not keep the app from sending anything new.
  public func load() async throws -> OutboxRecord {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return OutboxRecord() }
    let data = try Data(contentsOf: fileURL)
    do {
      return try JSONDecoder().decode(OutboxRecord.self, from: data)
    } catch {
      Log.outbox.error("outbox file unreadable, starting empty: \(String(describing: error), privacy: .public)")
      let aside = fileURL.appendingPathExtension("corrupt")
      try? FileManager.default.removeItem(at: aside)
      try FileManager.default.moveItem(at: fileURL, to: aside)
      return OutboxRecord()
    }
  }

  public func save(_ record: OutboxRecord) async throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
  }
}
