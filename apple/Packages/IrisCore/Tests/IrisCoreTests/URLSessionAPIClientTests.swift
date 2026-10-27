import Foundation
import Testing

@testable import IrisCore

private let memoID = "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34"

private func jsonValue(_ data: Data) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: data)
}

/// A fixture re-serialized onto one line, as it travels in an SSE `data:` field.
private func compactFixture(_ name: String) throws -> String {
  String(decoding: try IrisJSON.makeEncoder().encode(jsonValue(Contracts.fixtureData(name))), as: UTF8.self)
}

@Suite("URLSessionAPIClient")
struct URLSessionAPIClientTests {
  // MARK: Request shape

  @Test("whoami: GET /v1/whoami with the bearer token and no body")
  func whoami() async throws {
    let server = StubServer { _ in try .json(fixture: "whoami.response") }
    let whoami = try await server.makeClient().whoami()

    #expect(whoami == Whoami(device: "iphone"))
    let request = try #require(server.request)
    #expect(request.method == "GET")
    #expect(request.url.path == "/v1/whoami")
    #expect(request.header("Authorization") == "Bearer test-token")
    #expect(request.header("Accept") == "application/json")
    #expect(request.body.isEmpty)
  }

  @Test("health is the one route sent without credentials")
  func health() async throws {
    let server = StubServer { _ in try .json(fixture: "health.response.degraded") }
    let health = try await server.makeClient().health()

    #expect(health.status == .degraded)
    #expect(health.degraded == ["otel", "summarize"])
    let request = try #require(server.request)
    #expect(request.url.path == "/health")
    #expect(request.header("Authorization") == nil)
  }

  @Test("A base URL with a path prefix keeps the prefix")
  func basePathPrefix() async throws {
    let server = StubServer { _ in try .json(fixture: "whoami.response") }
    _ = try await server.makeClient(path: "/iris").whoami()
    #expect(server.request?.url.path == "/iris/v1/whoami")
  }

  @Test("createMemo: POST /v1/memos with the JSON request")
  func createMemo() async throws {
    let server = StubServer { _ in try .json(201, fixture: "memos.create.response.hermes") }
    let fixture = try Contracts.fixtureData("memos.create.request")
    let body = try IrisJSON.makeDecoder().decode(CreateMemoRequest.self, from: fixture)

    let memo = try await server.makeClient().createMemo(body)

    #expect(memo.mode == .hermes)
    #expect(memo.state == .receiving)
    let request = try #require(server.request)
    #expect(request.method == "POST")
    #expect(request.url.path == "/v1/memos")
    #expect(request.header("Content-Type") == "application/json")
    #expect(try jsonValue(request.body) == jsonValue(fixture))
  }

  @Test("createTextMemo: POST the text fixture to /v1/memos/text and decode the 202 memo")
  func createTextMemo() async throws {
    let server = StubServer { _ in try .json(202, fixture: "memos.text.response") }
    let body = try IrisJSON.makeDecoder().decode(
      CreateTextMemoRequest.self, from: Contracts.fixtureData("memos.text.request"))

    let memo = try await server.makeClient().createTextMemo(body)

    #expect(memo.state == .transcribed)
    #expect(memo.transcript == "Remind me to book the dentist for next week.")
    let request = try #require(server.request)
    #expect(request.method == "POST")
    #expect(request.url.path == "/v1/memos/text")
    #expect(request.header("Content-Type") == "application/json")
    #expect(try jsonValue(request.body) == jsonValue(Contracts.fixtureData("memos.text.request")))
  }

  @Test("uploadSegment: PUT raw bytes to /v1/memos/:id/segments/:n")
  func uploadSegment() async throws {
    let server = StubServer { _ in .empty(200) }
    let bytes = Data((0..<5000).map { UInt8($0 % 251) })

    try await server.makeClient().uploadSegment(memoID: memoID, index: 2, data: bytes)

    let request = try #require(server.request)
    #expect(request.method == "PUT")
    #expect(request.url.path == "/v1/memos/\(memoID)/segments/2")
    #expect(request.header("Content-Type") == "audio/mp4")
    #expect(request.header("Authorization") == "Bearer test-token")
    #expect(request.body == bytes)
  }

  @Test("completeMemo and retryMemo post their JSON bodies")
  func completeAndRetry() async throws {
    let server = StubServer { request in
      request.url.path.hasSuffix("/complete")
        ? try .json(202, fixture: "memos.complete.response") : try .json(202, fixture: "memos.retry.response")
    }
    let client = server.makeClient()

    let completed = try await client.completeMemo(id: memoID, request: CompleteMemoRequest(segmentCount: 4))
    let retried = try await client.retryMemo(id: memoID, request: RetryMemoRequest(from: .transcribe))

    #expect(completed.state == .received)
    #expect(retried.state == .received)
    let requests = server.requests
    #expect(requests.map(\.url.path) == ["/v1/memos/\(memoID)/complete", "/v1/memos/\(memoID)/retry"])
    #expect(requests.map(\.method) == ["POST", "POST"])
    #expect(try jsonValue(requests[0].body) == jsonValue(Contracts.fixtureData("memos.complete.request")))
    #expect(try jsonValue(requests[1].body) == jsonValue(Contracts.fixtureData("memos.retry.request")))
  }

  @Test("routeMemo posts the destination and tab to /route and decodes 202 and 200 alike")
  func routeMemo() async throws {
    for status in [202, 200] {
      let server = StubServer { _ in try .json(status, fixture: "memos.route.response") }
      let memo = try await server.makeClient().routeMemo(
        id: memoID, request: RouteRequest(destination: .herdr, tab: "w1:t1"))

      #expect(memo.state == .routed)
      #expect(memo.route == "hermes")
      let request = try #require(server.request)
      #expect(request.method == "POST")
      #expect(request.url.path == "/v1/memos/\(memoID)/route")
      #expect(try jsonValue(request.body) == jsonValue(Contracts.fixtureData("memos.route.request.herdr")))
    }
  }

  @Test("routeMemo without a tab omits the key")
  func routeMemoNoTab() async throws {
    let server = StubServer { _ in try .json(202, fixture: "memos.route.response") }
    _ = try await server.makeClient().routeMemo(id: memoID, request: RouteRequest(destination: .hermes))
    let request = try #require(server.request)
    #expect(try jsonValue(request.body) == jsonValue(Contracts.fixtureData("memos.route.request")))
  }

  @Test("routeMemo maps a 409 to the server error")
  func routeMemoConflict() async throws {
    let server = StubServer { _ in try .json(409, fixture: "error.bad-state") }
    await #expect(throws: APIError.self) {
      try await server.makeClient().routeMemo(id: memoID, request: RouteRequest(destination: .hermes))
    }
  }

  @Test("listMemos sends limit and cursor as query items")
  func listMemos() async throws {
    let server = StubServer { _ in try .json(fixture: "memos.list.response") }
    let page = try await server.makeClient().listMemos(ListMemosQuery(limit: 20, cursor: "41"))

    #expect(page.items.count == 3)
    #expect(page.nextCursor == "41")
    let request = try #require(server.request)
    #expect(request.url.path == "/v1/memos")
    #expect(
      request.queryItems == [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "cursor", value: "41")])
  }

  @Test("listMemos sends q, route and state and decodes the pinned memos")
  func listMemosSearch() async throws {
    let server = StubServer { _ in try .json(fixture: "memos.list.response.pinned") }
    let query = ListMemosQuery(limit: 20, q: "kalender termin", route: .hermes, state: .notified)
    let page = try await server.makeClient().listMemos(query)

    #expect(page.pinned.map(\.state) == [.needsRoute])
    #expect(page.items.count == 2)
    let request = try #require(server.request)
    #expect(
      request.queryItems == [
        URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "q", value: "kalender termin"),
        URLQueryItem(name: "route", value: "hermes"), URLQueryItem(name: "state", value: "notified"),
      ])
  }

  @Test("listMemos without a query sends none")
  func listMemosNoQuery() async throws {
    let server = StubServer { _ in try .json(fixture: "memos.list.response.empty") }
    let page = try await server.makeClient().listMemos(ListMemosQuery())
    #expect(page.items.isEmpty)
    #expect(server.request?.url.query == nil)
  }

  @Test("memo(id:) decodes the detail with its steps")
  func detail() async throws {
    let server = StubServer { _ in try .json(fixture: "memos.detail.response") }
    let detail = try await server.makeClient().memo(id: memoID)

    #expect(detail.steps.map(\.step) == [.transcribe, .route, .act, .summarize, .notify])
    #expect(detail.memo.summary?.headline == "Wochenplan abgestimmt, Release am Donnerstag")
    #expect(server.request?.url.path == "/v1/memos/\(memoID)")
  }

  @Test("createMemo and createTextMemo send the threadId of a continuation")
  func createInThread() async throws {
    let server = StubServer { _ in try .json(201, fixture: "memos.create.response") }
    let decoder = IrisJSON.makeDecoder()
    let create = try decoder.decode(CreateMemoRequest.self, from: Contracts.fixtureData("memos.create.request.thread"))
    _ = try await server.makeClient().createMemo(create)
    #expect(
      try jsonValue(#require(server.request).body) == jsonValue(Contracts.fixtureData("memos.create.request.thread")))

    let textServer = StubServer { _ in try .json(202, fixture: "memos.text.response") }
    let text = try decoder.decode(CreateTextMemoRequest.self, from: Contracts.fixtureData("memos.text.request.thread"))
    _ = try await textServer.makeClient().createTextMemo(text)
    #expect(
      try jsonValue(#require(textServer.request).body) == jsonValue(Contracts.fixtureData("memos.text.request.thread")))
  }

  @Test("listThreads sends kind, limit and cursor as query items")
  func listThreads() async throws {
    let server = StubServer { _ in try .json(fixture: "threads.list.response") }
    let page = try await server.makeClient().listThreads(ListThreadsQuery(kind: .chat, limit: 20, cursor: "abc"))

    #expect(page.items.map(\.kind) == [.chat, .hermes])
    #expect(page.nextCursor != nil)
    let request = try #require(server.request)
    #expect(request.method == "GET")
    #expect(request.url.path == "/v1/threads")
    #expect(
      request.queryItems == [
        URLQueryItem(name: "kind", value: "chat"), URLQueryItem(name: "limit", value: "20"),
        URLQueryItem(name: "cursor", value: "abc"),
      ])
  }

  @Test("listThreads without a query sends none")
  func listThreadsNoQuery() async throws {
    let server = StubServer { _ in try .json(fixture: "threads.list.response.empty") }
    let page = try await server.makeClient().listThreads(ListThreadsQuery())
    #expect(page.items.isEmpty)
    #expect(server.request?.url.query == nil)
  }

  @Test("thread(id:) decodes the thread, its memos and the conversation")
  func threadDetail() async throws {
    let server = StubServer { _ in try .json(fixture: "threads.detail.response") }
    let detail = try await server.makeClient().thread(id: "t1")
    #expect(detail.memos.count == 2)
    #expect(detail.messages.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(server.request?.url.path == "/v1/threads/t1")
  }

  @Test("result: 200 is ready, 202 is pending, and wait goes in the query")
  func result() async throws {
    let server = StubServer { request in
      request.url.query?.contains("wait=30") == true
        ? try .json(202, fixture: "memos.result.response.pending") : try .json(200, fixture: "memos.result.response")
    }
    let client = server.makeClient()

    let pending = try await client.result(id: memoID, query: MemoResultQuery(wait: 30))
    let ready = try await client.result(id: memoID, query: MemoResultQuery())

    guard case .pending(let waiting) = pending, case .ready(let done) = ready else {
      Issue.record("expected pending then ready, got \(pending) and \(ready)")
      return
    }
    #expect(waiting.state == .acted)
    #expect(done.state == .notified)
    let requests = server.requests
    #expect(requests.map(\.url.path) == ["/v1/memos/\(memoID)/result", "/v1/memos/\(memoID)/result"])
    #expect(requests[0].queryItems == [URLQueryItem(name: "wait", value: "30.0")])
    #expect(requests[1].queryItems.isEmpty)
  }

  @Test("registerDevice sends explicit nulls to clear tokens")
  func registerDevice() async throws {
    let server = StubServer { _ in try .json(fixture: "devices.register.response.bare") }
    let fixture = try Contracts.fixtureData("devices.register.request.clear-tokens")
    let body = try IrisJSON.makeDecoder().decode(RegisterDeviceRequest.self, from: fixture)

    let response = try await server.makeClient().registerDevice(body)

    #expect(response.hasApnsToken == false)
    let request = try #require(server.request)
    #expect(request.method == "POST")
    #expect(request.url.path == "/v1/devices/register")
    #expect(try jsonValue(request.body) == jsonValue(fixture))
  }

  @Test("setActivityToken: PUT, 204 with an empty body")
  func activityToken() async throws {
    let server = StubServer { _ in .empty(204) }
    let fixture = try Contracts.fixtureData("memos.activity-token.request")
    let body = try IrisJSON.makeDecoder().decode(ActivityTokenRequest.self, from: fixture)

    try await server.makeClient().setActivityToken(memoID: memoID, request: body)

    let request = try #require(server.request)
    #expect(request.method == "PUT")
    #expect(request.url.path == "/v1/memos/\(memoID)/activity-token")
    #expect(try jsonValue(request.body) == jsonValue(fixture))
  }

  @Test("herd decodes the live tabs")
  func herd() async throws {
    let server = StubServer { _ in try .json(fixture: "herd.response") }
    let herd = try await server.makeClient().herd()
    #expect(herd.tabs.map(\.id) == ["w1:t2", "w3:t1"])
    #expect(herd.tabs[1].lastActivity == nil)
    #expect(server.request?.url.path == "/v1/herd")
  }

  @Test("stats decodes the aggregates and sends days as a query item")
  func stats() async throws {
    let server = StubServer { _ in try .json(fixture: "stats.response") }
    let stats = try await server.makeClient().stats(StatsQuery(days: 7))
    #expect(stats.days == 7)
    #expect(stats.perDay.contains(StatsDayCount(date: "2026-03-12", route: "unrouted", count: 1)))
    #expect(
      stats.stepMedians.map(\.step) == [
        .transcribe, .transcribe, .transcribe, .transcribe, .route, .act, .summarize, .notify,
      ])
    #expect(
      stats.stepMedians.first { $0.step == .transcribe && $0.route == "hermes" }
        == StatsStepMedian(step: .transcribe, route: "hermes", medianMs: 4120, samples: 3))
    #expect(stats.costPerRoute.first { $0.route == "hermes" }?.costUsd == 0.0421)
    #expect(server.request?.url.path == "/v1/stats")
    #expect(server.request?.queryItems == [URLQueryItem(name: "days", value: "7")])
  }

  @Test("stats without days sends no query and decodes an empty window")
  func statsEmpty() async throws {
    let server = StubServer { _ in try .json(fixture: "stats.response.empty") }
    let stats = try await server.makeClient().stats(StatsQuery())
    #expect(stats.perDay.isEmpty && stats.perWeek.isEmpty && stats.stepMedians.isEmpty && stats.costPerRoute.isEmpty)
    #expect(server.request?.url.query == nil)
  }

  // MARK: Error mapping

  struct ErrorCase: Sendable, CustomTestStringConvertible {
    var name: String
    var response: StubResponse
    var expected: APIError
    var testDescription: String { name }
  }

  static func errorCases() throws -> [ErrorCase] {
    [
      ErrorCase(name: "401 plain text", response: .text(401, "Unauthorized"), expected: .unauthorized),
      ErrorCase(
        name: "404 not_found", response: try .json(404, fixture: "error"),
        expected: .server(status: 404, body: ErrorBody(error: .notFound, message: "memo not found"))),
      ErrorCase(
        name: "409 conflict", response: try .json(409, fixture: "error.conflict"),
        expected: .server(status: 409, body: ErrorBody(error: .conflict, message: "memo belongs to another device"))),
      ErrorCase(
        name: "400 bad_request", response: try .json(400, fixture: "error.bad-request"),
        expected: .server(status: 400, body: ErrorBody(error: .badRequest, message: "/mode: Expected union value"))),
      ErrorCase(
        name: "503 unavailable", response: try .json(503, fixture: "error.unavailable"),
        expected: .server(status: 503, body: ErrorBody(error: .unavailable, message: "herd is not configured"))),
      ErrorCase(
        name: "422 missing_segments", response: try .json(422, fixture: "error.missing-segments"),
        expected: .missingSegments(message: "segments missing: 1, 3", missing: [1, 3])),
      ErrorCase(
        name: "413 too_large", response: try .json(413, fixture: "error.too-large"),
        expected: .tooLarge(message: "segment exceeds 1048576 bytes", maxBytes: 1_048_576)),
      ErrorCase(name: "502 HTML", response: .text(502, "<html>Bad Gateway</html>"), expected: .unexpectedStatus(502)),
      ErrorCase(name: "500 empty", response: .empty(500), expected: .unexpectedStatus(500)),
    ]
  }

  @Test("Non-2xx responses map to a typed APIError", arguments: try errorCases())
  func errorMapping(_ errorCase: ErrorCase) async throws {
    let server = StubServer { _ in errorCase.response }
    await #expect(throws: errorCase.expected) {
      try await server.makeClient().completeMemo(id: memoID, request: CompleteMemoRequest(segmentCount: 4))
    }
  }

  @Test("The error mapping applies to uploads and body-less requests too")
  func errorMappingOnOtherVerbs() async throws {
    let server = StubServer { _ in try .json(413, fixture: "error.too-large") }
    let client = server.makeClient()
    await #expect(throws: APIError.tooLarge(message: "segment exceeds 1048576 bytes", maxBytes: 1_048_576)) {
      try await client.uploadSegment(memoID: memoID, index: 0, data: Data(count: 10))
    }
    await #expect(throws: APIError.tooLarge(message: "segment exceeds 1048576 bytes", maxBytes: 1_048_576)) {
      try await client.herd()
    }
  }

  @Test("A 2xx body that is not the contract type is a decoding error")
  func decodingError() async {
    let server = StubServer { _ in .text(200, "not json") }
    await #expect {
      try await server.makeClient().whoami()
    } throws: { error in
      guard case APIError.decoding = error else { return false }
      return true
    }
  }

  @Test("A connection failure is a transport error")
  func transportError() async {
    let server = StubServer { _ in throw URLError(.notConnectedToInternet) }
    await #expect(throws: APIError.transport(.notConnectedToInternet)) {
      try await server.makeClient().whoami()
    }
  }

  // MARK: Events

  @Test("events streams typed events, skips keepalives and unknown events, across chunk boundaries")
  func events() async throws {
    let updated = try compactFixture("events.memo-updated")
    let done = try compactFixture("events.memo-done")
    let body =
      "event: ready\ndata: {}\n\n: keepalive\n\nevent: future.thing\ndata: {}\n\n"
      + "event: memo.updated\ndata: \(updated)\n\nevent: memo.done\ndata: \(done)\n\n"
    let bytes = Array(body.utf8)
    let server = StubServer { _ in
      StubResponse(
        status: 200, headers: ["Content-Type": "text/event-stream"],
        chunks: [Data(bytes[..<17]), Data(bytes[17..<90]), Data(bytes[90...])])
    }

    var received: [ServerEvent] = []
    for try await event in server.makeClient().events() { received.append(event) }

    #expect(received.count == 3)
    #expect(received.first == .ready)
    guard case .memoUpdated(let first) = received[1], case .memoDone(let last) = received[2] else {
      Issue.record("unexpected events \(received)")
      return
    }
    #expect(first.state == .received)
    #expect(last.state == .notified)
    let request = try #require(server.request)
    #expect(request.url.path == "/v1/events")
    #expect(request.header("Accept") == "text/event-stream")
    #expect(request.header("Authorization") == "Bearer test-token")
  }

  @Test("events throws unauthorized on a 401")
  func eventsUnauthorized() async {
    let server = StubServer { _ in .text(401, "Unauthorized") }
    await #expect(throws: APIError.unauthorized) {
      for try await _ in server.makeClient().events() {}
    }
  }
}
