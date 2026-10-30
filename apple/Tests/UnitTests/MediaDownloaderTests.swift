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
  private static let delays = Mutex<[String: Double]>([:])
  private static let seen = Mutex<[String: [[String: String]]]>([:])

  static func serve(host: String, _ reply: Reply, delay: Double = 0) {
    replies.withLock { $0[host] = reply }
    delays.withLock { $0[host] = delay }
  }
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
    let delay = Self.delays.withLock { $0[host] ?? 0 }
    // The protocol object is not Sendable; the delivery happens on the thread URLSession gave it.
    nonisolated(unsafe) let this = self
    let deliver = {
      this.client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
      this.client?.urlProtocol(this, didLoad: reply.body)
      this.client?.urlProtocolDidFinishLoading(this)
    }
    if delay > 0 {
      DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
    } else {
      deliver()
    }
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

  @Test("the launch sweep removes files nobody touched for the age and keeps newer ones")
  func staleSweep() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let old = directory.appending(path: "gone.speech.mp3")
    let fresh = directory.appending(path: "kept.audio.m4a")
    for url in [old, fresh] { try Data("x".utf8).write(to: url) }
    let now = Date()
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-15 * 24 * 3600)], ofItemAtPath: old.path)
    await downloader().sweepStaleAndWait(olderThan: 14 * 24 * 3600, now: now)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
  }

  @Test("a cache hit counts as use: the sweep right after it keeps the file")
  func hitSurvivesTheSweep() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    MediaStub.serve(host: host, .init(status: 200, body: Data("one".utf8)))
    let downloader = downloader()
    let kept = try request(reusable: true)
    let file = try await downloader.localURL(for: kept)
    let now = Date()
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-30 * 24 * 3600)], ofItemAtPath: file.path)
    _ = try await downloader.localURL(for: kept)
    await downloader.sweepStaleAndWait(olderThan: 14 * 24 * 3600, now: now)
    #expect(FileManager.default.fileExists(atPath: file.path))
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

  @Test("two asks for the same file while it downloads are one request")
  func singleFlight() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    MediaStub.serve(host: host, .init(status: 200, body: Data("audio".utf8)), delay: 0.4)
    let downloader = downloader()
    let wanted = try request(reusable: false)
    async let first = downloader.localURL(for: wanted)
    async let second = downloader.localURL(for: wanted)
    let files = try await [first, second]
    #expect(files[0] == files[1])
    #expect(MediaStub.requests(host: host).count == 1)

    // Finished flights are forgotten: a later ask for a file that is not kept fetches it again.
    _ = try await downloader.localURL(for: wanted)
    #expect(MediaStub.requests(host: host).count == 2)
  }

  @Test("a failed download is not remembered: the next ask tries again")
  func failureIsNotCached() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let downloader = downloader()
    MediaStub.serve(host: host, .init(status: 503, body: Data()))
    await #expect(throws: MediaDownloadError.status(503)) {
      try await downloader.localURL(for: request(reusable: true))
    }
    MediaStub.serve(host: host, .init(status: 200, body: Data("ok".utf8)))
    let file = try await downloader.localURL(for: request(reusable: true))
    #expect(try Data(contentsOf: file) == Data("ok".utf8))
  }

  @Test("evicting a memo removes its recording, speech and images, and only its own")
  func evict() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    MediaStub.serve(host: host, .init(status: 200, body: Data("x".utf8)))
    let downloader = downloader()
    let names = ["m1.audio.m4a", "m1.speech.mp3", "m1.light.png", "m10.audio.m4a", "m2.audio.m4a"]
    for name in names { _ = try await downloader.localURL(for: request(reusable: true, name: name)) }

    await downloader.evictAndWait(memoID: "m1")
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(left == ["m10.audio.m4a", "m2.audio.m4a"])

    await downloader.evictAndWait(memoID: "never-cached")
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
  }

  @Test("a download still on the wire when its memo is evicted never lands")
  func evictionDuringDownload() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    MediaStub.serve(host: host, .init(status: 200, body: Data("audio".utf8)), delay: 0.6)
    let downloader = downloader()
    let wanted = try request(reusable: true)
    let download = Task { try await downloader.localURL(for: wanted) }
    while MediaStub.requests(host: host).isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    await downloader.evictAndWait(memoID: "m1")
    await #expect(throws: (any Error).self) { try await download.value }
    try await Task.sleep(for: .milliseconds(800))
    let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    #expect(left.isEmpty)

    // The memo can be downloaded again afterwards (an Undo).
    MediaStub.serve(host: host, .init(status: 200, body: Data("again".utf8)))
    let file = try await downloader.localURL(for: wanted)
    #expect(try Data(contentsOf: file) == Data("again".utf8))
  }
}
