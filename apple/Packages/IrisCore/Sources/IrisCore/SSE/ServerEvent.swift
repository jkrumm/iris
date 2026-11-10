import Foundation
import os

/// A typed `GET /v1/events` event.
public enum ServerEvent: Hashable, Sendable {
  case ready
  case memoUpdated(MemoEvent)
  case memoDone(MemoEvent)
  /// The next piece of the reply while `act` runs; a new `attempt` means `act` restarted.
  case memoDelta(MemoDelta)
  /// A tool Hermes started while `act` runs.
  case memoActivity(MemoActivity)

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
    case "memo.delta":
      return .memoDelta(try decodePayload(event))
    case "memo.activity":
      return .memoActivity(try decodePayload(event))
    default:
      return nil
    }
  }

  /// ``decode(_:)`` for a live stream: an event that does not decode (a state or step a newer server added, while this build is
  /// old) is logged and skipped, so one event never ends the stream, which would reconnect and reload the list every few seconds.
  public static func decodeSkippingMalformed(_ event: SSEEvent) -> ServerEvent? {
    do {
      return try decode(event)
    } catch {
      Logger(subsystem: "com.jkrumm.iris", category: "events")
        .error(
          "skipped an undecodable \(event.event, privacy: .public) event: \(String(describing: error), privacy: .public)"
        )
      return nil
    }
  }

  private static func decodePayload<Payload: Decodable>(_ event: SSEEvent) throws -> Payload {
    do {
      return try IrisJSON.makeDecoder().decode(Payload.self, from: Data(event.data.utf8))
    } catch {
      throw APIError.decoding("\(event.event): \(error.localizedDescription)")
    }
  }
}
