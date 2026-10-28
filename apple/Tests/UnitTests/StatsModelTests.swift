import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("StatsModel")
struct StatsModelTests {
  let client = FakeAPIClient()
  let model: StatsModel

  init() {
    model = StatsModel(client: client)
  }

  @Test("a load asks for the whole window once and serves both granularities from it")
  func loads() async {
    await client.setStats(SampleData.stats())
    #expect(model.report == nil)
    await model.load()
    #expect(model.report?.granularity == .days)
    model.granularity = .weeks
    #expect(model.report?.granularity == .weeks)
    #expect(await client.calls == [.stats(StatsQuery(days: StatsReport.windowDays))])
  }

  @Test("a failed first load is an error state, a failed refresh keeps the numbers")
  func failures() async {
    await client.enqueueFailure(.unexpectedStatus(500), for: .stats)
    await model.load()
    #expect(model.loadFailed)
    #expect(model.report == nil)

    await client.setStats(SampleData.stats())
    await model.load()
    #expect(!model.loadFailed)
    #expect(model.report != nil)

    await client.enqueueFailure(.unexpectedStatus(500), for: .stats)
    await model.load()
    #expect(model.loadFailed)
    #expect(model.report != nil)
  }

  @Test("a stale load never overwrites a newer one")
  func staleLoad() async {
    await client.setStats(SampleData.stats())
    let gate = await client.hold(.stats)
    let stale = Task { await model.load() }
    defer { gate.release() }
    guard await waitUntilHeld(gate) else { return }

    // The held call has read the sample numbers; the newer load sees an empty window and answers first.
    await client.setStats(Stats(days: 30, from: "1970-01-01", to: "1970-01-30"))
    await model.load()
    #expect(model.stats?.perDay.isEmpty == true)
    gate.release()
    await stale.value
    #expect(model.stats?.perDay.isEmpty == true)
    #expect(!model.isLoading)
  }
}
