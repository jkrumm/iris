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
  /// Segments rebuilt from the PCM shadow a kill left (their `.m4a`, which then went on as any orphan: adopted or quarantined).
  public var recovered: [URL] = []
  /// Files the sweep could neither attach nor move, and shadows it could not read: still in the capture directory, tried again
  /// at the next launch. Settings lists them so they are not invisible.
  public var stuck: [URL] = []

  public var isEmpty: Bool {
    adopted.isEmpty && quarantined.isEmpty && kept.isEmpty && recovered.isEmpty && stuck.isEmpty
  }
}

/// What became of a PCM shadow (`SegmentShadow`) the sweep found.
public enum ShadowRecovery: Sendable, Equatable {
  /// Transcoded to this playable `.m4a`.
  case recovered(URL)
  /// The shadow holds no audio: nothing to lose, it can go.
  case empty
  /// Could not be read or transcoded: left where it is for the next launch.
  case failed
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
  /// The PCM shadows (`<memo>-<index>.caf`) directly in the capture directory.
  func shadowFiles() async -> [URL]
  /// Rebuilds the segment a shadow stands for as a playable `.m4a` beside it (replacing the truncated one a kill left).
  func recover(shadow: URL) async -> ShadowRecovery
  /// The length of a shadow in seconds, `nil` when it cannot be read.
  func shadowDuration(of shadow: URL) -> TimeInterval?
  /// Removes a shadow whose audio is safe elsewhere (a playable m4a of the same length, or provably none).
  func discard(shadow: URL) async
}

extension SegmentFileStore {
  public func shadowFiles() async -> [URL] { [] }
  public func recover(shadow: URL) async -> ShadowRecovery { .failed }
  public func shadowDuration(of shadow: URL) -> TimeInterval? { nil }
  public func discard(shadow: URL) async {}
}

/// Transcodes a shadow to its m4a.
public typealias ShadowTranscoder = @Sendable (URL) -> ShadowRecovery

/// Production store: a capture directory and a `quarantine/` folder next to its files.
public struct DirectorySegmentFiles: SegmentFileStore {
  private let directory: URL
  private let quarantineDirectory: URL
  private let inspector: SegmentInspector
  private let transcoder: ShadowTranscoder

  public init(
    directory: URL, quarantineDirectory: URL? = nil, inspect: @escaping SegmentInspector = Outbox.inspectAudioFile,
    transcode: @escaping ShadowTranscoder = Outbox.transcodeShadow
  ) {
    self.directory = directory
    self.quarantineDirectory = quarantineDirectory ?? directory.appending(path: "quarantine")
    inspector = inspect
    transcoder = transcode
  }

  public func segmentFiles() async -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".m4a") }.map { directory.appending(path: $0) }
  }

  public func inspect(_ url: URL) -> (byteCount: Int, duration: TimeInterval)? { inspector(url) }

  public func shadowFiles() async -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter(SegmentShadow.isShadow).map { directory.appending(path: $0) }
  }

  public func recover(shadow: URL) async -> ShadowRecovery { transcoder(shadow) }

  public func shadowDuration(of shadow: URL) -> TimeInterval? {
    #if canImport(AVFAudio)
      SegmentWriter.duration(of: shadow)
    #else
      nil
    #endif
  }

  public func discard(shadow: URL) async { try? FileManager.default.removeItem(at: shadow) }

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
    let shadows = await files.shadowFiles().sorted { $0.lastPathComponent < $1.lastPathComponent }
    var candidates = await orphans(in: files, excluding: owned)
    guard !shadows.isEmpty || !candidates.isEmpty else { return await concluded(report) }
    // Who owns what is settled before anything is replaced or moved: a set-aside queue may name any of these files.
    let held = await HeldQueues.load(from: await setAsideQueueFiles())
    if !shadows.isEmpty {
      await recoverShadows(shadows, using: files, owned: owned, held: held, into: &report)
      candidates = await orphans(in: files, excluding: owned)  // recovered m4a files are orphans like any other
    }
    for url in candidates {
      let name = url.lastPathComponent
      var isFile = ObjCBool(false)
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFile), !isFile.boolValue else { continue }
      if held.mayName(name) {
        // A queue that was set aside may name this file (or cannot be checked): it stays where it is.
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
    return await concluded(report)
  }

  /// The segment files in the capture directory that the queue does not know, by take and index so a take that grows is
  /// adopted in order.
  private func orphans(in files: any SegmentFileStore, excluding owned: Set<String>) async -> [URL] {
    await files.segmentFiles().filter { !owned.contains($0.lastPathComponent) }.sorted {
      guard let left = Self.parse($0.lastPathComponent), let right = Self.parse($1.lastPathComponent) else {
        return $0.lastPathComponent < $1.lastPathComponent
      }
      return (left.0.uuidString, left.1) < (right.0.uuidString, right.1)
    }
  }

  /// Logs the sweep and remembers the files it could not deal with, for Settings.
  private func concluded(_ report: SweepReport) async -> SweepReport {
    noteStrays(report.stuck)
    // A take with no segment is dropped unless a file the sweep could not deal with may still hold its audio.
    let unresolved = Set((report.stuck + report.kept).compactMap { Self.parse($0.lastPathComponent)?.0 })
    await settleEmptyTakes(keeping: unresolved)
    guard !report.isEmpty else { return report }
    Log.outbox.notice(
      "capture sweep: \(report.adopted.count) adopted, \(report.quarantined.count) quarantined, \(report.kept.count) kept, \(report.recovered.count) recovered, \(report.stuck.count) stuck"
    )
    return report
  }

  /// A kill leaves the open segment's m4a without its index and the PCM shadow beside it whole. A shadow whose m4a is
  /// complete (the queue holds it, or it plays) is redundant and goes; otherwise it is transcoded to the m4a, which from then
  /// on is an orphan like any other (adopted by its take, or quarantined). The shadow goes as soon as that m4a plays: a kill
  /// right after leaves a playable orphan, never a loss.
  private func recoverShadows(
    _ shadows: [URL], using files: any SegmentFileStore, owned: Set<String>, held: HeldQueues,
    into report: inout SweepReport
  ) async {
    for shadow in shadows {
      let segment = SegmentShadow.segment(of: shadow)
      if let audio = files.inspect(segment) {
        // Redundant only when the m4a is shown to hold the shadow's audio: the same length, not just a file that plays.
        if let length = files.shadowDuration(of: shadow),
          abs(length - audio.duration) <= SegmentShadow.durationTolerance
        {
          await files.discard(shadow: shadow)
        } else {
          report.stuck.append(shadow)
        }
      } else if owned.contains(segment.lastPathComponent) {
        report.stuck.append(shadow)  // the queue's own file does not play: the shadow is the other copy
      } else if held.mayName(segment.lastPathComponent) {
        // Recovering would replace a file a set-aside queue still points at: neither file is touched.
        report.kept.append(shadow)
      } else {
        switch await files.recover(shadow: shadow) {
        case .recovered(let url):
          await files.discard(shadow: shadow)
          report.recovered.append(url)
        case .empty: await files.discard(shadow: shadow)
        case .failed: report.stuck.append(shadow)
        }
      }
    }
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

  /// The production transcoder: the shadow read back and encoded as the recorder's AAC.
  public static let transcodeShadow: ShadowTranscoder = { shadow in
    #if canImport(AVFAudio)
      return SegmentWriter.recover(shadow: shadow, sampleRate: SegmentRotationPolicy().sampleRate)
    #else
      return .failed
    #endif
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

/// The queue files earlier resets set aside, read once per sweep: what they name is not the sweep's to replace or move.
struct HeldQueues {
  private var contents: [Data] = []
  private var unreadable: [String] = []

  static func load(from files: [URL]) async -> HeldQueues {
    var held = HeldQueues()
    for file in files {
      do {
        held.contents.append(try Data(contentsOf: file))
      } catch {
        held.unreadable.append(file.lastPathComponent)
        Log.outbox.error(
          "set-aside queue \(file.lastPathComponent, privacy: .public) cannot be read: \(String(describing: error), privacy: .public)"
        )
      }
    }
    return held
  }

  /// A queue that cannot be read may name anything.
  func mayName(_ fileName: String) -> Bool {
    !unreadable.isEmpty || contents.contains { $0.range(of: Data(fileName.utf8)) != nil }
  }
}
