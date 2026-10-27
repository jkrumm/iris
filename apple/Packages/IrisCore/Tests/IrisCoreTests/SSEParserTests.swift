import Foundation
import Testing

@testable import IrisCore

/// A small seeded generator so the chunk-split fuzz is reproducible.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

private func parse(_ chunks: [[UInt8]]) -> [SSEEvent] {
  var parser = SSEParser()
  return chunks.flatMap { parser.feed($0) }
}

private func parse(_ text: String) -> [SSEEvent] {
  parse([Array(text.utf8)])
}

/// The events of the `events.*` fixtures as the server would write them, plus the events they must parse to.
private func fixtureStream(lineEnding: String) throws -> (bytes: [UInt8], expected: [SSEEvent]) {
  let manifest = try Contracts.manifest()
  guard case .object(let route)? = Contracts.eventsRoute(in: manifest), case .array(let declared)? = route["events"]
  else { throw Contracts.LocationError.repoRootNotFound(from: "manifest has no events route") }
  var names: [String: String] = [:]
  for case .object(let event) in declared {
    if case .string(let name)? = event["name"], case .string(let schema)? = event["schema"] { names[schema] = name }
  }
  var text = ": keepalive\(lineEnding)\(lineEnding)"
  var expected: [SSEEvent] = []
  for fixture in Contracts.fixtures() {
    guard let schema = fixture.schema, let name = names[schema] else { continue }
    let value = try JSONDecoder().decode(JSONValue.self, from: fixture.data)
    let data = String(decoding: try IrisJSON.makeEncoder().encode(value), as: UTF8.self)
    text += "event: \(name)\(lineEnding)data: \(data)\(lineEnding)\(lineEnding)"
    text += ": keepalive\(lineEnding)\(lineEnding)"
    expected.append(SSEEvent(event: name, data: data))
  }
  return (Array(text.utf8), expected)
}

@Suite("SSE parser")
struct SSEParserTests {
  @Test("The events.* fixtures parse the same at every single split point", arguments: ["\n", "\r\n", "\r"])
  func everySplitPoint(lineEnding: String) throws {
    let (bytes, expected) = try fixtureStream(lineEnding: lineEnding)
    #expect(expected.count >= 5)
    for split in 0...bytes.count {
      #expect(parse([Array(bytes[..<split]), Array(bytes[split...])]) == expected, "split at \(split)")
    }
  }

  @Test("Random chunk sizes, and one byte at a time, parse the same", arguments: ["\n", "\r\n"])
  func randomChunks(lineEnding: String) throws {
    let (bytes, expected) = try fixtureStream(lineEnding: lineEnding)
    #expect(parse(bytes.map { [$0] }) == expected)

    var random = SplitMix64(state: 0x1215)
    for _ in 0..<200 {
      var chunks: [[UInt8]] = []
      var index = 0
      while index < bytes.count {
        let end = min(bytes.count, index + Int.random(in: 1...40, using: &random))
        chunks.append(Array(bytes[index..<end]))
        index = end
      }
      #expect(parse(chunks) == expected)
    }
  }

  @Test("Fixture events decode into typed ServerEvents")
  func fixtureEventsDecode() throws {
    let (bytes, _) = try fixtureStream(lineEnding: "\n")
    let events = try parse([bytes]).compactMap(ServerEvent.decode)
    let ready = events.filter { $0 == .ready }.count
    let updated = events.filter { if case .memoUpdated = $0 { true } else { false } }.count
    let done = events.filter { if case .memoDone = $0 { true } else { false } }.count
    #expect((ready, updated, done) == (1, 3, 2))
  }

  @Test("Comments and keepalives yield nothing")
  func comments() {
    #expect(parse(": keepalive\n\n: another\n: and more\n\n").isEmpty)
  }

  @Test("Multi-line data joins with a newline")
  func multiLineData() {
    #expect(
      parse("event: note\ndata: one\ndata: two\ndata:\ndata: four\n\n") == [
        SSEEvent(event: "note", data: "one\ntwo\n\nfour")
      ])
  }

  @Test("A comment inside an event does not end it")
  func commentInsideEvent() {
    #expect(parse("event: a\n: keepalive\ndata: x\n\n") == [SSEEvent(event: "a", data: "x")])
  }

  @Test("Only one leading space after the colon is stripped")
  func leadingSpace() {
    #expect(
      parse("data:  two\n\ndata:none\n\n") == [
        SSEEvent(event: "message", data: " two"), SSEEvent(event: "message", data: "none"),
      ])
  }

  @Test("The event name resets between events")
  func eventNameResets() {
    #expect(
      parse("event: a\ndata: 1\n\ndata: 2\n\n") == [
        SSEEvent(event: "a", data: "1"), SSEEvent(event: "message", data: "2"),
      ])
  }

  @Test("An event with no data line is not dispatched")
  func noData() {
    #expect(parse("event: a\n\nid: 7\nretry: 1000\n\n").isEmpty)
  }

  @Test("A trailing partial event is dropped")
  func partialEvent() {
    #expect(parse("event: a\ndata: 1\n\nevent: b\ndata: 2\n") == [SSEEvent(event: "a", data: "1")])
  }

  @Test("Multi-byte characters split across chunks survive")
  func multiByteSplit() {
    let bytes = Array("data: Größe 日本\n\n".utf8)
    for split in 0...bytes.count {
      #expect(
        parse([Array(bytes[..<split]), Array(bytes[split...])]) == [SSEEvent(event: "message", data: "Größe 日本")])
    }
  }

  @Test("A parser keeps state across feeds")
  func incremental() {
    var parser = SSEParser()
    #expect(parser.feed(Array("event: ready\nda".utf8)).isEmpty)
    #expect(parser.feed(Array("ta: {}\n".utf8)).isEmpty)
    #expect(parser.feed(Array("\n".utf8)) == [SSEEvent(event: "ready", data: "{}")])
  }

  @Test("ServerEvent ignores unknown event names")
  func unknownEvent() throws {
    #expect(try ServerEvent.decode(SSEEvent(event: "memo.deleted", data: "{}")) == nil)
  }

  @Test("ServerEvent reports a malformed payload")
  func malformedPayload() {
    #expect(throws: APIError.self) { try ServerEvent.decode(SSEEvent(event: "memo.updated", data: "{")) }
  }
}
