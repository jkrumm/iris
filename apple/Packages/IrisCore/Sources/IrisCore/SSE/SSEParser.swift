import Foundation

/// One dispatched server-sent event. `event` defaults to `message` when the stream names none; `data`
/// joins multiple `data:` lines with `\n`.
public struct SSEEvent: Hashable, Sendable {
  public var event: String
  public var data: String

  public init(event: String, data: String) {
    self.event = event
    self.data = data
  }
}

/// An incremental `text/event-stream` parser. Feed it bytes in chunks of any size (a line, an event or a
/// single byte may be split anywhere); it returns the events completed by each chunk. Lines end in LF,
/// CRLF or CR, `:` lines are comments (keepalives), `id` and `retry` are ignored (the server has no
/// replay), and an event with no `data:` line is not dispatched. A trailing partial event is dropped, as
/// the SSE specification requires.
public struct SSEParser: Sendable {
  private static let lineFeed = UInt8(ascii: "\n")
  private static let carriageReturn = UInt8(ascii: "\r")
  private static let colon = UInt8(ascii: ":")
  private static let space = UInt8(ascii: " ")

  private var pending: [UInt8] = []
  private var eventName = ""
  private var dataLines: [String] = []

  public init() {}

  public mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
    pending.append(contentsOf: bytes)
    var events: [SSEEvent] = []
    var lineStart = 0
    var index = 0
    while index < pending.count {
      let byte = pending[index]
      guard byte == Self.lineFeed || byte == Self.carriageReturn else {
        index += 1
        continue
      }
      let lineEnd = index
      index += 1
      if byte == Self.carriageReturn {
        // A CR at the end of the buffer may be the first half of a CRLF: wait for the next byte.
        guard index < pending.count else { break }
        if pending[index] == Self.lineFeed { index += 1 }
      }
      if let event = consumeLine(pending[lineStart..<lineEnd]) { events.append(event) }
      lineStart = index
    }
    pending.removeSubrange(0..<lineStart)
    return events
  }

  private mutating func consumeLine(_ line: ArraySlice<UInt8>) -> SSEEvent? {
    guard let first = line.first else { return dispatch() }
    if first == Self.colon { return nil }
    let name: ArraySlice<UInt8>
    var value: ArraySlice<UInt8>
    if let colon = line.firstIndex(of: Self.colon) {
      name = line[line.startIndex..<colon]
      value = line[(colon + 1)...]
      if value.first == Self.space { value = value.dropFirst() }
    } else {
      name = line
      value = []
    }
    switch String(decoding: name, as: UTF8.self) {
    case "event": eventName = String(decoding: value, as: UTF8.self)
    case "data": dataLines.append(String(decoding: value, as: UTF8.self))
    default: break
    }
    return nil
  }

  private mutating func dispatch() -> SSEEvent? {
    defer {
      eventName = ""
      dataLines = []
    }
    guard !dataLines.isEmpty else { return nil }
    return SSEEvent(event: eventName.isEmpty ? "message" : eventName, data: dataLines.joined(separator: "\n"))
  }
}
