import IrisTelemetry

/// What `app.launch` and `outbox.state` say about the queue. An outbox that cannot be opened (before the first unlock) or read
/// has no item count: reporting zero would read as "nothing is waiting" exactly when something may be.
nonisolated enum OutboxStateRecord {
  static func attributes(available: Bool, unreadable: Bool, items: Int, quarantined: Int) -> [String: AttributeValue] {
    var attributes: [String: AttributeValue] = [
      "outbox.state": .string(available ? "available" : unreadable ? "unreadable" : "unavailable"),
      "outbox.quarantined_files": .int(quarantined),
    ]
    if available { attributes["outbox.items"] = .int(items) }
    return attributes
  }
}
