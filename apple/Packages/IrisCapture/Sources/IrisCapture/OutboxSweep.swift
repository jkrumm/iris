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

  public var isEmpty: Bool { adopted.isEmpty && quarantined.isEmpty && kept.isEmpty }
}

/// Reads a segment file back: its size and length, or `nil` when it is not a complete audio file (a take the app died in the
/// middle of leaves an AAC file without its trailer).
public typealias SegmentInspector = @Sendable (URL) -> (byteCount: Int, duration: TimeInterval)?

extension Outbox {
  /// The sweep that runs once at launch, after the queue is loaded and before anything is sent or recorded: a segment file
  /// is written before the queue file that names it is saved, so a crash or a failed save leaves files no record owns.
  ///
  /// Each file in `directory` that the queue does not know is either **adopted** (it belongs to a take the queue holds and is
  /// a complete audio file that fills one of its indices) or **moved** into `quarantineDirectory`. **Nothing is deleted.** A
  /// file that a quarantined queue file names stays where it is, so that queue can still be read back against its files.
  @discardableResult
  public func sweepOrphans(
    in directory: URL, quarantineTo quarantineDirectory: URL, inspect: SegmentInspector = Outbox.inspectAudioFile
  ) async -> SweepReport {
    var report = SweepReport()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    let owned = Set(machine.entries.values.map(\.segment.fileURL.lastPathComponent))
      .union(obsoleteFiles.map(\.url.lastPathComponent))
    // By take and index, so a take that grows is adopted in order.
    let candidates = names.filter { $0.hasSuffix(".m4a") && !owned.contains($0) }.sorted {
      guard let left = Self.parse($0), let right = Self.parse($1) else { return $0 < $1 }
      return (left.0.uuidString, left.1) < (right.0.uuidString, right.1)
    }
    guard !candidates.isEmpty else { return report }
    let heldQueues = await store.quarantined().compactMap { try? Data(contentsOf: $0) }

    for name in candidates {
      let url = directory.appending(path: name)
      var isFile = ObjCBool(false)
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFile), !isFile.boolValue else { continue }
      if heldQueues.contains(where: { $0.range(of: Data(name.utf8)) != nil }) {
        report.kept.append(url)
      } else if adopt(url, name: name, inspect: inspect) {
        report.adopted.append(url)
      } else if let moved = Self.quarantine(url, into: quarantineDirectory) {
        report.quarantined.append(moved)
      }
    }
    // Saved before anything goes up, as for any new segment (`persist()` releases the withheld ones).
    if !report.adopted.isEmpty { await persist() }
    if !report.isEmpty {
      Log.outbox.notice(
        "capture sweep: \(report.adopted.count) adopted, \(report.quarantined.count) quarantined, \(report.kept.count) kept"
      )
    }
    return report
  }

  /// `<memo id>-<index>.m4a` that belongs to a take the queue holds (`OutboxStateMachine.adopt`) and plays.
  private func adopt(_ url: URL, name: String, inspect: SegmentInspector) -> Bool {
    guard let (memoID, index) = Self.parse(name), let audio = inspect(url), audio.byteCount > 0 else { return false }
    let segment = ClosedSegment(
      memoID: memoID, index: index, fileURL: url, byteCount: audio.byteCount, duration: audio.duration)
    guard machine.adopt(segment) else { return false }
    unsavedSegments[SegmentKey(memoID: memoID, index: index)] = requested + 1
    return true
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

  /// Moves the file into the quarantine folder under its own name, or a unique one when that is taken.
  private static func quarantine(_ url: URL, into directory: URL) -> URL? {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var target = directory.appending(path: url.lastPathComponent)
      if FileManager.default.fileExists(atPath: target.path) {
        let stem = url.deletingPathExtension().lastPathComponent
        target = directory.appending(path: "\(stem)-\(UUID().uuidString.prefix(8)).m4a")
      }
      try FileManager.default.moveItem(at: url, to: target)
      return target
    } catch {
      // Left where it is: the next launch sweeps it again.
      Log.outbox.error("segment file not quarantined: \(String(describing: error), privacy: .public)")
      return nil
    }
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
