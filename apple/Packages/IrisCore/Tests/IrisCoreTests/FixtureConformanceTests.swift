import Foundation
import Testing

@testable import IrisCore

/// Decodes the fixture's bytes into the Swift type and encodes the value back.
typealias RoundTrip = @Sendable (Data) throws -> Data

private func roundTrip<Wire: Codable & Sendable>(_ type: Wire.Type) -> RoundTrip {
  { data in
    let value = try IrisJSON.makeDecoder().decode(Wire.self, from: data)
    return try IrisJSON.makeEncoder().encode(value)
  }
}

/// The ONE place a contract schema name meets a Swift type. A new schema or fixture without an entry
/// here fails `everyFixtureRoundTrips`, which forces the Swift side to follow the contract.
///
/// Intentional asymmetry: `liveactivity.content-state` maps to `LiveActivityContentState`, which declares
/// an optional `inputName` the server never sends. It is omitted when `nil`, so every fixture still
/// round-trips exactly. No other type drops or adds a field.
let fixtureTypes: [String: RoundTrip] = [
  "devices.register.request": roundTrip(RegisterDeviceRequest.self),
  "devices.register.response": roundTrip(RegisterDeviceResponse.self),
  "error": roundTrip(ErrorBody.self),
  "error.missing-segments": roundTrip(MissingSegmentsBody.self),
  "error.too-large": roundTrip(TooLargeBody.self),
  "events.memo-done": roundTrip(MemoEvent.self),
  "events.memo-updated": roundTrip(MemoEvent.self),
  "events.ready": roundTrip(ReadyEvent.self),
  "health.response": roundTrip(Health.self),
  "herd.response": roundTrip(Herd.self),
  "liveactivity.content-state": roundTrip(LiveActivityContentState.self),
  "memos.activity-token.request": roundTrip(ActivityTokenRequest.self),
  "memos.complete.request": roundTrip(CompleteMemoRequest.self),
  "memos.complete.response": roundTrip(Memo.self),
  "memos.create.request": roundTrip(CreateMemoRequest.self),
  "memos.create.response": roundTrip(Memo.self),
  "memos.detail.response": roundTrip(MemoDetail.self),
  "memos.delete.response": roundTrip(Memo.self),
  "memos.flags.request": roundTrip(SetFlagsRequest.self),
  "memos.flags.response": roundTrip(Memo.self),
  "memos.list.query": roundTrip(ListMemosQuery.self),
  "memos.list.response": roundTrip(MemoPage.self),
  "memos.text.request": roundTrip(CreateTextMemoRequest.self),
  "memos.text.response": roundTrip(Memo.self),
  "memos.restore.response": roundTrip(Memo.self),
  "memos.result.query": roundTrip(MemoResultQuery.self),
  "memos.result.response": roundTrip(Memo.self),
  "memos.retry.request": roundTrip(RetryMemoRequest.self),
  "memos.retry.response": roundTrip(Memo.self),
  "memos.route.request": roundTrip(RouteRequest.self),
  "memos.route.response": roundTrip(Memo.self),
  "push.alert": roundTrip(PushAlert.self),
  "stats.query": roundTrip(StatsQuery.self),
  "stats.response": roundTrip(Stats.self),
  "threads.detail.response": roundTrip(ThreadDetail.self),
  "threads.list.query": roundTrip(ListThreadsQuery.self),
  "threads.list.response": roundTrip(ThreadPage.self),
  "whoami.response": roundTrip(Whoami.self),
]

/// Schemas whose Swift types live in another package, which owns the fixture decode: IrisCore does not depend on
/// it, and these are not mapped in `fixtureTypes`. Every fixture of one is skipped by `everyFixtureRoundTrips`, and
/// `everySchemaIsMapped` does not ask for a type, but still requires the schema file to exist.
///
/// - `telemetry.*` (`POST /v1/telemetry`): `IrisTelemetry`, its `FixtureConformanceTests`.
let decodedElsewhere: Set<String> = ["telemetry.request", "telemetry.response"]

@Suite("Contract fixtures")
struct FixtureConformanceTests {
  @Test("The fixtures directory is found and not empty")
  func fixturesExist() throws {
    _ = try Contracts.root()
    #expect(Contracts.fixtures().count >= fixtureTypes.count)
  }

  @Test("Every fixture decodes into its Swift type and re-encodes to the same JSON", arguments: Contracts.fixtures())
  func everyFixtureRoundTrips(_ fixture: Fixture) throws {
    let schema = try #require(fixture.schema, "\(fixture.fileName) matches no schema in contracts/schema")
    guard !decodedElsewhere.contains(schema) else { return }
    let roundTrip = try #require(
      fixtureTypes[schema], "No Swift type is mapped for schema \(schema); add it to fixtureTypes")

    let original = try fixture.data
    let reencoded = try roundTrip(original)

    let decoder = JSONDecoder()
    #expect(try decoder.decode(JSONValue.self, from: reencoded) == decoder.decode(JSONValue.self, from: original))
  }

  @Test("Every schema and every schema the manifest names has a mapped Swift type")
  func everySchemaIsMapped() throws {
    let manifest = try Contracts.manifest()
    let schemas = try Contracts.schemaNames()
    let referenced = Set(manifest.strings(forKey: "schema") + manifest.strings(forKey: "query")).union(schemas)
    let unmapped = referenced.subtracting(fixtureTypes.keys).subtracting(decodedElsewhere)
    #expect(unmapped.isEmpty, "Unmapped: \(unmapped.sorted())")
    let stale = Set(fixtureTypes.keys).union(decodedElsewhere).subtracting(schemas)
    #expect(stale.isEmpty, "Mapped but no schema file: \(stale.sorted())")
  }

  @Test("Dates keep millisecond precision across a decode and encode")
  func dateRoundTrip() throws {
    struct Stamp: Codable { var at: Date }
    let json = #"{"at":"2026-03-14T09:20:50.440Z"}"#
    let stamp = try IrisJSON.makeDecoder().decode(Stamp.self, from: Data(json.utf8))
    #expect(String(decoding: try IrisJSON.makeEncoder().encode(stamp), as: UTF8.self) == json)
  }

  @Test("Dates without fractional seconds decode too")
  func dateWithoutFraction() throws {
    struct Stamp: Codable { var at: Date }
    let stamp = try IrisJSON.makeDecoder().decode(Stamp.self, from: Data(#"{"at":"2026-03-14T09:20:50Z"}"#.utf8))
    #expect(stamp.at == Date(timeIntervalSince1970: 1_773_480_050))
  }

  @Test("Register request distinguishes absent, null and set tokens")
  func registerRequestTriState() throws {
    let decoder = IrisJSON.makeDecoder()
    let minimal = try decoder.decode(
      RegisterDeviceRequest.self, from: Contracts.fixtureData("devices.register.request.minimal"))
    let cleared = try decoder.decode(
      RegisterDeviceRequest.self, from: Contracts.fixtureData("devices.register.request.clear-tokens"))
    let full = try decoder.decode(RegisterDeviceRequest.self, from: Contracts.fixtureData("devices.register.request"))
    #expect(minimal.apnsToken == .unchanged)
    #expect(cleared.apnsToken == .clear)
    #expect(cleared.apnsEnv == .clear)
    #expect(full.apnsEnv == .set(.sandbox))
  }

  @Test("A parked memo carries routeReason and routeSuggestion; other memos omit them on encode")
  func routeDetails() throws {
    let decoder = IrisJSON.makeDecoder()
    let parked = try decoder.decode(
      Memo.self, from: Contracts.fixtureData("memos.result.response.needs-route-suggestion"))
    #expect(parked.routeReason == "low confidence (0.62)")
    #expect(parked.routeSuggestion == "hermes")

    let routed = try decoder.decode(Memo.self, from: Contracts.fixtureData("memos.route.response"))
    #expect(routed.routeReason == nil)
    let encoded = String(decoding: try IrisJSON.makeEncoder().encode(routed), as: UTF8.self)
    #expect(!encoded.contains("routeReason") && !encoded.contains("routeSuggestion"))
  }

  @Test("The flags are always on the wire; deletedAt and purgeAt only while the memo is soft-deleted")
  func flags() throws {
    let decoder = IrisJSON.makeDecoder()
    let plain = try decoder.decode(Memo.self, from: Contracts.fixtureData("memos.create.response"))
    #expect(!plain.done && !plain.favorite && !plain.archived && !plain.isDeleted)
    let encoded = String(decoding: try IrisJSON.makeEncoder().encode(plain), as: UTF8.self)
    #expect(encoded.contains("\"done\":false") && encoded.contains("\"archived\":false"))
    #expect(!encoded.contains("deletedAt") && !encoded.contains("purgeAt"))

    let flagged = try decoder.decode(Memo.self, from: Contracts.fixtureData("memos.flags.response"))
    #expect(flagged.done && flagged.favorite && flagged.archived)

    let deleted = try decoder.decode(Memo.self, from: Contracts.fixtureData("memos.delete.response"))
    let deletedAt = try #require(deleted.deletedAt)
    #expect(deleted.isDeleted)
    #expect(deleted.purgeAt == deletedAt.addingTimeInterval(600))

    let restored = try decoder.decode(Memo.self, from: Contracts.fixtureData("memos.restore.response"))
    #expect(!restored.isDeleted && restored.purgeAt == nil)
  }

  @Test("A memo from a server without flags reads as unflagged")
  func memoWithoutFlagKeys() throws {
    let json = try JSONDecoder().decode(JSONValue.self, from: Contracts.fixtureData("memos.create.response"))
    guard case .object(var object) = json else {
      Issue.record("fixture is not an object")
      return
    }
    for key in ["done", "favorite", "archived"] { object[key] = nil }
    let data = try JSONEncoder().encode(JSONValue.object(object))
    let memo = try IrisJSON.makeDecoder().decode(Memo.self, from: data)
    #expect(!memo.done && !memo.favorite && !memo.archived)
  }

  @Test("The list query fixtures carry the flag filters as the string \"true\" and send them as query items")
  func listQueryFilters() throws {
    let decoder = IrisJSON.makeDecoder()
    let filters = try decoder.decode(ListMemosQuery.self, from: Contracts.fixtureData("memos.list.query.filters"))
    #expect(filters.favorite && !filters.archived && filters.kind == .chat)
    #expect(
      filters.queryItems == [
        URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "favorite", value: "true"),
        URLQueryItem(name: "kind", value: "chat"),
      ])
    let archived = try decoder.decode(ListMemosQuery.self, from: Contracts.fixtureData("memos.list.query.archived"))
    #expect(archived.archived && !archived.favorite)
    #expect(ListMemosQuery(favorite: false, archived: false, kind: .unknown).queryItems.isEmpty)
    #expect(throws: DecodingError.self) {
      try decoder.decode(ListMemosQuery.self, from: Data(#"{"favorite":"false"}"#.utf8))
    }
  }

  @Test("A flags request omits the flags it does not change")
  func flagsRequest() throws {
    let encoded = try IrisJSON.makeEncoder().encode(SetFlagsRequest(favorite: true))
    #expect(String(decoding: encoded, as: UTF8.self) == #"{"favorite":true}"#)
  }

  @Test("`typed` is explicit: true on a typed memo, absent on a recording, in a memo and in the detail")
  func typedMemo() throws {
    let decoder = IrisJSON.makeDecoder()
    let memo = try decoder.decode(Memo.self, from: Contracts.fixtureData("memos.text.response"))
    #expect(memo.state == .transcribed)
    #expect(memo.isTyped)

    let detail = try decoder.decode(MemoDetail.self, from: Contracts.fixtureData("memos.detail.response.typed"))
    #expect(detail.memo.segmentCount == 0)
    #expect(detail.memo.isTyped)

    let recorded = try decoder.decode(Memo.self, from: Contracts.fixtureData("memos.create.response"))
    #expect(!recorded.isTyped)
    let encoded = String(decoding: try IrisJSON.makeEncoder().encode(recorded), as: UTF8.self)
    #expect(!encoded.contains("\"typed\""))
  }

  @Test("each step carries `attempts`: 3 on the step that exhausted its automatic retries, 1 elsewhere")
  func stepAttempts() throws {
    let decoder = IrisJSON.makeDecoder()
    let failed = try decoder.decode(MemoDetail.self, from: Contracts.fixtureData("memos.detail.response.failed"))
    #expect(failed.steps.map(\.attempts) == [3])
    let notified = try decoder.decode(MemoDetail.self, from: Contracts.fixtureData("memos.detail.response"))
    #expect(notified.steps.allSatisfy { $0.attempts == 1 })
    let encoded = String(decoding: try IrisJSON.makeEncoder().encode(failed), as: UTF8.self)
    #expect(encoded.contains("\"attempts\":3"))
  }

  @Test("`replyBlocks` carry the asset ids per block, format and scheme; a memo without rendered blocks omits the key")
  func replyBlocks() throws {
    let decoder = IrisJSON.makeDecoder()
    let detail = try decoder.decode(MemoDetail.self, from: Contracts.fixtureData("memos.detail.response.assets"))
    let block = try #require(detail.memo.replyBlocks.first)
    #expect(detail.memo.replyBlocks.count == 1)
    #expect(block.index == 0)
    #expect(block.width == 486)
    #expect(block.height == 64)
    #expect(block.kind == .mermaid)
    #expect(block.svg == SchemeAssets(light: "5b0e2f8a-3c41-4d7e-9a16-8f2d0c7b1e53", dark: "a4c19d62-7e08-4f35-b2a1-3d9e5f06c874"))
    #expect(block.png.dark == "2d84b6c9-0f17-4e3a-8b52-c6a9e1d37f40")
    #expect(detail.memo.replyText?.contains("```mermaid") == true)

    let plain = try decoder.decode(MemoDetail.self, from: Contracts.fixtureData("memos.detail.response.chat"))
    #expect(plain.memo.replyBlocks.isEmpty)
    let encoded = String(decoding: try IrisJSON.makeEncoder().encode(plain), as: UTF8.self)
    #expect(!encoded.contains("replyBlocks"))
  }

  @Test("`threadId` is present on a chat memo's detail and omitted on a memo without one")
  func threadId() throws {
    let decoder = IrisJSON.makeDecoder()
    let chat = try decoder.decode(MemoDetail.self, from: Contracts.fixtureData("memos.detail.response.chat"))
    #expect(chat.memo.mode == .chat)
    #expect(chat.memo.threadId == chat.memo.id)

    let plain = try decoder.decode(Memo.self, from: Contracts.fixtureData("memos.create.response"))
    #expect(plain.threadId == nil)
    let encoded = String(decoding: try IrisJSON.makeEncoder().encode(plain), as: UTF8.self)
    #expect(!encoded.contains("threadId"))
  }

  @Test("`threadId` on a create request continues a thread; the thread detail is the conversation of its memos")
  func threads() throws {
    let decoder = IrisJSON.makeDecoder()
    let create = try decoder.decode(CreateMemoRequest.self, from: Contracts.fixtureData("memos.create.request.thread"))
    #expect(create.threadId == "9d4f2b68-1e73-4a85-b0c6-5f8a3e7d2c10")
    let text = try decoder.decode(CreateTextMemoRequest.self, from: Contracts.fixtureData("memos.text.request.thread"))
    #expect(text.threadId == create.threadId)
    let plain = try decoder.decode(CreateMemoRequest.self, from: Contracts.fixtureData("memos.create.request"))
    #expect(plain.threadId == nil)
    let encoded = String(decoding: try IrisJSON.makeEncoder().encode(plain), as: UTF8.self)
    #expect(!encoded.contains("threadId"))

    let detail = try decoder.decode(ThreadDetail.self, from: Contracts.fixtureData("threads.detail.response"))
    #expect(detail.thread.kind == .chat)
    #expect(detail.memos.map(\.threadId) == [detail.id, detail.id])
    #expect(detail.messages.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(detail.messages.map(\.memoId) == detail.memos.flatMap { [$0.id, $0.id] })
  }

  @Test("A thread kind this build does not know decodes with .unknown and keeps the rest of the page")
  func unknownThreadKind() throws {
    let original = String(decoding: try Contracts.fixtureData("threads.list.response"), as: UTF8.self)
    let patched = original.replacingOccurrences(of: "\"kind\": \"chat\"", with: "\"kind\": \"voice\"")
    #expect(patched != original)
    let page = try IrisJSON.makeDecoder().decode(ThreadPage.self, from: Data(patched.utf8))
    #expect(page.items.map(\.kind) == [.unknown, .hermes])
    #expect(!ThreadKind.allCases.contains(.unknown))
  }

  @Test("A memo with a mode this build does not know decodes with .unknown and keeps the rest of the page")
  func unknownMode() throws {
    let original = String(decoding: try Contracts.fixtureData("memos.list.response"), as: UTF8.self)
    let patched = original.replacingOccurrences(of: "\"mode\": \"auto\"", with: "\"mode\": \"voice-note\"")
    #expect(patched != original)

    let decoder = IrisJSON.makeDecoder()
    let known = try decoder.decode(MemoPage.self, from: Data(original.utf8))
    let page = try decoder.decode(MemoPage.self, from: Data(patched.utf8))
    #expect(page.items.count == known.items.count)
    #expect(page.items.first?.mode == .unknown)
    #expect(page.items.dropFirst().map(\.mode) == known.items.dropFirst().map(\.mode))
    #expect(!MemoMode.allCases.contains(.unknown))
  }

  @Test("Result-ready states match the server")
  func resultReadyStates() {
    #expect(MemoState.allCases.filter(\.isResultReady) == [.needsRoute, .notified, .failed])
  }
}
