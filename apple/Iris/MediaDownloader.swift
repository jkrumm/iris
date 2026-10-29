import Foundation

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
    if request.isReusable, FileManager.default.fileExists(atPath: destination.path) { return destination }
    let session = session
    let directory = directory
    return try await flights.join("\(request.url.absoluteString)|\(name)") {
      try await Self.download(request, to: destination, in: directory, with: session)
    }
  }

  /// Removes the cached files of a memo that was deleted or purged: its recording, its spoken reply and the images of
  /// its reply (all named `<memo id>.…`). A memo with nothing cached is a no-op.
  func evict(memoID: String) {
    let prefix = Self.safeName(memoID) + "."
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(prefix) {
      try? FileManager.default.removeItem(at: directory.appending(path: name))
    }
  }

  private static func download(
    _ request: MediaRequest, to destination: URL, in directory: URL, with session: URLSession
  ) async throws -> URL {
    var urlRequest = URLRequest(url: request.url)
    for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
    let (temporary, response) = try await session.download(for: urlRequest)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let http = response as? HTTPURLResponse else { throw MediaDownloadError.notHTTP }
    guard (200..<300).contains(http.statusCode) else { throw MediaDownloadError.status(http.statusCode) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: temporary, to: destination)
    return destination
  }

  /// A cache name never leaves the cache directory, whatever the memo id holds.
  private static func safeName(_ name: String) -> String {
    name.replacingOccurrences(of: "/", with: "_")
  }

  /// The downloads on the wire, by request. The download itself is an unstructured task of its own: a caller that is
  /// cancelled stops waiting for it at its next suspension, but the file still lands for the others that joined.
  private actor Flights {
    private var running: [String: Task<URL, any Error>] = [:]

    func join(_ key: String, start: @escaping @Sendable () async throws -> URL) async throws -> URL {
      if let task = running[key] { return try await task.value }
      let task = Task { try await start() }
      running[key] = task
      defer { if running[key] == task { running[key] = nil } }
      return try await task.value
    }
  }
}
