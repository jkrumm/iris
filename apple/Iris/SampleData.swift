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
        steps: [
          StepEntry(
            step: .transcribe, status: .done, startedAt: now.addingTimeInterval(-5_395),
            finishedAt: now.addingTimeInterval(-5_387), costUsd: 0.0038)
        ]),
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
    ]
  }

  /// Fills a `FakeAPIClient` with the sample memos.
  static func seed(_ client: FakeAPIClient) async {
    for detail in details() {
      await client.seed(detail)
    }
  }
}
