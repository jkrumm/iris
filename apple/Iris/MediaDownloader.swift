import Foundation
import Synchronization

nonisolated enum MediaDownloadError: Error, Equatable {
  case status(Int)
  case notHTTP
}

/// Turns a ``MediaRequest`` into a file the player can open. AVFoundation has no documented way to attach headers to
/// an `AVURLAsset`, so the authenticated request is made here with `URLSession` and the player is given the file
/// (TDD §4 "Authenticated media"). A file URL passes through untouched.
///
/// A download is single-flight per request: a second ask for the same URL and cache name while the first is on the wire
/// joins it, so two players, or a player and a diagram, never fetch the same file twice. The app has one downloader
/// (``shared``), so one `URLSession` and one set of flights serve every player and image.
nonisolated struct MediaDownloader: Sendable {
  /// The downloader of the app: every player and the reply images go through it.
  static let shared = MediaDownloader()

  let session: URLSession
  let directory: URL
  private let flights = Flights()
  private let evictions = Evictions()

  init(
    session: URLSession = MediaDownloader.makeSession(),
    directory: URL = URL.cachesDirectory.appending(path: "iris-media")
  ) {
    self.session = session
    self.directory = directory
  }

  /// An ephemeral session whose whole transfer is bounded. The default allows a week, and a request that hangs would hold
  /// its single-flight entry, and one of the image store's load slots, until the process ends.
  static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 300
    return URLSession(configuration: configuration)
  }

  func localURL(for request: MediaRequest) async throws -> URL {
    if request.url.isFileURL { return request.url }
    let name = Self.safeName(request.cacheName ?? UUID().uuidString)
    let destination = directory.appending(path: name)
    // The cache check runs on the flights' actor, the same one eviction runs on, so a file is either seen before an
    // eviction that was asked for earlier removes it, or not at all.
    // A memo whose eviction was asked for (and has not run yet) has no cache hit: the ask is answered by the download.
    if request.isReusable, !evictions.isPending(name), await flights.useFile(at: destination) { return destination }
    let session = session
    let directory = directory
    let flights = flights
    let key = "\(request.url.absoluteString)|\(name)"
    return try await flights.join(key, name: name) { flight in
      try await Self.download(
        request, to: destination, in: directory, with: session,
        land: { try await flights.land($0, as: destination, flight: flight, key: key) })
    }
  }

  /// Removes the cached files of a memo that was deleted or purged: its recording, its spoken reply and the images of
  /// its reply (all named `<memo id>.…`), and cancels the downloads of those files still on the wire, so none lands
  /// afterwards. The scan runs on the flights' actor, never on the caller's (History's, the main actor's); the call
  /// returns at once. A memo with nothing cached is a no-op.
  func evict(memoID: String) {
    let flights = flights
    let directory = directory
    let prefix = Self.safeName(memoID) + "."
    let evictions = evictions
    evictions.begin(prefix)
    Task {
      await flights.evict(prefix: prefix, in: directory)
      evictions.end(prefix)
    }
  }

  /// Removes cached files nobody has touched for `age` seconds: spoken replies that were played (not reusable, so kept only
  /// by accident), recordings and images of memos deleted on another device or while the app was killed. Runs once at
  /// launch; the scan is off the caller's actor and the call returns at once. A removed file is simply downloaded again.
  func sweepStale(olderThan age: TimeInterval = 14 * 24 * 3600, now: Date = Date()) {
    let flights = flights
    let directory = directory
    Task { await flights.sweep(in: directory, notModifiedSince: now.addingTimeInterval(-age)) }
  }

  /// ``sweepStale(olderThan:now:)``, returning once the files are gone.
  func sweepStaleAndWait(olderThan age: TimeInterval, now: Date = Date()) async {
    await flights.sweep(in: directory, notModifiedSince: now.addingTimeInterval(-age))
  }

  /// ``evict(memoID:)``, returning once the files are gone.
  func evictAndWait(memoID: String) async {
    let prefix = Self.safeName(memoID) + "."
    evictions.begin(prefix)
    await flights.evict(prefix: prefix, in: directory)
    evictions.end(prefix)
  }

  private static func download(
    _ request: MediaRequest, to destination: URL, in directory: URL, with session: URLSession,
    land: (URL) async throws -> Void
  ) async throws -> URL {
    var urlRequest = URLRequest(url: request.url)
    for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
    let (temporary, response) = try await session.download(for: urlRequest)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let http = response as? HTTPURLResponse else { throw MediaDownloadError.notHTTP }
    guard (200..<300).contains(http.statusCode) else { throw MediaDownloadError.status(http.statusCode) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try await land(temporary)
    return destination
  }

  /// A cache name never leaves the cache directory, whatever the memo id holds.
  private static func safeName(_ name: String) -> String {
    name.replacingOccurrences(of: "/", with: "_")
  }

  /// The evictions asked for and not yet run. ``evict(memoID:)`` returns before its scan, so this is what makes an ask that
  /// comes after it miss the cache instead of being handed a file that is about to go.
  private final class Evictions: Sendable {
    private let pending = Mutex<[String: Int]>([:])

    func begin(_ prefix: String) { pending.withLock { $0[prefix, default: 0] += 1 } }

    func end(_ prefix: String) {
      pending.withLock {
        let left = ($0[prefix] ?? 1) - 1
        $0[prefix] = left > 0 ? left : nil
      }
    }

    func isPending(_ name: String) -> Bool {
      pending.withLock { $0.keys.contains { name.hasPrefix($0) } }
    }
  }

  /// The downloads on the wire, by request. The download itself is an unstructured task of its own: a caller that is
  /// cancelled stops waiting for it at its next suspension, but the file still lands for the others that joined.
  /// Only the actor moves a finished file into the cache, and eviction runs here too, so a download either lands before
  /// an eviction (which then removes it) or finds itself evicted and discards its file.
  private actor Flights {
    private struct Flight {
      let id: UUID
      let name: String
      let task: Task<URL, any Error>
    }
    private var running: [String: Flight] = [:]

    func join(_ key: String, name: String, start: @escaping @Sendable (UUID) async throws -> URL) async throws -> URL {
      if let flight = running[key] { return try await flight.task.value }
      let id = UUID()
      let task = Task { try await start(id) }
      running[key] = Flight(id: id, name: name, task: task)
      defer { if running[key]?.id == id { running[key] = nil } }
      return try await task.value
    }

    /// Whether the cached file exists; a hit marks it as just used, so the launch sweep (which drops files by age) cannot
    /// remove it between this answer and the player opening it.
    func useFile(at url: URL) -> Bool {
      guard FileManager.default.fileExists(atPath: url.path) else { return false }
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
      return true
    }

    /// Removes files last modified before `cutoff`, except those a download on the wire is about to replace.
    func sweep(in directory: URL, notModifiedSince cutoff: Date) {
      let busy = Set(running.values.map(\.name))
      let urls =
        (try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      for url in urls where !busy.contains(url.lastPathComponent) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified < cutoff { try? FileManager.default.removeItem(at: url) }
      }
    }

    /// Moves a finished download into the cache, unless its flight was evicted meanwhile.
    func land(_ temporary: URL, as destination: URL, flight: UUID, key: String) throws {
      guard running[key]?.id == flight else { throw CancellationError() }
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func evict(prefix: String, in directory: URL) {
      for (key, flight) in running where flight.name.hasPrefix(prefix) {
        flight.task.cancel()
        running[key] = nil
      }
      let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      for name in names where name.hasPrefix(prefix) {
        try? FileManager.default.removeItem(at: directory.appending(path: name))
      }
    }
  }
}
