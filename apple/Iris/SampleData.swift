import Foundation
import IrisCore

/// Five placeholder memos shaped like `contracts/fixtures` (German and English, five pipeline states), dated
/// relative to `now` so the history reads naturally. Shared with the Mac target until the real client lands.
enum SampleData {
  static func details(now: Date = Date()) -> [MemoDetail] {
    [
      MemoDetail(
        memo: Memo(
          id: "e41a8c73-2b9d-4f06-8d35-6a7b0c1e9f22", mode: .auto, device: "iphone",
          startedAt: now.addingTimeInterval(-150), state: .received, segmentCount: 3,
          createdAt: now.addingTimeInterval(-149), updatedAt: now.addingTimeInterval(-120)),
        steps: []),
      MemoDetail(
        memo: Memo(
          id: "2f8d5b06-9c1e-4a73-b4d8-0e6a3c7f1d95", mode: .auto, device: "iphone",
          startedAt: now.addingTimeInterval(-1_500), state: .needsRoute, segmentCount: 2, audioSeconds: 14.9,
          transcript: "Schreib das bitte in mein Journal und gib mir morgen früh eine Zusammenfassung.",
          createdAt: now.addingTimeInterval(-1_499), updatedAt: now.addingTimeInterval(-1_480)),
        steps: [
          StepEntry(
            step: .transcribe, status: .done, startedAt: now.addingTimeInterval(-1_495),
            finishedAt: now.addingTimeInterval(-1_487), costUsd: 0.0015)
        ]),
      MemoDetail(
        memo: Memo(
          id: "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-5_400), state: .notified, segmentCount: 4, audioSeconds: 38.4,
          transcript:
            "Erinnere mich bitte daran, am Montag die offenen Pull Requests durchzugehen, am Mittwoch den Feature-Freeze zu machen und am Donnerstag das Release zu bauen.",
          route: "hermes", destinationRef: "iris-0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34",
          replyText: "Alles notiert. Montag: Pull Requests prüfen. Mittwoch: Feature-Freeze. Donnerstag: Release.",
          summary: MemoSummary(
            headline: "Wochenplan abgestimmt, Release am Donnerstag",
            detail: "Montag Review der offenen Pull Requests, Mittwoch Feature-Freeze, Donnerstag Release.",
            spoken: "Der Wochenplan steht. Release ist am Donnerstag."),
          createdAt: now.addingTimeInterval(-5_399), updatedAt: now.addingTimeInterval(-5_360)),
        steps: timeline(
          from: now.addingTimeInterval(-5_395),
          [
            (.transcribe, 8.5, 0.0038), (.route, 0.012, nil), (.act, 11.4, 0.0412), (.summarize, 5.7, 0.0021),
            (.notify, 1.9, nil),
          ])),
      MemoDetail(
        memo: Memo(
          id: "5a1c7e92-8d3f-4b60-a2e4-9c0b1d6f3a77", mode: .tab, device: "iphone",
          startedAt: now.addingTimeInterval(-26_000), state: .notified, segmentCount: 2, audioSeconds: 21.7,
          transcript: "Tell the docs tab to add a short troubleshooting section for the background upload retries.",
          route: "tab", destinationRef: "docs",
          replyText: "Sent to the docs tab. It is adding a troubleshooting section for upload retries.",
          summary: MemoSummary(
            headline: "Docs tab adds a troubleshooting section for upload retries",
            detail: "The request was forwarded to the docs tab, which is drafting the section.",
            spoken: "The docs tab is adding a troubleshooting section."),
          createdAt: now.addingTimeInterval(-25_999), updatedAt: now.addingTimeInterval(-25_960)),
        steps: []),
      MemoDetail(
        memo: Memo(
          id: "7c9e2a10-5d4b-4e8f-a3b6-1f0d9c2e4a58", mode: .journal, device: "iphone",
          startedAt: now.addingTimeInterval(-90_000), state: .failed, failedStep: .transcribe,
          error: "transcribe failed: 502", segmentCount: 3,
          createdAt: now.addingTimeInterval(-89_999), updatedAt: now.addingTimeInterval(-89_970)),
        steps: [
          StepEntry(
            step: .transcribe, status: .failed, startedAt: now.addingTimeInterval(-89_995),
            finishedAt: now.addingTimeInterval(-89_970), error: "transcribe failed: 502")
        ]),
      // In flight: summarize is running, so History shows three finished dashes and the detail a live bar.
      MemoDetail(
        memo: Memo(
          id: "3d7b9a41-6e20-4c85-b1f3-8a4e2c6d0f19", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-26), state: .acted, segmentCount: 2, audioSeconds: 9.8,
          transcript: "Which Postgres index fits the herd snapshot query?", route: "hermes",
          destinationRef: "iris-3d7b9a41-6e20-4c85-b1f3-8a4e2c6d0f19",
          replyText: "A **partial index** on `(repo, last_activity)` covers it.",
          createdAt: now.addingTimeInterval(-25), updatedAt: now.addingTimeInterval(-11)),
        steps: timeline(
          from: now.addingTimeInterval(-24), [(.transcribe, 3.2, 0.0012), (.route, 0.01, nil), (.act, 9.5, 0.0301)])
          + [StepEntry(step: .summarize, status: .running, startedAt: now.addingTimeInterval(-10.5))]),
      // Failed at summarize: the detail offers a retry from that step.
      MemoDetail(
        memo: Memo(
          id: "9e2c4b70-1a58-4d36-8f07-5b3a6d1c8e24", mode: .tab, device: "iphone",
          startedAt: now.addingTimeInterval(-3_200), state: .failed, failedStep: .summarize,
          error: "agw job failed: upstream 503", segmentCount: 1, audioSeconds: 14.2,
          transcript: "An Tab dotfiles: ergänze bitte xcodegen im Brewfile und lass danach make check laufen.",
          route: "tab", destinationRef: "dotfiles",
          createdAt: now.addingTimeInterval(-3_199), updatedAt: now.addingTimeInterval(-3_180)),
        steps: timeline(
          from: now.addingTimeInterval(-3_195), [(.transcribe, 3.1, 0.0012), (.route, 0.009, nil), (.act, 2.2, nil)])
          + [
            StepEntry(
              step: .summarize, status: .failed, startedAt: now.addingTimeInterval(-3_189.5),
              finishedAt: now.addingTimeInterval(-3_182.5), error: "agw job failed: upstream 503", attempts: 3)
          ]),
    ]
  }

  /// Back-to-back finished steps starting at `start`: (step, seconds, cost), each 70 ms after the one before.
  private static func timeline(from start: Date, _ steps: [(MemoStep, Double, Double?)]) -> [StepEntry] {
    var cursor = start
    return steps.map { step, seconds, cost in
      defer { cursor = cursor.addingTimeInterval(seconds + 0.07) }
      return StepEntry(
        step: step, status: .done, startedAt: cursor, finishedAt: cursor.addingTimeInterval(seconds), costUsd: cost)
    }
  }

  /// What "usual" means for the sample memos: the Hermes steps have enough samples to compare against, the tab
  /// route's summarize median does not (three samples), so the failed memo shows no faster/slower tags. The volume
  /// rows cover the last 56 days ending at `now` with a made-up but steady rhythm (busier on weekdays, Chat started
  /// three weeks ago), so the Stats tab has something to draw.
  static func stats(now: Date = Date(), windowDays: Int = 56) -> Stats {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = .gmt
    let key: (Date) -> String = { $0.formatted(.iso8601.year().month().day().dateSeparator(.dash)) }
    let days = (0..<windowDays).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }

    var perDay: [StatsDayCount] = []
    var weeks: [String: Int] = [:]
    for (index, day) in days.enumerated() {
      let weekday = calendar.component(.weekday, from: day)
      let weekend = weekday == 1 || weekday == 7
      let rhythm = [(0, 3), (1, 2), (2, 1)]
      for (offset, base) in rhythm {
        let count = max(0, (base + (index * (offset + 2) + offset) % 3 - 1) - (weekend ? 2 : 0))
        guard count > 0 else { continue }
        perDay.append(StatsDayCount(date: key(day), route: ["hermes", "journal", "tab"][offset], count: count))
        let monday = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        weeks[key(monday), default: 0] += count
      }
    }
    return Stats(
      days: windowDays, from: days.first.map(key) ?? "", to: key(now), perDay: perDay,
      perWeek: weeks.keys.sorted().map { StatsWeekCount(weekStart: $0, count: weeks[$0] ?? 0) },
      stepMedians: [
        StatsStepMedian(step: .transcribe, route: "hermes", medianMs: 7_900, samples: 30),
        StatsStepMedian(step: .route, route: "hermes", medianMs: 11, samples: 30),
        StatsStepMedian(step: .act, route: "hermes", medianMs: 8_200, samples: 30),
        StatsStepMedian(step: .summarize, route: "hermes", medianMs: 6_900, samples: 30),
        StatsStepMedian(step: .notify, route: "hermes", medianMs: 2_100, samples: 30),
        StatsStepMedian(step: .summarize, route: "tab", medianMs: 6_800, samples: 3),
      ],
      costPerRoute: [
        StatsRouteCost(route: "hermes", costUsd: 1.18, memos: 64),
        StatsRouteCost(route: "journal", costUsd: 0.31, memos: 41),
        StatsRouteCost(route: "tab", costUsd: 0.13, memos: 22),
      ])
  }

  /// Fills a `FakeAPIClient` with the sample memos.
  static func seed(_ client: FakeAPIClient) async {
    for detail in details() {
      await client.seed(detail)
    }
    await client.setStats(stats())
  }
}
