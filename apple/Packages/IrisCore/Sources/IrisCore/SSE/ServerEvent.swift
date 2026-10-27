import Foundation

/// A typed `GET /v1/events` event.
public enum ServerEvent: Hashable, Sendable {
  case ready
  case memoUpdated(MemoEvent)
  case memoDone(MemoEvent)

  /// Decodes a dispatched SSE event. Returns `nil` for event names this client does not know, so a newer
  /// server can add events without breaking the stream. Throws `APIError.decoding` for a malformed payload.
  public static func decode(_ event: SSEEvent) throws -> ServerEvent? {
    switch event.event {
    case "ready":
      return .ready
    case "memo.updated":
      return .memoUpdated(try decodePayload(event))
    case "memo.done":
      return .memoDone(try decodePayload(event))
    default:
      return nil
    }
  }

  private static func decodePayload(_ event: SSEEvent) throws -> MemoEvent {
    do {
      return try IrisJSON.makeDecoder().decode(MemoEvent.self, from: Data(event.data.utf8))
    } catch {
      throw APIError.decoding("\(event.event): \(error.localizedDescription)")
    }
  }
}
