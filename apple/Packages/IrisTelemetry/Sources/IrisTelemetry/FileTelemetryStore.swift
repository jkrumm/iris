import Foundation
import os

/// JSON-lines crash file: one `StoredEntry` per line, appended per record. A torn last line after a crash is skipped
/// on load. The file lives wherever the app puts it (typically Application Support); the directory is created lazily.
///
/// An actor so every operation is atomic with respect to the others: `removeThrough` reads, filters and rewrites the
/// file, and no `append` may land between the read and the write. The private helpers are synchronous, so no
/// operation suspends mid-way.
public actor FileTelemetryStore: TelemetryStore {
  private let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func append(_ entries: [StoredEntry]) async throws {
    guard !entries.isEmpty else { return }
    let data = try Self.encodeLines(entries)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: fileURL.path) else {
      try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: fileURL, options: .atomic)
      return
    }
    let handle = try FileHandle(forUpdating: fileURL)
    defer { try? handle.close() }
    try Self.cutTornTail(of: handle)
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  /// A crash mid-write leaves a last line without its newline. Appending after it would glue the next record to the fragment and
  /// lose both, so the fragment is cut off first.
  private static func cutTornTail(of handle: FileHandle) throws {
    let end = try handle.seekToEnd()
    guard end > 0 else { return }
    try handle.seek(toOffset: end - 1)
    guard let last = try handle.read(upToCount: 1), last.first != 0x0A else { return }
    try handle.seek(toOffset: 0)
    let data = try handle.readToEnd() ?? Data()
    let keep = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
    try handle.truncate(atOffset: UInt64(keep))
  }

  public func load() async throws -> [StoredEntry] {
    try loadEntries()
  }

  public func removeThrough(sequence: UInt64) async throws {
    let remaining = try loadEntries().filter { $0.sequence > sequence }
    guard !remaining.isEmpty else {
      try removeFile()
      return
    }
    try Self.encodeLines(remaining).write(to: fileURL, options: .atomic)
  }

  public func clear() async throws {
    try removeFile()
  }

  private func loadEntries() throws -> [StoredEntry] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data = try Data(contentsOf: fileURL)
    let decoder = TelemetryCoding.makeDecoder()
    var entries: [StoredEntry] = []
    var skipped = 0
    for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
      guard let entry = try? decoder.decode(StoredEntry.self, from: Data(line)) else {
        skipped += 1
        continue
      }
      entries.append(entry)
    }
    if skipped > 0 {
      Logger.telemetry.warning("Skipped \(skipped, privacy: .public) unreadable telemetry lines")
    }
    return entries.sorted { $0.sequence < $1.sequence }
  }

  private func removeFile() throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }

  private static func encodeLines(_ entries: [StoredEntry]) throws -> Data {
    let encoder = TelemetryCoding.makeEncoder()
    var data = Data()
    for entry in entries {
      data.append(try encoder.encode(entry))
      data.append(0x0A)
    }
    return data
  }
}
