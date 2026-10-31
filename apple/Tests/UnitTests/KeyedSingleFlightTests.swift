import Synchronization
import Testing

@testable import Iris

@MainActor
@Suite("KeyedSingleFlight")
struct KeyedSingleFlightTests {
  @Test("a call with the running key joins the job instead of running another")
  func sameKeyJoins() async {
    let flight = KeyedSingleFlight<String>()
    let runs = Mutex(0)
    async let first: Void = flight.run(key: "a") {
      runs.withLock { $0 += 1 }
      try? await Task.sleep(for: .milliseconds(100))
    }
    while runs.withLock({ $0 }) == 0 { await Task.yield() }
    await flight.run(key: "a") { runs.withLock { $0 += 1 } }
    await first
    #expect(runs.withLock { $0 } == 1)
  }

  @Test("a call with another key cancels the running job and does not wait for it")
  func otherKeyReplaces() async {
    let flight = KeyedSingleFlight<String>()
    let started = Mutex(false)
    let cancelled = Mutex(false)
    async let old: Void = flight.run(key: "old") {
      started.withLock { $0 = true }
      // Stalled until cancelled, as a lookup to a server that no longer answers.
      do { try await Task.sleep(for: .seconds(60)) } catch { cancelled.withLock { $0 = true } }
    }
    while !started.withLock({ $0 }) { await Task.yield() }
    let ran = Mutex(false)
    await flight.run(key: "new") { ran.withLock { $0 = true } }
    await old
    #expect(ran.withLock { $0 })
    #expect(cancelled.withLock { $0 })
  }
}
