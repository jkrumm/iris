import Foundation
import os

/// JSON-lines crash file: one `StoredEntry` per line, appended per record. A torn last line after a crash is skipped
/// on load. The file lives wherever the app puts it (typically Application Support); the directory is created lazily.
public struct FileTelemetryStore: TelemetryStore {
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
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  public func load() async throws -> [StoredEntry] {
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

  public func removeThrough(sequence: UInt64) async throws {
    let remaining = try await load().filter { $0.sequence > sequence }
    guard !remaining.isEmpty else {
      try await clear()
      return
    }
    try Self.encodeLines(remaining).write(to: fileURL, options: .atomic)
  }

  public func clear() async throws {
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
