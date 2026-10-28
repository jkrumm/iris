import Foundation
import Synchronization
import Testing

@testable import Iris

/// A fake media server for the downloader: answers by host, records the headers it saw.
private nonisolated final class MediaStub: URLProtocol {
  struct Reply: Sendable {
    var status: Int
    var body: Data
  }
  private static let replies = Mutex<[String: Reply]>([:])
  private static let seen = Mutex<[String: [[String: String]]]>([:])

  static func serve(host: String, _ reply: Reply) { replies.withLock { $0[host] = reply } }
  static func requests(host: String) -> [[String: String]] { seen.withLock { $0[host] ?? [] } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    guard let url = request.url, let host = url.host, let reply = Self.replies.withLock({ $0[host] }),
      let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    Self.seen.withLock { $0[host, default: []].append(request.allHTTPHeaderFields ?? [:]) }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.body)
    client?.urlProtocolDidFinishLoading(self)
  }
}

@Suite("MediaDownloader")
struct MediaDownloaderTests {
  private let directory = FileManager.default.temporaryDirectory.appending(path: "iris-dl-\(UUID().uuidString)")
  private let host = "\(UUID().uuidString.lowercased()).media.example.com"

  private func downloader() -> MediaDownloader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MediaStub.self]
    return MediaDownloader(session: URLSession(configuration: configuration), directory: directory)
  }

  private func request(reusable: Bool, name: String = "m1.audio.m4a") throws -> MediaRequest {
    MediaRequest(
      url: try #require(URL(string: "https://\(host)/v1/memos/m1/audio")),
      headers: ["Authorization": "Bearer secret"], cacheName: name, isReusable: reusable)
  }

  @Test("the download carries the bearer header and lands in the cache under its name")
  func authenticatedDownload() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    MediaStub.serve(host: host, .init(status: 200, body: Data("audio".utf8)))
    let file = try await downloader().localURL(for: request(reusable: false))
    #expect(file.lastPathComponent == "m1.audio.m4a" && file.deletingLastPathComponent().path == directory.path)
    #expect(try Data(contentsOf: file) == Data("audio".utf8))
    #expect(MediaStub.requests(host: host).first?["Authorization"] == "Bearer secret")
  }

  @Test("a reusable file is downloaded once; anything else is fetched again and replaced")
  func reuse() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let downloader = downloader()
    MediaStub.serve(host: host, .init(status: 200, body: Data("one".utf8)))
    let kept = try request(reusable: true)
    _ = try await downloader.localURL(for: kept)
    MediaStub.serve(host: host, .init(status: 200, body: Data("two".utf8)))
    let again = try await downloader.localURL(for: kept)
    #expect(try Data(contentsOf: again) == Data("one".utf8))
    #expect(MediaStub.requests(host: host).count == 1)

    let fresh = try request(reusable: false, name: "m1.speech.mp3")
    _ = try await downloader.localURL(for: fresh)
    MediaStub.serve(host: host, .init(status: 200, body: Data("three".utf8)))
    let replaced = try await downloader.localURL(for: fresh)
    #expect(try Data(contentsOf: replaced) == Data("three".utf8))
  }

  @Test("a non-2xx answer throws and leaves nothing behind; a file URL passes through")
  func failures() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    MediaStub.serve(host: host, .init(status: 401, body: Data("Unauthorized".utf8)))
    await #expect(throws: MediaDownloadError.status(401)) {
      try await downloader().localURL(for: request(reusable: true))
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "m1.audio.m4a").path))

    let local = URL(filePath: "/tmp/clip.wav")
    #expect(try await downloader().localURL(for: MediaRequest(url: local, headers: [:])) == local)
  }

  @Test("a cache name cannot climb out of the cache directory")
  func traversal() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    MediaStub.serve(host: host, .init(status: 200, body: Data("x".utf8)))
    let file = try await downloader().localURL(for: request(reusable: false, name: "../../escape.m4a"))
    #expect(file.deletingLastPathComponent().path == directory.path)
  }
}
