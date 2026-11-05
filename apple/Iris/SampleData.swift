import Foundation
import IrisCore

/// Placeholder memos shaped like `contracts/fixtures` (German and English), dated relative to `now` so the history reads
/// naturally: memos Hermes classified (a kind and the tools it ran, the pipeline transcribe, act, notify), a transcript-only
/// memo, a failed one, one in flight, and old memos from before Hermes decides (a route, no kind, a summary and the
/// route and summarize steps). Shared with the Mac target until the real client lands.
enum SampleData {
  static func details(now: Date = Date()) -> [MemoDetail] {
    baseDetails(now: now).map(inOwnSession)
      + threadDetails(now: now).flatMap(\.memos).map { MemoDetail(memo: $0, steps: []) }
  }

  /// What `act` does to a Hermes memo: its own session id becomes its `threadId`. An old routed memo to another destination
  /// and a memo that has not reached `act` have none.
  private static func inOwnSession(_ detail: MemoDetail) -> MemoDetail {
    var detail = detail
    let memo = detail.memo
    guard memo.threadId == nil, memo.destinationRef != nil, memo.route == nil || memo.route == "hermes" else {
      return detail
    }
    detail.memo.threadId = memo.id
    return detail
  }

  private static func baseDetails(now: Date) -> [MemoDetail] {
    [
      MemoDetail(
        memo: Memo(
          id: "e41a8c73-2b9d-4f06-8d35-6a7b0c1e9f22", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-150), state: .received, segmentCount: 3,
          createdAt: now.addingTimeInterval(-149), updatedAt: now.addingTimeInterval(-120)),
        steps: []),
      // A task Hermes captured: kind and the tool it used, no summary (the headline is the transcript).
      MemoDetail(
        memo: Memo(
          id: "2f8d5b06-9c1e-4a73-b4d8-0e6a3c7f1d95", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-1_500), state: .notified, segmentCount: 2, audioSeconds: 14.9,
          transcript: "Schreib das bitte in mein Journal und gib mir morgen früh eine Zusammenfassung.",
          replyText: "Ist im Journal. Die Zusammenfassung bekommst du morgen früh.", kind: "task",
          actions: ["capture"], createdAt: now.addingTimeInterval(-1_499), updatedAt: now.addingTimeInterval(-1_470)),
        steps: timeline(
          from: now.addingTimeInterval(-1_495), [(.transcribe, 8.0, 0.0015), (.act, 12.4, 0.0390), (.notify, 0.4, nil)])
      ),
      // Failed at `act`: the detail offers a retry from that step.
      MemoDetail(
        memo: Memo(
          id: "9e2c4b70-1a58-4d36-8f07-5b3a6d1c8e24", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-3_200), state: .failed, failedStep: .act,
          error: "hermes request failed: upstream 503", segmentCount: 1, audioSeconds: 14.2,
          transcript: "An Tab dotfiles: ergänze bitte xcodegen im Brewfile und lass danach make check laufen.",
          createdAt: now.addingTimeInterval(-3_199), updatedAt: now.addingTimeInterval(-3_180)),
        steps: timeline(from: now.addingTimeInterval(-3_195), [(.transcribe, 3.1, 0.0012)])
          + [
            StepEntry(
              step: .act, status: .failed, startedAt: now.addingTimeInterval(-3_191.8),
              finishedAt: now.addingTimeInterval(-3_182.5), error: "hermes request failed: upstream 503", attempts: 3)
          ]),
      // An old memo (before Hermes decides): the route it went to, a summary, and the route and summarize steps.
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
      // Old, finished without a summary: summarize failed for good, the memo still ends done (the step is optional).
      MemoDetail(
        memo: Memo(
          id: "4e8a2c7d-91b3-4f06-8d5a-3b7e1c9f2a60", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-7_200), state: .notified, segmentCount: 4, audioSeconds: 38.4,
          transcript:
            "Erinnere mich bitte daran, am Montag die offenen Pull Requests durchzugehen, am Mittwoch den Feature-Freeze zu machen und am Donnerstag das Release zu bauen. Die Datenbankmigration ist noch offen.",
          route: "hermes", destinationRef: "iris-4e8a2c7d-91b3-4f06-8d5a-3b7e1c9f2a60",
          replyText: "Alles notiert. Montag: Pull Requests prüfen. Mittwoch: Feature-Freeze. Donnerstag: Release.",
          createdAt: now.addingTimeInterval(-7_199), updatedAt: now.addingTimeInterval(-7_160)),
        steps: timeline(
          from: now.addingTimeInterval(-7_195),
          [(.transcribe, 8.5, 0.0038), (.route, 0.012, nil), (.act, 11.4, 0.0412)])
          + [
            StepEntry(
              step: .summarize, status: .failed, startedAt: now.addingTimeInterval(-7_174),
              finishedAt: now.addingTimeInterval(-7_171), error: "agw triage failed: 402 payment required",
              attempts: 3),
            StepEntry(
              step: .notify, status: .done, startedAt: now.addingTimeInterval(-7_170.9),
              finishedAt: now.addingTimeInterval(-7_170)),
          ]),
      // Two tools: Hermes opened an issue.
      MemoDetail(
        memo: Memo(
          id: "b7e41d92-3c05-4a86-9f2d-6e1a8b4c0d73", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-9_000), state: .notified, segmentCount: 2, audioSeconds: 17.3,
          transcript: "Mach ein GitHub-Issue auf: der Upload-Retry bleibt nach einem Neustart hängen.",
          replyText: "Issue angelegt: **Upload-Retry hängt nach Neustart**. Ich habe es dem Backlog zugeordnet.",
          kind: "github issue", actions: ["terminal", "github"], createdAt: now.addingTimeInterval(-8_999),
          updatedAt: now.addingTimeInterval(-8_960)),
        steps: timeline(
          from: now.addingTimeInterval(-8_995), [(.transcribe, 6.1, 0.0021), (.act, 19.8, 0.0630), (.notify, 0.5, nil)])
      ),
      // A plain answer: Hermes used no tool.
      MemoDetail(
        memo: Memo(
          id: "c2f05a38-7d19-4b64-a8e3-0f5c1d9b2e46", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-12_000), state: .notified, segmentCount: 1, audioSeconds: 5.4,
          transcript: "Wie viele Segmente hat eine Minute Aufnahme?",
          replyText: "Sechs: ein Segment dauert zehn Sekunden.", kind: "answer",
          createdAt: now.addingTimeInterval(-11_999),
          updatedAt: now.addingTimeInterval(-11_980)),
        steps: timeline(
          from: now.addingTimeInterval(-11_995), [(.transcribe, 3.2, 0.0010), (.act, 4.1, 0.0120), (.notify, 0.3, nil)])
      ),
      // A kind outside the known colors.
      MemoDetail(
        memo: Memo(
          id: "d4a96c17-2b83-4e05-b7f1-9a3e6c0d5f82", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-15_000), state: .notified, segmentCount: 3, audioSeconds: 22.0,
          transcript: "Recherchiere, wie andere Apps ihre Aufnahme nach einem Anruf wieder aufnehmen.",
          replyText: "Drei Muster: Sitzung neu aktivieren, Engine neu bauen, den Take beenden und neu starten.",
          kind: "research", actions: ["web", "terminal"], createdAt: now.addingTimeInterval(-14_999),
          updatedAt: now.addingTimeInterval(-14_900)),
        steps: timeline(
          from: now.addingTimeInterval(-14_995),
          [(.transcribe, 7.0, 0.0028), (.act, 82.0, 0.2100), (.notify, 0.6, nil)])),
      // Transcript only: no kind, no route, no act.
      MemoDetail(
        memo: Memo(
          id: "e8b3d2f0-4a17-4c59-8d60-1b7f3a9e5c24", mode: .transcribe, device: "iphone",
          startedAt: now.addingTimeInterval(-20_000), state: .notified, segmentCount: 2, audioSeconds: 12.6,
          transcript: "Nur ein Gedanke für später: die Aufnahme beim Anruf nicht abbrechen, sondern pausieren.",
          createdAt: now.addingTimeInterval(-19_999), updatedAt: now.addingTimeInterval(-19_980)),
        steps: timeline(from: now.addingTimeInterval(-19_995), [(.transcribe, 5.0, 0.0020), (.notify, 0.4, nil)])),
      // Old, routed to a tab: the route name is the chip, the destination its name.
      MemoDetail(
        memo: Memo(
          id: "5a1c7e92-8d3f-4b60-a2e4-9c0b1d6f3a77", mode: .hermes, device: "iphone",
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
          id: "a9d2e6c4-1f38-4b70-9c85-2e4a7d0b3f61", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-30_000), state: .notified, segmentCount: 1, audioSeconds: 6.8,
          transcript: "Notiz: Die Keynote beginnt am Donnerstag um zehn.",
          replyText: "Notiert.", kind: "note", actions: ["capture"], createdAt: now.addingTimeInterval(-29_999),
          updatedAt: now.addingTimeInterval(-29_980)),
        steps: timeline(
          from: now.addingTimeInterval(-29_995), [(.transcribe, 3.4, 0.0011), (.act, 6.2, 0.0180), (.notify, 0.4, nil)])
      ),
      // Old, routed to the journal.
      MemoDetail(
        memo: Memo(
          id: "f1c7a5b9-6e24-4d83-8a10-3c9b0e5d7f28", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-50_000), state: .notified, segmentCount: 2, audioSeconds: 19.1,
          transcript: "Tagebuch: heute lange spazieren gewesen und den Kopf freibekommen.",
          route: "journal", destinationRef: "2027-01-14.md",
          summary: MemoSummary(
            headline: "Spaziergang im Tagebuch notiert", detail: "Ein Eintrag für heute.", spoken: "Eingetragen."),
          createdAt: now.addingTimeInterval(-49_999), updatedAt: now.addingTimeInterval(-49_960)),
        steps: []),
      MemoDetail(
        memo: Memo(
          id: "7c9e2a10-5d4b-4e8f-a3b6-1f0d9c2e4a58", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-90_000), state: .failed, failedStep: .transcribe,
          error: "transcribe failed: 502", segmentCount: 3,
          createdAt: now.addingTimeInterval(-89_999), updatedAt: now.addingTimeInterval(-89_970)),
        steps: [
          StepEntry(
            step: .transcribe, status: .failed, startedAt: now.addingTimeInterval(-89_995),
            finishedAt: now.addingTimeInterval(-89_970), error: "transcribe failed: 502")
        ]),
      // In flight: notify is running, so History shows two finished dashes and the detail a live bar.
      MemoDetail(
        memo: Memo(
          id: "3d7b9a41-6e20-4c85-b1f3-8a4e2c6d0f19", mode: .hermes, device: "iphone",
          startedAt: now.addingTimeInterval(-26), state: .acted, segmentCount: 2, audioSeconds: 9.8,
          transcript: "Which Postgres index fits the herd snapshot query?",
          replyText: "A **partial index** on `(repo, last_activity)` covers it.", kind: "answer",
          createdAt: now.addingTimeInterval(-25), updatedAt: now.addingTimeInterval(-11)),
        steps: timeline(from: now.addingTimeInterval(-24), [(.transcribe, 3.2, 0.0012), (.act, 9.5, 0.0301)])
          + [StepEntry(step: .notify, status: .running, startedAt: now.addingTimeInterval(-10.5))]),
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

  /// What "usual" means for the sample memos: the answer steps have enough samples to compare against, the task act
  /// median does not (three samples), so a task shows no faster/slower tag. The volume rows cover the last 56 days ending
  /// at `now` with a made-up but steady rhythm (busier on weekdays; five kinds and transcripts, so Other shows), so the
  /// Stats tab has something to draw.
  static func stats(now: Date = Date(), windowDays: Int = 56) -> Stats {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = .gmt
    let key: (Date) -> String = { $0.formatted(.iso8601.year().month().day().dateSeparator(.dash)) }
    let days = (0..<windowDays).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }

    var perDay: [StatsDayCount] = []
    var weeks: [String: Int] = [:]
    func add(_ day: Date, _ kind: String?, _ count: Int) {
      guard count > 0 else { return }
      perDay.append(StatsDayCount(date: key(day), kind: kind, count: count))
      let monday = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
      weeks[key(monday), default: 0] += count
    }
    for (index, day) in days.enumerated() {
      let weekday = calendar.component(.weekday, from: day)
      let weekend = weekday == 1 || weekday == 7
      let rhythm = [(0, 3), (1, 2), (2, 1)]
      for (offset, base) in rhythm {
        add(
          day, ["answer", "task", "note"][offset], (base + (index * (offset + 2) + offset) % 3 - 1) - (weekend ? 2 : 0))
      }
      if index % 3 == 0 { add(day, "github issue", 1) }
      if index % 5 == 0 { add(day, "research", 1) }
      if index % 4 == 0 { add(day, nil, 1) }
    }
    return Stats(
      days: windowDays, from: days.first.map(key) ?? "", to: key(now), perDay: perDay,
      perWeek: weeks.keys.sorted().map { StatsWeekCount(weekStart: $0, count: weeks[$0] ?? 0) },
      stepMedians: [
        StatsStepMedian(step: .transcribe, kind: "answer", medianMs: 7_900, samples: 30),
        StatsStepMedian(step: .act, kind: "answer", medianMs: 8_200, samples: 30),
        StatsStepMedian(step: .notify, kind: "answer", medianMs: 2_100, samples: 30),
        StatsStepMedian(step: .act, kind: "task", medianMs: 12_800, samples: 3),
        StatsStepMedian(step: .transcribe, kind: nil, medianMs: 7_000, samples: 12),
        StatsStepMedian(step: .notify, kind: nil, medianMs: 400, samples: 12),
      ],
      costPerKind: [
        StatsKindCost(kind: "answer", costUsd: 1.18, memos: 64),
        StatsKindCost(kind: "task", costUsd: 0.31, memos: 41),
        StatsKindCost(kind: "note", costUsd: 0.13, memos: 22),
        StatsKindCost(kind: "github issue", costUsd: 0.27, memos: 19),
        StatsKindCost(kind: "research", costUsd: 0.62, memos: 12),
        StatsKindCost(kind: nil, costUsd: 0.04, memos: 14),
      ])
  }

  /// Fills a `FakeAPIClient` with the sample memos.
  static func seed(_ client: FakeAPIClient, now: Date = Date()) async {
    for detail in details(now: now) {
      await client.seed(detail)
    }
    for thread in threadDetails(now: now) {
      await client.seed(thread)
    }
    await client.setStats(stats(now: now))
  }

  /// The launch argument that pins the sample clock (`-IrisSampleNow 2027-01-15T12:00:00Z`), so UI tests see the same
  /// History whatever time of day they run: the sample memos are relative to it, and a memo from 90 minutes ago is
  /// on another day for the first hour and a half after midnight.
  static let nowArgument = "-IrisSampleNow"

  static func now(arguments: [String], fallback: Date = Date()) -> Date {
    guard let index = arguments.firstIndex(of: nowArgument), arguments.indices.contains(index + 1),
      let pinned = try? Date(arguments[index + 1], strategy: .iso8601)
    else { return fallback }
    return pinned
  }
}
