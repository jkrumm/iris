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

  @Test("an older pinned memo gets its own header above Today")
  func pinnedFromAnOlderDay() {
    let memos = [MemoFactory.memo("parked", age: 3 * day), MemoFactory.memo("a", age: 0)]
    #expect(HistoryDaySection.group(memos, calendar: calendar).map { $0.memos.map(\.id) } == [["parked"], ["a"]])
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
