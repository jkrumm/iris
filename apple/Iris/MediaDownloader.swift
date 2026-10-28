import Foundation

nonisolated enum MediaDownloadError: Error, Equatable {
  case status(Int)
  case notHTTP
}

/// Turns a ``MediaRequest`` into a file the player can open. AVFoundation has no documented way to attach headers to
/// an `AVURLAsset`, so the authenticated request is made here with `URLSession` and the player is given the file
/// (TDD §4 "Authenticated media"). A file URL passes through untouched.
nonisolated struct MediaDownloader: Sendable {
  let session: URLSession
  let directory: URL

  init(
    session: URLSession = URLSession(configuration: .ephemeral),
    directory: URL = URL.cachesDirectory.appending(path: "iris-media")
  ) {
    self.session = session
    self.directory = directory
  }

  func localURL(for request: MediaRequest) async throws -> URL {
    if request.url.isFileURL { return request.url }
    let name = Self.safeName(request.cacheName ?? UUID().uuidString)
    let destination = directory.appending(path: name)
    if request.isReusable, FileManager.default.fileExists(atPath: destination.path) { return destination }

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
}
