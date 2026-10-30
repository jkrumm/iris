import CryptoKit
import Foundation

/// The server closed a memo without this segment (`409 bad_state`, and its segment count does not cover the index): the take's
/// tail reached it after the memo had completed. The file is the only copy of that audio, so the outbox does not drop it and
/// does not re-open the memo (that could act twice); it makes the audio a memo of its own, mode `transcribe` (see
/// ``Outbox``). Thrown by a ``SegmentUploader`` from `upload(_:)`.
public struct LateSegmentError: Error, Sendable, Equatable {
  /// Starts the new memo's queue title ("Late recording"), localized by the app; the take it belongs to follows it.
  public let label: String
  /// What the server said, for the log.
  public let answer: String
  /// How many segments the server completed the take's memo with. The take's own `complete` goes out with this count, not
  /// the local one: the server would refuse a larger count (409 `conflict`) and the take would stall for a segment that
  /// now lives in a memo of its own.
  public let serverSegmentCount: Int

  public init(label: String, answer: String, serverSegmentCount: Int) {
    self.label = label
    self.answer = answer
    self.serverSegmentCount = serverSegmentCount
  }
}

enum LateTail {
  /// The `MemoMode` raw value of the memo a late tail becomes: transcript only, nothing is routed or acted on.
  static let mode = "transcribe"

  /// The id of the memo that takes `memoID`'s segment `index`: derived, so a replay (the answer was lost, the app was killed
  /// between queueing the memo and marking the segment) finds the memo it already made instead of making a second one.
  static func memoID(of memoID: MemoID, index: Int) -> MemoID {
    var bytes = Array(SHA256.hash(data: Data("late-tail/\(memoID.uuidString)/\(index)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10],
        bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  /// The row's title: the label and the take it belongs to, with the first block of its memo id so two takes read apart.
  static func title(label: String, original: OutboxItem?, memoID: MemoID) -> String {
    let take = original?.title ?? "Voice memo"
    return "\(label) · \(take) \(memoID.uuidString.prefix(8).lowercased())"
  }

  /// The file operations `link` uses, injectable so a test can make a copy fail half way.
  struct FileOperations {
    var link: (URL, URL) throws -> Void = { try FileManager.default.linkItem(at: $0, to: $1) }
    var copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    var size: (URL) -> Int? = { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? nil }
    var remove: (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
    var rename: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
  }

  /// A second name for the file next to it, in the recorder's naming (`<memo id>-<index>.m4a`), so the startup sweep and the
  /// store's relative paths treat it like any segment. A hard link: the audio stays on disk until both names are gone, so
  /// the original take retiring its file cannot take the late tail with it. Where linking is not possible, a copy: written
  /// under a temporary name (not `.m4a`, so no sweep or queue picks it up) and renamed into place, so a copy that was cut
  /// off leaves no file under the real name. An existing target is reused only when it is as large as the source; anything
  /// else is a leftover of an interrupted run and is made again.
  static func link(_ file: URL, as target: URL, using files: FileOperations = FileOperations()) throws {
    let expected = files.size(file)
    if FileManager.default.fileExists(atPath: target.path) {
      if let expected, files.size(target) == expected { return }
      files.remove(target)
    }
    do {
      try files.link(file, target)
    } catch {
      let partial = target.appendingPathExtension("partial")
      files.remove(partial)
      do {
        try files.copy(file, partial)
        guard files.size(partial) == expected else { throw CocoaError(.fileWriteUnknown) }
        try files.rename(partial, target)
      } catch {
        files.remove(partial)
        throw error
      }
    }
  }
}
