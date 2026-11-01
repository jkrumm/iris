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
  /// The recovery running now; a second caller waits for it instead of returning early (a flush must not start before the
  /// stored queue is in, nor a record be numbered before it).
  private var recovery: Task<Void, Never>?
  /// The last recovery could not read the store (the phone has not been unlocked since boot, so the file's protection class
  /// refuses the read). Records stay in memory and are numbered above anything the file can hold; the next `recover()` retries.
  private var storeUnreadable = false

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
    // Nothing of this run is in a store that could not be read, and a removal by sequence would also take the older entries
    // that recovery has not loaded yet.
    guard !storeUnreadable else { return }
    do {
      try await store.removeThrough(sequence: newest)
    } catch {
      Logger.telemetry.error("Telemetry store cleanup failed: \(String(describing: type(of: error)), privacy: .public)")
    }
  }

  /// Loads what a previous run left in the store. Call at launch, before recording. Concurrent calls share one load and
  /// all return after it; once it succeeded later calls do nothing, and after a failed one (a locked file) the next call
  /// tries again. Entries beyond capacity are dropped oldest-first and counted.
  public func recover() async {
    if hasRecovered { return }
    if let running = recovery {
      await running.value
      return
    }
    let task = Task { await self.loadStore() }
    recovery = task
    await task.value
  }

  private func loadStore() async {
    defer { recovery = nil }
    do {
      let loaded = try await store.load()
      hasRecovered = true
      if storeUnreadable {
        // The records of this run were numbered high while the file was out of reach; the file's own are all lower.
        storeUnreadable = false
        await persistPending()
      }
      guard let newest = loaded.last?.sequence else { return }
      let known = Set(pending.map(\.sequence))
      pending = loaded.filter { !known.contains($0.sequence) } + pending
      nextSequence = Swift.max(nextSequence, newest + 1)
      enforceCapacity()
      await trimStoreIfNeeded()
    } catch {
      Logger.telemetry.error("Telemetry recovery failed: \(String(describing: type(of: error)), privacy: .public)")
      markStoreUnreadable()
    }
  }

  /// A store that cannot be read cannot say which sequences it holds: continue far above any a run could have written
  /// (milliseconds since 1970 is above every counter and above any earlier run's own bump), so a later `removeThrough`
  /// never reaches an older entry through a reused number.
  private func markStoreUnreadable() {
    guard !storeUnreadable else { return }
    storeUnreadable = true
    let base = UInt64(Swift.max(0, Date().timeIntervalSince1970 * 1000)) << 8
    guard base > nextSequence else { return }
    nextSequence = base
    pending = pending.map { item in
      defer { nextSequence += 1 }
      return StoredEntry(sequence: nextSequence, entry: item.entry)
    }
  }

  /// Writes what was held in memory while the store was out of reach.
  private func persistPending() async {
    do {
      try await store.append(pending)
    } catch {
      Logger.telemetry.error("Telemetry store append failed: \(String(describing: type(of: error)), privacy: .public)")
    }
  }

  private func enqueue(_ entry: TelemetryEntry) async {
    // A load in progress finishes first: a record numbered before it would reuse a stored sequence.
    if let running = recovery { await running.value }
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
