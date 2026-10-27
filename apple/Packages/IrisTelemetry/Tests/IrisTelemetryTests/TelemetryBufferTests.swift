import Foundation
import Testing

@testable import IrisTelemetry

struct TelemetryBufferTests {
  @Test func drainReturnsOldestFirstInBatches() async {
    let buffer = TelemetryBuffer(capacity: 10)
    for index in 1...5 { await buffer.record(span: Fixtures.span(index)) }

    let first = await buffer.drain(max: 2)
    let second = await buffer.drain(max: 2)
    let third = await buffer.drain(max: 2)
    let empty = await buffer.drain(max: 2)

    #expect(first.entries == [.span(Fixtures.span(1)), .span(Fixtures.span(2))])
    #expect(second.entries == [.span(Fixtures.span(3)), .span(Fixtures.span(4))])
    #expect(third.entries == [.span(Fixtures.span(5))])
    #expect(empty.isEmpty)
  }

  @Test func spansAndLogsShareOneOrderedQueue() async {
    let buffer = TelemetryBuffer(capacity: 10)
    await buffer.record(span: Fixtures.span(1))
    await buffer.record(log: Fixtures.log(2))
    await buffer.record(span: Fixtures.span(3))

    let drain = await buffer.drain(max: 10)
    #expect(drain.entries == [.span(Fixtures.span(1)), .log(Fixtures.log(2)), .span(Fixtures.span(3))])
  }

  @Test func overflowDropsOldestAndCountsIntoNextDrain() async {
    let buffer = TelemetryBuffer(capacity: 3)
    for index in 1...5 { await buffer.record(span: Fixtures.span(index)) }

    #expect(await buffer.pendingCount == 3)
    #expect(await buffer.unreportedDropCount == 2)

    let drain = await buffer.drain(max: 10)
    #expect(drain.entries == (3...5).map { .span(Fixtures.span($0)) })
    #expect(drain.dropped == 2)

    let next = await buffer.drain(max: 10)
    #expect(next.dropped == 0)
    #expect(await buffer.unreportedDropCount == 0)
  }

  @Test func droppedCountAloneMakesADrainNonEmpty() async {
    let buffer = TelemetryBuffer(capacity: 1)
    await buffer.record(span: Fixtures.span(1))
    await buffer.record(span: Fixtures.span(2))
    _ = await buffer.drain(max: 1)
    await buffer.record(span: Fixtures.span(3))
    await buffer.record(span: Fixtures.span(4))
    _ = await buffer.drain(max: 1)

    let drain = await buffer.drain(max: 10)
    #expect(drain.entries.isEmpty)
    #expect(drain.dropped == 0)
    #expect(drain.isEmpty)
  }

  @Test func requeueRestoresOrderAheadOfNewerRecords() async {
    let buffer = TelemetryBuffer(capacity: 10)
    for index in 1...4 { await buffer.record(span: Fixtures.span(index)) }
    let failed = await buffer.drain(max: 2)
    await buffer.record(span: Fixtures.span(5))

    await buffer.requeue(failed)

    let retry = await buffer.drain(max: 10)
    #expect(retry.entries == [1, 2, 3, 4, 5].map { .span(Fixtures.span($0)) })
  }

  @Test func requeueRestoresTheDroppedCount() async {
    let buffer = TelemetryBuffer(capacity: 3)
    for index in 1...4 { await buffer.record(span: Fixtures.span(index)) }
    let failed = await buffer.drain(max: 2)
    #expect(failed.dropped == 1)
    #expect(await buffer.unreportedDropCount == 0)

    await buffer.requeue(failed)

    let retry = await buffer.drain(max: 10)
    #expect(retry.entries == [2, 3, 4].map { .span(Fixtures.span($0)) })
    #expect(retry.dropped == 1)
  }

  @Test func requeueBeyondCapacityDropsTheOldest() async {
    let buffer = TelemetryBuffer(capacity: 2)
    await buffer.record(span: Fixtures.span(1))
    await buffer.record(span: Fixtures.span(2))
    let failed = await buffer.drain(max: 2)
    await buffer.record(span: Fixtures.span(3))
    await buffer.record(span: Fixtures.span(4))

    await buffer.requeue(failed)

    let retry = await buffer.drain(max: 10)
    #expect(retry.entries == [3, 4].map { .span(Fixtures.span($0)) })
    #expect(retry.dropped == 2)
  }

  @Test func storeFailuresNeverReachTheCaller() async {
    let buffer = TelemetryBuffer(capacity: 2, store: FailingStore())
    await buffer.recover()
    await buffer.record(span: Fixtures.span(1))
    let drain = await buffer.drain(max: 10)
    await buffer.acknowledge(drain)
    #expect(drain.entries == [.span(Fixtures.span(1))])
  }
}
