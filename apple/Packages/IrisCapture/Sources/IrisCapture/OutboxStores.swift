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

/// Test fake of a queue file this build cannot read: `load()` fails with `undecodable` until `quarantine()` sets the file
/// aside, after which the queue is empty. Saves while unreadable are refused, as writing over the file would lose it.
public actor UnreadableOutboxStore: OutboxStore {
  private var isUnreadable = true
  private var record = OutboxRecord()
  private var setAside: [URL] = []

  public init() {}

  public func load() throws -> OutboxRecord {
    if isUnreadable { throw OutboxStoreError.undecodable }
    return record
  }

  public func save(_ record: OutboxRecord) throws {
    if isUnreadable { throw OutboxStoreError.undecodable }
    self.record = record
  }

  public func quarantine() async throws -> URL? {
    guard isUnreadable else { return nil }
    isUnreadable = false
    let url = URL(fileURLWithPath: "/in-memory/outbox.quarantined-\(setAside.count + 1).json")
    setAside.append(url)
    return url
  }

  public func quarantined() async -> [URL] { setAside }
}

/// Production store: one JSON file, replaced atomically on every save.
public struct JSONFileOutboxStore: OutboxStore {
  private let fileURL: URL
  private let now: @Sendable () -> Date

  public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.fileURL = fileURL
    self.now = now
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

extension JSONFileOutboxStore {
  /// `outbox.quarantined-20261029T101500Z.json`, next to `outbox.json`.
  private var quarantinePrefix: String { "\(fileURL.deletingPathExtension().lastPathComponent).quarantined-" }

  /// Renames the queue file aside and keeps it: its segment files stay where they are, and the next `load()` finds no file
  /// and opens an empty queue. A second quarantine in the same second gets a counter, so a name is never reused.
  public func quarantine() async throws -> URL? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let directory = fileURL.deletingLastPathComponent()
    let stamp = now().formatted(Date.ISO8601FormatStyle(timeZone: .gmt).dateSeparator(.omitted).timeSeparator(.omitted))
    var target = directory.appending(path: "\(quarantinePrefix)\(stamp).json")
    var counter = 1
    while FileManager.default.fileExists(atPath: target.path) {
      counter += 1
      target = directory.appending(path: "\(quarantinePrefix)\(stamp)-\(counter).json")
    }
    try FileManager.default.moveItem(at: fileURL, to: target)
    Log.outbox.notice("outbox file set aside as \(target.lastPathComponent, privacy: .public)")
    return target
  }

  public func quarantined() async -> [URL] {
    let directory = fileURL.deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasPrefix(quarantinePrefix) }.sorted().map { directory.appending(path: $0) }
  }
}

public enum OutboxStoreError: Error, Sendable, Equatable {
  /// The saved queue is there but this build cannot read it; it is left as it is.
  case undecodable
}
