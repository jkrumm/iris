import IrisTelemetry
import Testing

@testable import Iris

@Suite("OutboxStateRecord")
struct OutboxStateRecordTests {
  @Test("an open queue reports its items")
  func available() {
    let attributes = OutboxStateRecord.attributes(available: true, unreadable: false, items: 3, quarantined: 1)
    #expect(attributes["outbox.state"] == "available")
    #expect(attributes["outbox.items"] == 3)
  }

  @Test("a queue that cannot be opened or read has no item count, not zero")
  func unavailable() {
    let closed = OutboxStateRecord.attributes(available: false, unreadable: false, items: 0, quarantined: 0)
    #expect(closed["outbox.state"] == "unavailable")
    #expect(closed["outbox.items"] == nil)
    let broken = OutboxStateRecord.attributes(available: false, unreadable: true, items: 0, quarantined: 2)
    #expect(broken["outbox.state"] == "unreadable")
    #expect(broken["outbox.items"] == nil)
    #expect(broken["outbox.quarantined_files"] == 2)
  }
}
