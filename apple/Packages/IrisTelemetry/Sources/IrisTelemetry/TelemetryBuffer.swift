import Foundation
import os

/// What `TelemetryBuffer.drain` hands to the exporter: the oldest entries plus the overflow count to report.
public struct TelemetryDrain: Hashable, Sendable {
  public let items: [StoredEntry]
  public let dropped: Int

  public init(items: [StoredEntry], dropped: Int) {
    self.items = items
    self.dropped = dropped
  }

  public var entries: [TelemetryEntry] { items.map(\.entry) }
  public var isEmpty: Bool { items.isEmpty && dropped == 0 }
}

extension TelemetryBatch {
  /// Splits a drain into spans and logs, keeping buffer order within each list.
  public init(resource: TelemetryResource, drain: TelemetryDrain) {
    var spans: [SpanRecord] = []
    var logs: [LogRecord] = []
    for entry in drain.entries {
      switch entry {
      case .span(let span): spans.append(span)
      case .log(let log): logs.append(log)
      }
    }
    self.init(resource: resource, spans: spans, logs: logs, dropped: drain.dropped)
  }
}

/// Bounded in-memory queue of spans and logs, mirrored to a `TelemetryStore` so a crash loses nothing recorded.
///
/// Overflow drops the oldest entry and counts it; the count rides on the next drain. Persistence failures are logged
/// and never surface to callers. At-least-once: entries stay in the store until `acknowledge`, so a crash mid-send
/// re-sends them after `recover()`.
public actor TelemetryBuffer {
  private let capacity: Int
  private let store: any TelemetryStore
  private var pending: [StoredEntry] = []
  private var droppedCount = 0
  private var nextSequence: UInt64 = 1
  private var droppedSinceTrim = 0
  private var newestDroppedSequence: UInt64 = 0
  private var drainInFlight = false
  private var hasRecovered = false

  public init(capacity: Int, store: any TelemetryStore = InMemoryTelemetryStore()) {
    self.capacity = max(1, capacity)
    self.store = store
  }

  public var pendingCount: Int { pending.count }

  /// Overflow drops not yet reported in a drain.
  public var unreportedDropCount: Int { droppedCount }

  public func record(span: SpanRecord) async {
    await enqueue(.span(span))
  }

  public func record(log: LogRecord) async {
    await enqueue(.log(log))
  }

  /// Removes and returns up to `max` of the oldest entries and resets the dropped counter into the result. The
  /// entries stay in the store until `acknowledge`; call `requeue` instead when delivery failed.
  public func drain(max limit: Int) -> TelemetryDrain {
    let items = Array(pending.prefix(Swift.max(0, limit)))
    pending.removeFirst(items.count)
    let dropped = droppedCount
    droppedCount = 0
    drainInFlight = !items.isEmpty
    return TelemetryDrain(items: items, dropped: dropped)
  }

  /// Puts a failed drain back in front of anything recorded since, preserving order, and restores its dropped count.
  public func requeue(_ drain: TelemetryDrain) {
    drainInFlight = false
    pending.insert(contentsOf: drain.items, at: 0)
    droppedCount += drain.dropped
    enforceCapacity()
  }

  /// Marks a drain as delivered and removes it from the store.
  public func acknowledge(_ drain: TelemetryDrain) async {
    drainInFlight = false
    guard let newest = drain.items.last?.sequence else { return }
    do {
      try await store.removeThrough(sequence: newest)
    } catch {
      Logger.telemetry.error("Telemetry store cleanup failed: \(String(describing: type(of: error)), privacy: .public)")
    }
  }

  /// Loads what a previous run left in the store. Call once at launch, before recording; later calls do nothing.
  /// Entries beyond capacity are dropped oldest-first and counted.
  public func recover() async {
    guard !hasRecovered else { return }
    hasRecovered = true
    do {
      let loaded = try await store.load()
      guard let newest = loaded.last?.sequence else { return }
      pending = loaded + pending
      nextSequence = Swift.max(nextSequence, newest + 1)
      enforceCapacity()
      await trimStoreIfNeeded()
    } catch {
      Logger.telemetry.error("Telemetry recovery failed: \(String(describing: type(of: error)), privacy: .public)")
    }
  }

  private func enqueue(_ entry: TelemetryEntry) async {
    let item = StoredEntry(sequence: nextSequence, entry: entry)
    nextSequence += 1
    pending.append(item)
    enforceCapacity()
    do {
      try await store.append([item])
    } catch {
      Logger.telemetry.error("Telemetry store append failed: \(String(describing: type(of: error)), privacy: .public)")
    }
    await trimStoreIfNeeded()
  }

  private func enforceCapacity() {
    while pending.count > capacity {
      let dropped = pending.removeFirst()
      droppedCount += 1
      droppedSinceTrim += 1
      newestDroppedSequence = Swift.max(newestDroppedSequence, dropped.sequence)
    }
  }

  /// Keeps the store near twice the capacity while offline: overflow-dropped entries are removed in bulk. Skipped
  /// while a drain is in flight so its entries stay on disk until acknowledged.
  private func trimStoreIfNeeded() async {
    guard droppedSinceTrim >= capacity, !drainInFlight else { return }
    droppedSinceTrim = 0
    do {
      try await store.removeThrough(sequence: newestDroppedSequence)
    } catch {
      Logger.telemetry.error("Telemetry store trim failed: \(String(describing: type(of: error)), privacy: .public)")
    }
  }
}
