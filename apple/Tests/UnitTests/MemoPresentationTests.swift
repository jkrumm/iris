import IrisCore
import IrisUI
import Testing

@testable import Iris

@Suite("Memo presentation")
struct MemoPresentationTests {
  @Test(
    "audio lengths read as seconds, minutes and hours",
    arguments: [
      (38.4, "38 s"), (132.0, "2 min 12 s"), (2_460.0, "41 min"), (3_900.0, "1 h 5 min"), (7_200.0, "2 h"),
    ])
  func durations(seconds: Double, expected: String) {
    #expect(DurationText.string(seconds: seconds) == expected)
  }

  @Test("the route is where the memo went, a tab by its name, the mode only before routing")
  func routeLabel() {
    #expect(MemoFactory.memo("a", route: "hermes").routeLabel == "Hermes")
    #expect(MemoFactory.memo("a", route: "journal").routeLabel == "Journal")
    #expect(MemoFactory.memo("a", route: "tab", destinationRef: "docs").routeLabel == "docs")
    #expect(MemoFactory.memo("a", route: "herdr", destinationRef: "dotfiles").routeLabel == "dotfiles")
    #expect(MemoFactory.memo("a", mode: .auto).routeLabel == "Auto")
  }

  @Test("the headline is the summary's; without one it is the transcript on one line, clipped to 60 characters")
  func headlineFallback() {
    let summary = MemoSummary(headline: "Release am Donnerstag", detail: "d", spoken: "s")
    #expect(MemoFactory.memo("a", transcript: "ignored", summary: summary).rowHeadline == "Release am Donnerstag")
    #expect(MemoFactory.memo("a", transcript: "Kurz und gut").rowHeadline == "Kurz und gut")
    #expect(MemoFactory.memo("a", transcript: "Zwei\nZeilen  mit   Lücken").rowHeadline == "Zwei Zeilen mit Lücken")

    let long = String(repeating: "wort ", count: 30)
    let clipped = MemoFactory.memo("a", transcript: long).rowHeadline
    #expect(clipped.count <= Memo.headlineLimit + 1)
    #expect(clipped.hasSuffix("…"))
    #expect(!clipped.contains("  "))
    #expect(MemoFactory.memo("a", transcript: String(repeating: "x", count: 60)).rowHeadline.count == 60)
  }

  @Test("a settled memo shows route and audio length, no cost")
  func settledStatus() {
    let memo = MemoFactory.memo("a", route: "hermes", audioSeconds: 38.4)
    #expect(memo.rowStatus == .settled(route: "Hermes", dot: memo.routeDotColor, duration: "38 s"))
    #expect(
      MemoFactory.memo("a", route: "journal").rowStatus
        == .settled(route: "Journal", dot: MemoFactory.memo("a", route: "journal").routeDotColor, duration: nil))
  }

  @Test("a memo that needs the user replaces the route with the coloured state")
  func alertStatus() {
    #expect(
      MemoFactory.memo("a", state: .needsRoute).rowStatus == .alert(label: "Needs route", color: Theme.Status.warn))
    #expect(
      MemoFactory.memo("a", state: .failed, failedStep: .summarize).rowStatus
        == .alert(label: "Failed · summarize", color: Theme.Status.bad))
  }

  @Test("a memo the pipeline is driving says Acting next to its route")
  func inFlightStatus() {
    let memo = MemoFactory.memo("a", state: .acted, route: "hermes")
    #expect(
      memo.rowStatus
        == .inFlight(
          route: "Hermes", dot: memo.routeDotColor, label: "Acting", progress: StepProgress(completed: 3, total: 5)))
    #expect(MemoFactory.memo("a", state: .received).rowStatus.isInFlight)
  }

  @Test(
    "the dashes count the steps the state says are done",
    arguments: [
      (MemoState.receiving, 0), (.received, 0), (.transcribed, 1), (.needsRoute, 1), (.routed, 2), (.acted, 3),
      (.summarized, 4), (.notified, 5),
    ])
  func stepProgress(state: MemoState, completed: Int) {
    #expect(MemoFactory.memo("a", state: state).stepProgress == StepProgress(completed: completed, total: 5))
  }

  @Test("the secondary line: failure hint, parked hint, else the summary's first line")
  func secondaryLine() {
    let failed = MemoFactory.memo(
      "a", state: .failed, failedStep: .summarize, error: "agw job failed (upstream 503)", transcript: "Prompt an Tab")
    #expect(failed.rowSecondary == "agw job failed (upstream 503) — retry from summarize")

    // Without a transcript the error is the headline, so the secondary line is only the hint.
    let noTranscript = Memo(
      id: "b", mode: .auto, device: "iphone", startedAt: MemoFactory.now, state: .failed, failedStep: .transcribe,
      error: "transcribe failed: 502", createdAt: MemoFactory.now, updatedAt: MemoFactory.now)
    #expect(noTranscript.rowSecondary == "retry from transcribe")

    #expect(MemoFactory.memo("a", state: .needsRoute).rowSecondary == "Tap to decide")

    let summary = MemoSummary(headline: "H", detail: "Montag PR-Review\nMittwoch Feature-Freeze", spoken: "s")
    #expect(MemoFactory.memo("a", summary: summary).rowSecondary == "Montag PR-Review")
    #expect(MemoFactory.memo("a").rowSecondary == nil)
  }

  @Test("a typed memo's pipeline skips transcribe, a spoken one runs every step")
  func applicableSteps() {
    #expect(PipelineSteps.applicable(to: MemoFactory.memo("a")) == [.transcribe, .route, .act, .summarize, .notify])
    #expect(PipelineSteps.applicable(to: MemoFactory.memo("t", typed: true)) == [.route, .act, .summarize, .notify])
  }
}

extension HistoryRowStatus {
  fileprivate var isInFlight: Bool {
    if case .inFlight = self { true } else { false }
  }
}
