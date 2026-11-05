import Foundation
import IrisCore
import Testing

@testable import Iris

@Suite("HistoryDaySection")
struct HistorySectionsTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  private let hour: TimeInterval = 3_600
  private let day: TimeInterval = 86_400

  @Test("memos group into runs of one day, in list order")
  func groups() {
    let memos = [
      MemoFactory.memo("a", age: 0), MemoFactory.memo("b", age: hour), MemoFactory.memo("c", age: day),
      MemoFactory.memo("d", age: 3 * day),
    ]
    let sections = HistoryDaySection.group(memos, calendar: calendar)
    #expect(sections.map { $0.memos.map(\.id) } == [["a", "b"], ["c"], ["d"]])
  }

  @Test("two runs of the same day get distinct section ids")
  func runsOfTheSameDayDoNotShareAnID() {
    // A list that is not strictly newest first: yesterday, today, yesterday again.
    let memos = [
      MemoFactory.memo("x", age: day + hour), MemoFactory.memo("a", age: 0), MemoFactory.memo("b", age: hour),
      MemoFactory.memo("c", age: day), MemoFactory.memo("d", age: day + 2 * hour),
    ]
    let sections = HistoryDaySection.group(memos, calendar: calendar)
    #expect(sections.map { $0.memos.map(\.id) } == [["x"], ["a", "b"], ["c", "d"]])
    #expect(Set(sections.map(\.id)).count == sections.count, "SwiftUI drops rows of sections that share an id")
    #expect(sections.map(\.id) == HistoryDaySection.group(memos, calendar: calendar).map(\.id), "ids are stable")
  }

  @Test("a pinned sample clock comes from the launch arguments, else the real one")
  func sampleClock() {
    let fallback = Date(timeIntervalSince1970: 5)
    #expect(SampleData.now(arguments: [], fallback: fallback) == fallback)
    #expect(
      SampleData.now(arguments: ["-IrisFakeCapture", "-IrisSampleNow", "2027-01-15T12:00:00Z"], fallback: fallback)
        == Date(timeIntervalSince1970: 1_800_014_400))
    #expect(SampleData.now(arguments: ["-IrisSampleNow", "not a date"], fallback: fallback) == fallback)
    #expect(SampleData.now(arguments: ["-IrisSampleNow"], fallback: fallback) == fallback)
  }

  @Test("titles read Today, Yesterday, then the date")
  func titles() {
    let now = MemoFactory.now
    let sections = HistoryDaySection.group(
      [MemoFactory.memo("a"), MemoFactory.memo("b", age: day), MemoFactory.memo("c", age: 3 * day)], calendar: calendar)
    let titles = sections.map { $0.title(now: now, calendar: calendar) }
    #expect(titles[0] == "Today")
    #expect(titles[1] == "Yesterday")
    #expect(!titles[2].isEmpty && titles[2] != "Today" && titles[2] != "Yesterday")
  }

  @Test("the subtitle counts today's memos and sums their audio")
  func subtitle() {
    let memos = [
      MemoFactory.memo("a", audioSeconds: 38.4), MemoFactory.memo("b", age: hour, audioSeconds: 253.6),
      MemoFactory.memo("old", age: 2 * day, audioSeconds: 600),
    ]
    #expect(
      HistoryDaySection.subtitle(for: memos, now: MemoFactory.now, calendar: calendar)
        == "2 memos today · 4 min 52 s of audio")
  }

  @Test("the subtitle leaves out audio when there is none, says memo once and is absent without today's memos")
  func subtitleEdges() {
    #expect(
      HistoryDaySection.subtitle(for: [MemoFactory.memo("a")], now: MemoFactory.now, calendar: calendar)
        == "1 memo today")
    #expect(
      HistoryDaySection.subtitle(for: [MemoFactory.memo("a", age: 2 * day)], now: MemoFactory.now, calendar: calendar)
        == nil)
    #expect(HistoryDaySection.subtitle(for: [], now: MemoFactory.now, calendar: calendar) == nil)
  }
}

@MainActor
@Suite("HistoryModel sections")
struct HistoryModelSectionsTests {
  @Test("the model keeps the day sections and row ids of its list, grouped once per change")
  func sectionsFollowTheList() async {
    let client = FakeAPIClient(now: { MemoFactory.now })
    for memo in [
      MemoFactory.memo("old", age: 90_000), MemoFactory.memo("a", age: 10),
      MemoFactory.memo("b", age: 20),
    ] {
      await client.seed(MemoFactory.detail(memo))
    }
    let model = HistoryModel(client: client)
    #expect(model.sections.isEmpty && model.memoIDs.isEmpty)

    await model.load()
    #expect(model.memoIDs == ["a", "b", "old"])
    #expect(model.sections.flatMap(\.memos).map(\.id) == model.memoIDs, "the sections are the list, in order")
    #expect(Set(model.sections.map(\.id)).count == model.sections.count)

    let memoA = model.memos[0]
    await model.toggleFavorite(memoA)
    #expect(model.sections.flatMap(\.memos).first { $0.id == "a" }?.favorite == true, "a flag change reaches the rows")
    #expect(model.memoIDs == ["a", "b", "old"], "and does not look like a reorder")
  }

  @Test("a long list groups in one pass and keeps list order inside a day")
  func longListKeepsOrder() {
    let memos = (0..<2_000).map { MemoFactory.memo("m\($0)", age: TimeInterval($0)) }
    let sections = HistoryDaySection.group(memos)
    #expect(sections.flatMap(\.memos).map(\.id) == memos.map(\.id))
    #expect(sections.count <= 2, "two thousand seconds span at most two calendar days")
  }
}
