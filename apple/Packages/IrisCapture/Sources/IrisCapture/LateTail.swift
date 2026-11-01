import CryptoKit
import Foundation

/// A segment's memo is closed on the server without it (the uploader's 409 `bad_state`, and the server holds fewer segments
/// than this index). The outbox answers by making the segment its own transcribe memo (`LateTail`) instead of stalling.
public struct LateTailError: Error, Sendable, Equatable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }
}

/// A late tail: the end of a take (one or more segments) that reaches the outbox after the server closed the take's memo, so
/// the memo can no longer take it. It becomes **its own `transcribe` memo**, client only: a fresh memo id, mode `transcribe`
/// (the transcript, never a route or an act, so it cannot double-act), one segment, the normal create → upload → complete path.
/// One memo per segment; `OutboxItem.tailOf` names the take for the queue row.
///
/// - **Idempotent:** the id is derived from the take's id and the segment index (UUIDv5), so a replay lands on the same memo;
///   `Outbox` queues a derived id once, and never again after it completed or was discarded.
/// - **No audio is lost:** the tail's file gets a second name in the same directory (a hard link, `<tail id>-0.m4a`) before
///   anything is saved; the take's own name goes away with the take's files, the tail's name when the tail memo is delivered.
///   A crash before the save leaves the take's entry as it was (it is diverted again after the relaunch) and the second name
///   for the startup sweep to set aside; nothing is deleted on a guess.
enum LateTail {
  /// Fixed, random once: the namespace of the derived ids (6f1c1c0e-3d0b-5a52-9e0a-1f2b7a3c9d41).
  private static let namespace = UUID(
    uuid: (0x6f, 0x1c, 0x1c, 0x0e, 0x3d, 0x0b, 0x5a, 0x52, 0x9e, 0x0a, 0x1f, 0x2b, 0x7a, 0x3c, 0x9d, 0x41))

  /// UUIDv5 of the take's id and the segment index.
  static func memoID(of take: MemoID, index: Int) -> MemoID {
    let name = "\(take.uuidString.lowercased())/\(index)"
    let input = withUnsafeBytes(of: namespace.uuid) { Data($0) } + Data(name.utf8)
    var b = Array(Insecure.SHA1.hash(data: input).prefix(16))
    b[6] = (b[6] & 0x0F) | 0x50
    b[8] = (b[8] & 0x3F) | 0x80
    return UUID(
      uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
  }

  /// The queue item of the tail: bound to the take's server, named after the take.
  static func item(after take: OutboxItem?, segment: ClosedSegment, now: Date) -> OutboxItem {
    let title = take.map { String(localized: "End of \($0.title)") } ?? String(localized: "End of a take")
    var item = OutboxItem(
      memoID: memoID(of: segment.memoID, index: segment.index), kind: .voice, mode: "transcribe",
      startedAt: take?.startedAt ?? now, queuedAt: now, title: title, serverKey: take?.serverKey)
    item.tailOf = segment.memoID
    return item
  }

  /// The segment under the tail's own file name; `nil` when that name cannot be made (the take's file stays as it is).
  static func link(_ segment: ClosedSegment, as memoID: MemoID) -> ClosedSegment? {
    let target = segment.fileURL.deletingLastPathComponent().appending(path: "\(memoID.uuidString)-0.m4a")
    let files = FileManager.default
    if files.fileExists(atPath: target.path) {
      // A name left by a diversion that was not saved: the same bytes, or not ours to reuse.
      guard (try? files.attributesOfItem(atPath: target.path)[.size] as? Int) == segment.byteCount else { return nil }
    } else {
      do { try files.linkItem(at: segment.fileURL, to: target) } catch {
        Log.outbox.error("late tail not linked: \(String(describing: error), privacy: .public)")
        return nil
      }
    }
    return ClosedSegment(
      memoID: memoID, index: 0, fileURL: target, byteCount: segment.byteCount, duration: segment.duration)
  }
}
