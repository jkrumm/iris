import Foundation
import Synchronization

@testable import IrisCore

struct RecordedRequest: Sendable {
  var method: String
  var url: URL
  var headers: [String: String]
  var body: Data

  func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  var queryItems: [URLQueryItem] {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
  }
}

struct StubResponse: Sendable {
  var status: Int
  var headers: [String: String] = [:]
  /// Delivered one after another, so a body can arrive in pieces.
  var chunks: [Data] = []

  static func json(_ status: Int = 200, fixture name: String) throws -> StubResponse {
    StubResponse(
      status: status, headers: ["Content-Type": "application/json"], chunks: [try Contracts.fixtureData(name)])
  }

  static func text(_ status: Int, _ body: String) -> StubResponse {
    StubResponse(status: status, headers: ["Content-Type": "text/plain"], chunks: [Data(body.utf8)])
  }

  static func empty(_ status: Int) -> StubResponse {
    StubResponse(status: status)
  }
}

/// A fake server for one test. Its host name is unique, so tests running in parallel never share a stub.
final class StubServer: Sendable {
  typealias Handler = @Sendable (RecordedRequest) throws -> StubResponse

  // The registry is read from URLProtocol's loading thread; `Mutex` is the whole synchronization story.
  private static let registry = Mutex<[String: StubServer]>([:])

  let host = "\(UUID().uuidString.lowercased()).iris.example.com"
  private let handler: Handler
  private let recorded = Mutex<[RecordedRequest]>([])

  init(_ handler: @escaping Handler) {
    self.handler = handler
    Self.registry.withLock { $0[host] = self }
  }

  deinit {
    Self.registry.withLock { _ = $0.removeValue(forKey: host) }
  }

  var requests: [RecordedRequest] { recorded.withLock { $0 } }

  /// The only request the test made.
  var request: RecordedRequest? { requests.count == 1 ? requests.first : nil }

  func baseURL(path: String = "") -> URL {
    URL(string: "https://\(host)\(path)") ?? URL(filePath: "/")
  }

  func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  func makeClient(bearer: String = "test-token", path: String = "") -> URLSessionAPIClient {
    URLSessionAPIClient(baseURL: baseURL(path: path), bearerToken: bearer, session: makeSession())
  }

  static func server(for host: String?) -> StubServer? {
    guard let host else { return nil }
    return registry.withLock { $0[host] }
  }

  func handle(_ request: RecordedRequest) throws -> StubResponse {
    recorded.withLock { $0.append(request) }
    return try handler(request)
  }
}

final class StubURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    guard let url = request.url, let server = StubServer.server(for: url.host) else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    let recorded = RecordedRequest(
      method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: readBody())
    do {
      let stub = try server.handle(recorded)
      guard
        let response = HTTPURLResponse(
          url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
      else { throw URLError(.badServerResponse) }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      for chunk in stub.chunks { client?.urlProtocol(self, didLoad: chunk) }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  /// URLSession hands a request body to the protocol as a stream.
  private func readBody() -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
