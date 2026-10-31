import Foundation
import Synchronization

/// Where the snapshot lives between the app and the widget extension. A port: the App Group file in production, memory in
/// tests. Both calls are best effort and never throw: a widget that cannot read shows "Open Iris", an app that cannot
/// write loses a widget refresh and nothing else.
public protocol LastMemoSnapshotStoring: Sendable {
  /// `nil` when there is nothing readable: no container, no file, a file that does not decode.
  func load() -> LastMemoSnapshot?
  /// Replaces the snapshot, or removes it for `nil`. `false` when it could not be stored.
  @discardableResult func save(_ snapshot: LastMemoSnapshot?) -> Bool
}

/// The snapshot as one small JSON file in a directory both processes can reach (the App Group container).
///
/// Without the App Group entitlement (a Personal Team device build, the unsigned simulator build) the container URL is `nil`:
/// the store is then unavailable, ``load()`` is `nil` and ``save(_:)`` is a no-op returning `false`; nothing crashes and
/// the widget degrades to its static "Open Iris" state.
public struct FileLastMemoSnapshotStore: LastMemoSnapshotStoring {
  /// The App Group both targets' entitlements name (`apple/Iris/Iris.entitlements`, `apple/IrisWidgets/IrisWidgets.entitlements`).
  public static let appGroupIdentifier = "group.com.jkrumm.iris"
  static let fileName = "last-memo.json"

  private let directory: URL?

  public init(directory: URL?) {
    self.directory = directory
  }

  /// The App Group container, or an unavailable store when this build is not entitled to it.
  public static func appGroup(
    identifier: String = appGroupIdentifier, fileManager: FileManager = .default
  ) -> FileLastMemoSnapshotStore {
    FileLastMemoSnapshotStore(directory: fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier))
  }

  public var isAvailable: Bool { directory != nil }

  private var file: URL? { directory?.appending(path: Self.fileName, directoryHint: .notDirectory) }

  public func load() -> LastMemoSnapshot? {
    guard let file, let data = try? Data(contentsOf: file) else { return nil }
    return try? Self.decoder.decode(LastMemoSnapshot.self, from: data)
  }

  @discardableResult
  public func save(_ snapshot: LastMemoSnapshot?) -> Bool {
    guard let directory, let file else { return false }
    do {
      guard let snapshot else {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        return true
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Self.encoder.encode(snapshot).write(to: file, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

/// The in-memory adapter: the tests' store, and the previews'.
public final class InMemoryLastMemoSnapshotStore: LastMemoSnapshotStoring {
  private let state: Mutex<LastMemoSnapshot?>
  private let accepts: Bool

  /// `accepting: false` is a container that cannot be written to.
  public init(_ snapshot: LastMemoSnapshot? = nil, accepting: Bool = true) {
    state = Mutex(snapshot)
    accepts = accepting
  }

  public func load() -> LastMemoSnapshot? { state.withLock { $0 } }

  @discardableResult
  public func save(_ snapshot: LastMemoSnapshot?) -> Bool {
    guard accepts else { return false }
    state.withLock { $0 = snapshot }
    return true
  }
}
