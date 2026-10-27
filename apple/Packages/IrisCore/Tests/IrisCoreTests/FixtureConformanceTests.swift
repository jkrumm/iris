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
  "memos.list.query": roundTrip(ListMemosQuery.self),
  "memos.list.response": roundTrip(MemoPage.self),
  "memos.text.request": roundTrip(CreateTextMemoRequest.self),
  "memos.text.response": roundTrip(Memo.self),
  "memos.result.query": roundTrip(MemoResultQuery.self),
  "memos.result.response": roundTrip(Memo.self),
  "memos.retry.request": roundTrip(RetryMemoRequest.self),
  "memos.retry.response": roundTrip(Memo.self),
  "memos.route.request": roundTrip(RouteRequest.self),
  "memos.route.response": roundTrip(Memo.self),
  "push.alert": roundTrip(PushAlert.self),
  "whoami.response": roundTrip(Whoami.self),
]

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
    let unmapped = referenced.subtracting(fixtureTypes.keys)
    #expect(unmapped.isEmpty, "Unmapped: \(unmapped.sorted())")
    let stale = Set(fixtureTypes.keys).subtracting(schemas)
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
