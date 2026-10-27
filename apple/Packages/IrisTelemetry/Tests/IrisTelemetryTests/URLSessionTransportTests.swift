import Foundation
import Synchronization
import Testing

@testable import IrisTelemetry

struct CapturedRequest: Sendable {
  let method: String?
  let path: String
  let headers: [String: String]
  let body: Data
}

/// Intercepts requests per host so parallel tests do not see each other's traffic. The registry is test-only shared
/// state behind a `Mutex` because `URLProtocol` callbacks are synchronous and non-isolated.
final class StubURLProtocol: URLProtocol {
  private struct Stub {
    var statusCode: Int
    var requests: [CapturedRequest] = []
  }

  private static let stubs = Mutex<[String: Stub]>([:])

  static func register(host: String, statusCode: Int) {
    stubs.withLock { $0[host] = Stub(statusCode: statusCode) }
  }

  static func requests(host: String) -> [CapturedRequest] {
    stubs.withLock { $0[host]?.requests ?? [] }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let host = url.host else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let captured = CapturedRequest(
      method: request.httpMethod,
      path: url.path,
      headers: request.allHTTPHeaderFields ?? [:],
      body: Self.body(of: request)
    )
    let statusCode = Self.stubs.withLock { stubs -> Int? in
      stubs[host]?.requests.append(captured)
      return stubs[host]?.statusCode
    }
    guard let statusCode,
      let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func body(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

struct URLSessionTransportTests {
  private func makeTransport(
    host: String,
    statusCode: Int,
    path: String = ""
  ) throws -> URLSessionTelemetryTransport {
    StubURLProtocol.register(host: host, statusCode: statusCode)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let baseURL = try #require(URL(string: "https://\(host)\(path)"))
    return URLSessionTelemetryTransport(
      baseURL: baseURL,
      bearerToken: "test-token",
      session: URLSession(configuration: configuration)
    )
  }

  private func uniqueHost() -> String { "\(UUID().uuidString.lowercased()).stub.example.com" }

  @Test func postsTheBatchJSONWithBearerToken() async throws {
    let host = uniqueHost()
    let transport = try makeTransport(host: host, statusCode: 202)
    let batch = TelemetryBatch(
      resource: Fixtures.resource, spans: [Fixtures.span(1)], logs: [Fixtures.log(2)], dropped: 1)

    try await transport.send(batch)

    let request = try #require(StubURLProtocol.requests(host: host).first)
    #expect(request.method == "POST")
    #expect(request.path == "/v1/telemetry")
    #expect(request.headers["Authorization"] == "Bearer test-token")
    #expect(request.headers["Content-Type"] == "application/json")
    #expect(request.body == (try batch.jsonData()))
  }

  @Test func keepsABaseURLPathPrefix() async throws {
    let host = uniqueHost()
    let transport = try makeTransport(host: host, statusCode: 200, path: "/api")
    try await transport.send(TelemetryBatch(resource: Fixtures.resource))
    #expect(StubURLProtocol.requests(host: host).first?.path == "/api/v1/telemetry")
  }

  @Test func nonSuccessStatusThrows() async throws {
    let host = uniqueHost()
    let transport = try makeTransport(host: host, statusCode: 503)
    await #expect(throws: TelemetryTransportError.rejected(statusCode: 503)) {
      try await transport.send(TelemetryBatch(resource: Fixtures.resource))
    }
  }

  @Test func exporterKeepsDataWhenTheServerRejects() async throws {
    let host = uniqueHost()
    let transport = try makeTransport(host: host, statusCode: 401)
    let buffer = TelemetryBuffer(capacity: 10)
    let exporter = RelayExporter(buffer: buffer, transport: transport, resource: Fixtures.resource)
    await buffer.record(span: Fixtures.span(1))

    await exporter.flush()

    #expect(await buffer.pendingCount == 1)
    #expect(StubURLProtocol.requests(host: host).count == 1)
  }
}
