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
}
