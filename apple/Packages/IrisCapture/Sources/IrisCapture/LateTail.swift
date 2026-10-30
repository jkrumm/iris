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

  public init(label: String, answer: String) {
    self.label = label
    self.answer = answer
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

  /// A second name for the file next to it, in the recorder's naming (`<memo id>-<index>.m4a`), so the startup sweep and the
  /// store's relative paths treat it like any segment. A hard link: the audio stays on disk until both names are gone, so
  /// the original take retiring its file cannot take the late tail with it. A copy where linking is not possible.
  static func link(_ file: URL, as target: URL) throws {
    if FileManager.default.fileExists(atPath: target.path) { return }
    do {
      try FileManager.default.linkItem(at: file, to: target)
    } catch {
      try FileManager.default.copyItem(at: file, to: target)
    }
  }
}
