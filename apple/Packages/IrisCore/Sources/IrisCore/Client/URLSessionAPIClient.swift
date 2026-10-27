import Foundation

/// The production `APIClient`: plain `URLSession` over the Iris HTTP API. The base URL and the device's
/// bearer token are injected; the token is only ever placed in the `Authorization` header.
public struct URLSessionAPIClient: APIClient {
  private static let maxErrorBodyBytes = 64 * 1024

  private let baseURL: URL
  private let bearerToken: String
  private let session: URLSession

  public init(baseURL: URL, bearerToken: String, session: URLSession = URLSession(configuration: .ephemeral)) {
    self.baseURL = baseURL
    self.bearerToken = bearerToken
    self.session = session
  }

  // MARK: APIClient

  public func health() async throws -> Health {
    try await decode(Health.self, from: makeRequest("GET", ["health"], authorized: false))
  }

  public func whoami() async throws -> Whoami {
    try await decode(Whoami.self, from: makeRequest("GET", ["v1", "whoami"]))
  }

  public func createMemo(_ body: CreateMemoRequest) async throws -> Memo {
    try await decode(Memo.self, from: makeJSONRequest("POST", ["v1", "memos"], body: body))
  }

  public func createTextMemo(_ body: CreateTextMemoRequest) async throws -> Memo {
    try await decode(Memo.self, from: makeJSONRequest("POST", ["v1", "memos", "text"], body: body))
  }

  public func uploadSegment(memoID: String, index: Int, data: Data) async throws {
    var request = try makeRequest("PUT", ["v1", "memos", memoID, "segments", String(index)])
    request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
    _ = try await perform { try await session.upload(for: request, from: data) }
  }

  public func completeMemo(id: String, request body: CompleteMemoRequest) async throws -> Memo {
    try await decode(Memo.self, from: makeJSONRequest("POST", ["v1", "memos", id, "complete"], body: body))
  }

  public func retryMemo(id: String, request body: RetryMemoRequest) async throws -> Memo {
    try await decode(Memo.self, from: makeJSONRequest("POST", ["v1", "memos", id, "retry"], body: body))
  }

  public func routeMemo(id: String, request body: RouteRequest) async throws -> Memo {
    try await decode(Memo.self, from: makeJSONRequest("POST", ["v1", "memos", id, "route"], body: body))
  }

  public func listMemos(_ query: ListMemosQuery) async throws -> MemoPage {
    try await decode(MemoPage.self, from: makeRequest("GET", ["v1", "memos"], query: query.queryItems))
  }

  public func memo(id: String) async throws -> MemoDetail {
    try await decode(MemoDetail.self, from: makeRequest("GET", ["v1", "memos", id]))
  }

  public func listThreads(_ query: ListThreadsQuery) async throws -> ThreadPage {
    try await decode(ThreadPage.self, from: makeRequest("GET", ["v1", "threads"], query: query.queryItems))
  }

  public func thread(id: String) async throws -> ThreadDetail {
    try await decode(ThreadDetail.self, from: makeRequest("GET", ["v1", "threads", id]))
  }

  public func result(id: String, query: MemoResultQuery) async throws -> MemoResult {
    var request = try makeRequest("GET", ["v1", "memos", id, "result"], query: query.queryItems)
    // The server holds the request for up to `wait` seconds; the idle timeout must outlast that.
    request.timeoutInterval = (query.wait ?? 0) + 30
    let (data, status) = try await perform { try await session.data(for: request) }
    let memo = try decode(Memo.self, from: data)
    return status == 202 ? .pending(memo) : .ready(memo)
  }

  public func registerDevice(_ body: RegisterDeviceRequest) async throws -> RegisterDeviceResponse {
    try await decode(
      RegisterDeviceResponse.self, from: makeJSONRequest("POST", ["v1", "devices", "register"], body: body))
  }

  public func setActivityToken(memoID: String, request body: ActivityTokenRequest) async throws {
    let request = try makeJSONRequest("PUT", ["v1", "memos", memoID, "activity-token"], body: body)
    _ = try await perform { try await session.data(for: request) }
  }

  public func herd() async throws -> Herd {
    try await decode(Herd.self, from: makeRequest("GET", ["v1", "herd"]))
  }

  public func events() -> AsyncThrowingStream<ServerEvent, any Error> {
    let session = session
    let request: URLRequest
    do {
      request = try makeRequest("GET", ["v1", "events"], accept: "text/event-stream")
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await Self.stream(request, on: session, into: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: Self.isCancellation(error) ? nil : Self.mapped(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: Plumbing

  private func makeRequest(
    _ method: String,
    _ components: [String],
    query: [URLQueryItem] = [],
    authorized: Bool = true,
    accept: String = "application/json"
  ) throws -> URLRequest {
    var url = components.reduce(baseURL) { $0.appending(component: $1) }
    if !query.isEmpty { url.append(queryItems: query) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(accept, forHTTPHeaderField: "Accept")
    if authorized { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
    return request
  }

  private func makeJSONRequest(_ method: String, _ components: [String], body: some Encodable) throws -> URLRequest {
    var request = try makeRequest(method, components)
    request.httpBody = try IrisJSON.makeEncoder().encode(body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  private func decode<Response: Decodable>(_ type: Response.Type, from request: URLRequest) async throws -> Response {
    let (data, _) = try await perform { try await session.data(for: request) }
    return try decode(type, from: data)
  }

  private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
    do {
      return try IrisJSON.makeDecoder().decode(type, from: data)
    } catch {
      throw APIError.decoding(String(describing: error))
    }
  }

  /// Runs one transfer and maps every failure to `APIError`. Returns the body and status of a 2xx answer.
  private func perform(_ transfer: () async throws -> (Data, URLResponse)) async throws -> (Data, Int) {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transfer()
    } catch {
      throw Self.isCancellation(error) ? CancellationError() : Self.mapped(error)
    }
    guard let http = response as? HTTPURLResponse else { throw APIError.transport(.badServerResponse) }
    guard (200..<300).contains(http.statusCode) else { throw APIError.from(status: http.statusCode, body: data) }
    return (data, http.statusCode)
  }

  private static func stream(
    _ request: URLRequest,
    on session: URLSession,
    into continuation: AsyncThrowingStream<ServerEvent, any Error>.Continuation
  ) async throws {
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw APIError.transport(.badServerResponse) }
    guard (200..<300).contains(http.statusCode) else {
      var body = Data()
      for try await byte in bytes where body.count < maxErrorBodyBytes { body.append(byte) }
      throw APIError.from(status: http.statusCode, body: body)
    }
    var parser = SSEParser()
    for try await byte in bytes {
      for sse in parser.feed(CollectionOfOne(byte)) {
        if let event = try ServerEvent.decode(sse) { continuation.yield(event) }
      }
    }
  }

  private static func isCancellation(_ error: any Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
  }

  private static func mapped(_ error: any Error) -> any Error {
    if let apiError = error as? APIError { return apiError }
    if let urlError = error as? URLError { return APIError.transport(urlError.code) }
    return APIError.transport(.unknown)
  }
}
