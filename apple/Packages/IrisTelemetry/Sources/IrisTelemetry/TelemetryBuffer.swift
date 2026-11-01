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
///
/// **The store is read once before it is written.** The first record waits for the first recovery attempt (so it is numbered
/// after the stored entries). If that attempt fails (a file readable only after the first unlock), the records of this run are
/// memory-only: no append, no trim, no removal by sequence, because the store cannot say which sequences it holds. The next
/// successful load renumbers them above the stored maximum, persists them, and only then is the buffer recovered; a failed
/// persist leaves it unrecovered and the next `recover()` tries again.
public actor TelemetryBuffer {
  private let capacity: Int
  private let store: any TelemetryStore
  private var pending: [StoredEntry] = []
  private var droppedCount = 0
  private var nextSequence: UInt64 = 1
  private var droppedSinceTrim = 0
  private var newestDroppedSequence: UInt64 = 0
  private var drainInFlight = false
  /// The store has been read and this run's records are in it: from here on the buffer mirrors every change.
  private var recovered = false
  private var hasAttempted = false
  /// The recovery attempt running now; a second caller waits for it.
  private var recovery: Task<Void, Never>?

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
    guard recovered, let newest = drain.items.last?.sequence else { return }
    do {
      try await store.removeThrough(sequence: newest)
    } catch {
      Logger.telemetry.error("Telemetry store cleanup failed: \(String(describing: type(of: error)), privacy: .public)")
    }
  }

  /// Loads what a previous run left in the store. Call at launch, before recording. Concurrent calls share one attempt and
  /// all return after it; once it succeeded later calls do nothing, and after a failed one (a locked file) the next call
  /// tries again. Entries beyond capacity are dropped oldest-first and counted.
  public func recover() async {
    if recovered { return }
    if let running = recovery {
      await running.value
      return
    }
    hasAttempted = true
    let task = Task { await self.attemptRecovery() }
    recovery = task
    await task.value
  }

  private func attemptRecovery() async {
    defer { recovery = nil }
    let loaded: [StoredEntry]
    do {
      loaded = try await store.load()
    } catch {
      Logger.telemetry.error("Telemetry recovery failed: \(String(describing: type(of: error)), privacy: .public)")
      return
    }
    // A send holds entries numbered in this run's own sequence; renumbering now would make its acknowledgement remove the
    // wrong ones. Recovery is retried by the next flush, which starts with none in flight.
    guard !drainInFlight else { return }
    let base = loaded.map(\.sequence).max() ?? 0
    // This run's records, above everything stored. Nothing is changed until they are in the store.
    var next = base + 1
    let mine = pending.map { item -> StoredEntry in
      defer { next += 1 }
      return StoredEntry(sequence: next, entry: item.entry)
    }
    if !mine.isEmpty {
      do {
        try await store.append(mine)
      } catch {
        Logger.telemetry.error(
          "Telemetry store append failed: \(String(describing: type(of: error)), privacy: .public)")
        return
      }
    }
    pending = loaded + mine
    nextSequence = next
    // The memory-only overflow of the unread period was never in the store, so there is nothing of it to trim.
    droppedSinceTrim = 0
    newestDroppedSequence = 0
    recovered = true
    enforceCapacity()
    await trimStoreIfNeeded()
  }

  /// The first record waits for the first recovery attempt, and any record for one in progress: numbering it earlier would
  /// reuse a stored sequence.
  private func settleRecovery() async {
    if !hasAttempted { await recover() }
    while let running = recovery { await running.value }
  }

  private func enqueue(_ entry: TelemetryEntry) async {
    await settleRecovery()
    let item = StoredEntry(sequence: nextSequence, entry: entry)
    nextSequence += 1
    pending.append(item)
    enforceCapacity()
    // Memory only until the store has been read (and `recovered` never goes back to false, so this holds below).
    guard recovered else { return }
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
  /// while a drain is in flight so its entries stay on disk until acknowledged, and until the store has been read.
  private func trimStoreIfNeeded() async {
    guard recovered, droppedSinceTrim >= capacity, !drainInFlight else { return }
    droppedSinceTrim = 0
    do {
      try await store.removeThrough(sequence: newestDroppedSequence)
    } catch {
      Logger.telemetry.error("Telemetry store trim failed: \(String(describing: type(of: error)), privacy: .public)")
    }
  }
}
