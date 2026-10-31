#if os(macOS)
  import Foundation
  import Synchronization

  /// One source, any number of independent consumers. An `AsyncStream` has one consumer: a second reader takes every other
  /// element, and the first reader that stops (a cancelled task, a finished take) ends the stream for everyone. Here every
  /// ``subscribe()`` is its own stream with its own buffer, so a consumer that goes away takes nothing with it, and the next
  /// take subscribes again. A value yielded while nobody is subscribed is dropped.
  public final class Broadcast<Element: Sendable>: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    public init() {}

    /// A new stream of everything yielded from now on. It keeps the newest `buffer` values a slow consumer has not read.
    public func subscribe(buffer: Int = 1) -> AsyncStream<Element> {
      let id = UUID()
      return AsyncStream(bufferingPolicy: .bufferingNewest(buffer)) { continuation in
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
          _ = self?.subscribers.withLock { $0.removeValue(forKey: id) }
        }
      }
    }

    public func yield(_ value: Element) {
      let current = subscribers.withLock { Array($0.values) }
      for continuation in current { continuation.yield(value) }
    }
  }
#endif
