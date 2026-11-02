import Foundation
import IrisCore

/// A run of consecutive memos from one calendar day. History is already newest first (pinned rows on top), so the
/// sections follow the list order: a pinned memo from an older day gets its own header above Today.
struct HistoryDaySection: Identifiable {
  /// The day alone is not an identity: a pinned memo from yesterday and yesterday's own memos are two sections of the same
  /// day, with today's in between. `occurrence` counts the sections of that day in list order (0 for the first).
  struct ID: Hashable {
    let day: Date
    let occurrence: Int
  }

  let day: Date
  let occurrence: Int
  let memos: [Memo]

  var id: ID { ID(day: day, occurrence: occurrence) }

  static func group(_ memos: [Memo], calendar: Calendar = .current) -> [HistoryDaySection] {
    // Runs are filled in place and turned into sections once: no array is copied per row.
    var runs: [(day: Date, occurrence: Int, memos: [Memo])] = []
    var occurrences: [Date: Int] = [:]
    for memo in memos {
      let day = calendar.startOfDay(for: memo.createdAt)
      if let last = runs.indices.last, runs[last].day == day {
        runs[last].memos.append(memo)
      } else {
        let occurrence = occurrences[day, default: 0]
        occurrences[day] = occurrence + 1
        runs.append((day, occurrence, [memo]))
      }
    }
    return runs.map { HistoryDaySection(day: $0.day, occurrence: $0.occurrence, memos: $0.memos) }
  }

  func title(now: Date = Date(), calendar: Calendar = .current) -> String {
    Self.title(of: day, now: now, calendar: calendar)
  }

  /// "Today", "Yesterday", else "Mon 2 Nov": a day's name wherever one is shown (History's headers, a thread's dividers).
  static func title(of day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today", comment: "History day header") }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
      return String(localized: "Yesterday", comment: "History day header")
    }
    return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
  }

  /// "6 memos today · 4 min 52 s of audio", counted over the memos in the list; `nil` when none is from today.
  static func subtitle(for memos: [Memo], now: Date = Date(), calendar: Calendar = .current) -> String? {
    let today = memos.filter { calendar.isDate($0.createdAt, inSameDayAs: now) }
    guard !today.isEmpty else { return nil }
    let count =
      today.count == 1
      ? String(localized: "1 memo today", comment: "History subtitle")
      : String(localized: "\(today.count) memos today", comment: "History subtitle")
    let audio = today.compactMap(\.audioSeconds).reduce(0, +)
    guard audio >= 1 else { return count }
    let length = DurationText.string(seconds: audio)
    return String(localized: "\(count) · \(length) of audio", comment: "History subtitle: memo count, audio length")
  }
}
