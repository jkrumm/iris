import Foundation

#if canImport(AVFAudio)
  import AVFAudio
#endif

/// What a startup sweep of the capture directory did with the segment files nobody owned.
public struct SweepReport: Sendable, Equatable {
  /// Files attached to the take they belong to; they go up with the rest of it.
  public var adopted: [URL] = []
  /// Files moved into the quarantine folder (their new location).
  public var quarantined: [URL] = []
  /// Files left where they are because a quarantined queue file names them.
  public var kept: [URL] = []
  /// Files the sweep could neither attach nor move: still in the capture directory, tried again at the next launch. Settings
  /// lists them so they are not invisible.
  public var stuck: [URL] = []

  public var isEmpty: Bool { adopted.isEmpty && quarantined.isEmpty && kept.isEmpty && stuck.isEmpty }
}

/// Reads a segment file back: its size and length, or `nil` when it is not a complete audio file (a take the app died in the
/// middle of leaves an AAC file without its trailer).
public typealias SegmentInspector = @Sendable (URL) -> (byteCount: Int, duration: TimeInterval)?

/// A file the sweep set aside, for Settings to count and size. Never deleted by the app.
public struct SetAsideFile: Sendable, Equatable {
  public let url: URL
  public let byteCount: Int
  public let modifiedAt: Date?

  public init(url: URL, byteCount: Int, modifiedAt: Date?) {
    self.url = url
    self.byteCount = byteCount
    self.modifiedAt = modifiedAt
  }
}

/// The capture directory as the startup sweep sees it: the segment files in it, how to read one back and where a stray goes.
/// Production: `DirectorySegmentFiles`.
public protocol SegmentFileStore: Sendable {
  /// The `.m4a` files directly in the capture directory.
  func segmentFiles() async -> [URL]
  /// A complete audio file's size and length, `nil` when it does not play.
  func inspect(_ url: URL) -> (byteCount: Int, duration: TimeInterval)?
  /// Moves the file out of the capture directory and keeps it; its new location, `nil` when it could not be moved (it stays
  /// where it is and the next launch sweeps it again). Never deletes.
  func setAside(_ url: URL) async -> URL?
  /// Every file earlier sweeps set aside, oldest first.
  func setAsideFiles() async -> [SetAsideFile]
  /// Name, size and date of files in the capture directory, for Settings; those that are no longer there are left out.
  func describe(_ urls: [URL]) async -> [SetAsideFile]
}

extension SegmentFileStore {
  public func describe(_ urls: [URL]) async -> [SetAsideFile] {
    urls.map { SetAsideFile(url: $0, byteCount: 0, modifiedAt: nil) }
  }
}

/// Production store: a capture directory and a `quarantine/` folder next to its files.
public struct DirectorySegmentFiles: SegmentFileStore {
  private let directory: URL
  private let quarantineDirectory: URL
  private let inspector: SegmentInspector

  public init(
    directory: URL, quarantineDirectory: URL? = nil, inspect: @escaping SegmentInspector = Outbox.inspectAudioFile
  ) {
    self.directory = directory
    self.quarantineDirectory = quarantineDirectory ?? directory.appending(path: "quarantine")
    inspector = inspect
  }

  public func segmentFiles() async -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".m4a") }.map { directory.appending(path: $0) }
  }

  public func inspect(_ url: URL) -> (byteCount: Int, duration: TimeInterval)? { inspector(url) }

  public func describe(_ urls: [URL]) async -> [SetAsideFile] {
    urls.compactMap { url in
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
        // Still there but unreadable: listed by name with an unknown size, not dropped from the list.
        return FileManager.default.fileExists(atPath: url.path)
          ? SetAsideFile(url: url, byteCount: 0, modifiedAt: nil) : nil
      }
      return SetAsideFile(
        url: url, byteCount: (attributes[.size] as? Int) ?? 0, modifiedAt: attributes[.modificationDate] as? Date)
    }
  }

  /// Moves the file into the quarantine folder under its own name, or a unique one when that is taken.
  public func setAside(_ url: URL) async -> URL? {
    do {
      try FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
      var target = quarantineDirectory.appending(path: url.lastPathComponent)
      if FileManager.default.fileExists(atPath: target.path) {
        let stem = url.deletingPathExtension().lastPathComponent
        target = quarantineDirectory.appending(path: "\(stem)-\(UUID().uuidString.prefix(8)).m4a")
      }
      try FileManager.default.moveItem(at: url, to: target)
      return target
    } catch {
      Log.outbox.error("segment file not quarantined: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  public func setAsideFiles() async -> [SetAsideFile] {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: quarantineDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
    return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
      return SetAsideFile(url: url, byteCount: values.fileSize ?? 0, modifiedAt: values.contentModificationDate)
    }
  }
}

extension Outbox {
  /// The sweep that runs once at launch, after the queue is loaded and before anything is sent or recorded: a segment file
  /// is written before the queue file that names it is saved, so a crash or a failed save leaves files no record owns.
  ///
  /// Each file in the capture directory that the queue does not know is either **adopted** (it belongs to a take the queue
  /// holds and is a complete audio file that fills one of its indices) or **set aside** in the quarantine folder. **Nothing is
  /// deleted.** A file that a set-aside queue file names stays where it is, so that queue can still be read back against its
  /// files.
  @discardableResult
  public func sweepOrphans(using files: any SegmentFileStore) async -> SweepReport {
    var report = SweepReport()
    let owned = segmentFileNames()
    // By take and index, so a take that grows is adopted in order.
    let candidates = await files.segmentFiles().filter { !owned.contains($0.lastPathComponent) }.sorted {
      guard let left = Self.parse($0.lastPathComponent), let right = Self.parse($1.lastPathComponent) else {
        return $0.lastPathComponent < $1.lastPathComponent
      }
      return (left.0.uuidString, left.1) < (right.0.uuidString, right.1)
    }
    guard !candidates.isEmpty else { return await concluded(report, files: files) }
    var heldQueues: [Data] = []
    var unreadable: [String] = []
    for file in await setAsideQueueFiles() {
      do {
        heldQueues.append(try Data(contentsOf: file))
      } catch {
        unreadable.append(file.lastPathComponent)
        Log.outbox.error(
          "set-aside queue \(file.lastPathComponent, privacy: .public) cannot be read: \(String(describing: error), privacy: .public)"
        )
      }
    }

    for url in candidates {
      let name = url.lastPathComponent
      var isFile = ObjCBool(false)
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFile), !isFile.boolValue else { continue }
      if !unreadable.isEmpty {
        // A queue that was set aside may name this file and cannot be checked: every candidate stays where it is.
        report.kept.append(url)
      } else if heldQueues.contains(where: { $0.range(of: Data(name.utf8)) != nil }) {
        report.kept.append(url)
      } else if adopt(url, name: name, files: files) {
        report.adopted.append(url)
      } else if let moved = await files.setAside(url) {
        report.quarantined.append(moved)
      } else {
        report.stuck.append(url)
      }
    }
    // Saved before anything goes up, as for any new segment (the save releases the withheld ones).
    if !report.adopted.isEmpty { await flush() }
    return await concluded(report, files: files)
  }

  /// Logs the sweep and remembers the files it could not deal with, for Settings.
  private func concluded(_ report: SweepReport, files: any SegmentFileStore) async -> SweepReport {
    noteStrays(report.stuck, in: files)
    guard !report.isEmpty else { return report }
    Log.outbox.notice(
      "capture sweep: \(report.adopted.count) adopted, \(report.quarantined.count) quarantined, \(report.kept.count) kept, \(report.stuck.count) stuck"
    )
    return report
  }

  /// `<memo id>-<index>.m4a` that belongs to a take the queue holds (`OutboxStateMachine.adopt`) and plays.
  private func adopt(_ url: URL, name: String, files: any SegmentFileStore) -> Bool {
    guard let (memoID, index) = Self.parse(name), let audio = files.inspect(url), audio.byteCount > 0 else {
      return false
    }
    return adoptSwept(
      ClosedSegment(memoID: memoID, index: index, fileURL: url, byteCount: audio.byteCount, duration: audio.duration))
  }

  /// The recorder's file name: `<memo uuid>-<segment index>.m4a`.
  static func parse(_ name: String) -> (MemoID, Int)? {
    let stem = name.dropLast(".m4a".count)
    guard stem.count > 37, let separator = stem.index(stem.startIndex, offsetBy: 36, limitedBy: stem.endIndex),
      stem[separator] == "-", let memoID = UUID(uuidString: String(stem[..<separator])),
      let index = Int(stem[stem.index(after: separator)...]), index >= 0
    else { return nil }
    return (memoID, index)
  }

  /// The production inspector: the file opens as audio and holds frames.
  public static let inspectAudioFile: SegmentInspector = { url in
    #if canImport(AVFAudio)
      guard let file = try? AVAudioFile(forReading: url), file.length > 0,
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
      else { return nil }
      return (size, Double(file.length) / file.processingFormat.sampleRate)
    #else
      return nil
    #endif
  }
}
