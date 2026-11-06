import Foundation
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

  @Test("a known kind reads by its catalog name, in any case and padding")
  func knownKindLabel() {
    for kind in ["answer", "task", "note", "github issue", "chat"] {
      let name = KindPalette.localizedName(forKind: kind)
      #expect(name != nil)
      #expect(Memo.capitalizedKind(kind) == name)
      #expect(Memo.capitalizedKind("  \(kind.uppercased()) ") == name)
      #expect(MemoFactory.memo("a", kind: kind).kindLabel == name)
    }
    #expect(KindPalette.localizedName(forKind: "deep dive") == nil)
    #expect(KindPalette.normalized("  Github Issue ") == "github issue")
  }

  @Test("an unknown kind is Hermes' kind with its first letter upper-cased, at most 24 code points")
  func kindLabel() {
    #expect(MemoFactory.memo("a", kind: "deep dive").kindLabel == "Deep dive")
    #expect(MemoFactory.memo("a", kind: "tab Prompt").kindLabel == "Tab Prompt")
    let long = String(repeating: "x", count: 40)
    #expect(MemoFactory.memo("a", kind: long).kindLabel == "X" + String(repeating: "x", count: 23))
    #expect(Memo.capitalizedKind("éclair").hasPrefix("É"))
  }

  @Test("a memo without a kind reads its old route, a tab by its name")
  func oldRouteLabel() {
    #expect(MemoFactory.memo("a", route: "hermes").kindLabel == "Hermes")
    #expect(MemoFactory.memo("a", route: "journal").kindLabel == "Journal")
    #expect(MemoFactory.memo("a", route: "chat").kindLabel == "Chat")
    #expect(MemoFactory.memo("a", route: "tab", destinationRef: "docs").kindLabel == "docs")
    #expect(MemoFactory.memo("a", route: "herdr", destinationRef: "dotfiles").kindLabel == "dotfiles")
    #expect(MemoFactory.memo("a", route: "tab").kindLabel == "Tab")
    #expect(
      MemoFactory.memo("a", route: "journal", kind: "deep dive").kindLabel == "Deep dive", "a kind wins over a route")
  }

  @Test("a transcript-only memo is Transcript, a Hermes memo not yet classified is Hermes")
  func transcriptAndInFlightLabels() {
    let memo = MemoFactory.memo("a", mode: .transcribe)
    #expect(memo.kindLabel == "Transcript")
    #expect(memo.kindIcon == "text.alignleft")
    #expect(memo.kindDotColor == Theme.Ink.faint)
    let flying = MemoFactory.memo("a", state: .received)
    #expect(flying.kindLabel == "Hermes")
    #expect(flying.kindIcon == "tag.fill")
  }

  @Test("the kind dot follows the palette")
  func kindDot() {
    #expect(MemoFactory.memo("a", kind: "task").kindDotColor == KindPalette.color(forKind: "task"))
    #expect(MemoFactory.memo("a", kind: "research").kindDotColor == Theme.Ink.faint)
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

  @Test("a long headline is cut at a word boundary, never inside a word")
  func headlineWordBoundary() {
    let text = "Pull Request für das neue Retry-Fenster der Outbox schreiben und danach mit Hermes besprechen"
    let clipped = Memo.clipped(text)
    #expect(clipped == "Pull Request für das neue Retry-Fenster der Outbox schreiben…")
    #expect(clipped.count <= Memo.headlineLimit + 1)
    // A cut that lands exactly between two words keeps the whole last word.
    let exact = String(repeating: "x", count: Memo.headlineLimit - 4) + " abc def"
    #expect(Memo.clipped(exact) == String(repeating: "x", count: Memo.headlineLimit - 4) + " abc…")
    // One unbroken word longer than the limit has no boundary to cut at.
    #expect(Memo.clipped(String(repeating: "x", count: 80)) == String(repeating: "x", count: 60) + "…")
  }

  @Test("every mode has a glyph of its own")
  func modeGlyphsAreDistinct() {
    let modes = MemoMode.allCases
    #expect(Set(modes.map(\.recordIcon)).count == modes.count)
  }

  @Test("a settled memo shows its kind and audio length, no cost")
  func settledStatus() {
    let memo = MemoFactory.memo("a", audioSeconds: 38.4, kind: "task")
    #expect(memo.rowStatus == .settled(kind: "Task", dot: memo.kindDotColor, duration: "38 s"))
    let old = MemoFactory.memo("a", route: "journal")
    #expect(old.rowStatus == .settled(kind: "Journal", dot: old.kindDotColor, duration: nil))
  }

  @Test("a failed memo replaces the kind with the coloured state")
  func alertStatus() {
    #expect(
      MemoFactory.memo("a", state: .failed, failedStep: .summarize).rowStatus
        == .alert(label: "Failed · Summarize", color: Theme.Status.bad))
  }

  @Test("an old memo parked at needs_route reads as a plain, neutral status with no route prompt")
  func oldNeedsRoute() {
    let memo = MemoFactory.memo("a", state: .needsRoute, done: true)
    #expect(memo.rowStatus == .alert(label: "Not delivered", color: Theme.Status.neutral))
    #expect(memo.rowSecondary == nil)
    #expect(MemoState.needsRoute.label == "Not delivered")
  }

  @Test("a memo the pipeline is driving says Acting next to its kind")
  func inFlightStatus() {
    let memo = MemoFactory.memo("a", state: .acted, kind: "answer")
    #expect(
      memo.rowStatus
        == .inFlight(
          kind: "Answer", dot: memo.kindDotColor, label: "Acting", progress: StepProgress(completed: 2, total: 3)))
    #expect(MemoFactory.memo("a", state: .received).rowStatus.isInFlight)
  }

  @Test(
    "the dashes count the steps the state says are done",
    arguments: [
      (MemoState.receiving, 0), (.received, 0), (.transcribed, 1), (.routed, 1), (.acted, 2), (.summarized, 2),
      (.notified, 3),
    ])
  func stepProgress(state: MemoState, completed: Int) {
    #expect(MemoFactory.memo("a", state: state).stepProgress == StepProgress(completed: completed, total: 3))
  }

  @Test("the secondary line: failure hint, else the summary's first line")
  func secondaryLine() {
    let failed = MemoFactory.memo(
      "a", state: .failed, failedStep: .summarize, error: "agw job failed (upstream 503)", transcript: "Prompt an Tab")
    #expect(failed.rowSecondary == "agw job failed (upstream 503) — retry from Summarize")

    // Without a transcript the error is the headline, so the secondary line is only the hint.
    let noTranscript = Memo(
      id: "b", mode: .hermes, device: "iphone", startedAt: MemoFactory.now, state: .failed, failedStep: .transcribe,
      error: "transcribe failed: 502", createdAt: MemoFactory.now, updatedAt: MemoFactory.now)
    #expect(noTranscript.rowSecondary == "retry from Transcribe")

    let summary = MemoSummary(headline: "H", detail: "Montag PR-Review\nMittwoch Feature-Freeze", spoken: "s")
    #expect(MemoFactory.memo("a", summary: summary).rowSecondary == "Montag PR-Review")
    #expect(MemoFactory.memo("a").rowSecondary == nil)
  }

  @Test("a typed memo's pipeline skips transcribe, a spoken one runs every step")
  func applicableSteps() {
    #expect(PipelineSteps.applicable(to: MemoFactory.memo("a")) == [.transcribe, .act, .notify])
    #expect(PipelineSteps.applicable(to: MemoFactory.memo("t", typed: true)) == [.act, .notify])
    #expect(
      PipelineSteps.legacy(for: MemoFactory.memo("a", route: "hermes"))
        == [.transcribe, .route, .act, .summarize, .notify])
  }

  @Test("a transcribe memo reads as its transcript: Transcript chip, no reply or summary line")
  func transcribeMemo() {
    let memo = MemoFactory.memo(
      "a", mode: .transcribe, audioSeconds: 17.3, transcript: "Ideen für das Wochenende: früh los zum See")
    #expect(memo.kindLabel == "Transcript")
    #expect(memo.rowHeadline == "Ideen für das Wochenende: früh los zum See")
    #expect(memo.rowSecondary == nil)
    #expect(memo.rowStatus == .settled(kind: "Transcript", dot: memo.kindDotColor, duration: "17 s"))
  }

  @Test("a transcribe memo goes through transcribe and notify only, and its dashes count two")
  func transcribeSteps() {
    let spoken = MemoFactory.memo("a", mode: .transcribe)
    #expect(PipelineSteps.applicable(to: spoken) == [.transcribe, .notify])
    #expect(PipelineSteps.applicable(to: MemoFactory.memo("t", mode: .transcribe, typed: true)) == [.notify])
    #expect(
      MemoFactory.memo("a", state: .received, mode: .transcribe).stepProgress == StepProgress(completed: 0, total: 2))
    #expect(
      MemoFactory.memo("a", state: .transcribed, mode: .transcribe).stepProgress == StepProgress(completed: 1, total: 2)
    )
    #expect(spoken.stepProgress == StepProgress(completed: 2, total: 2))
  }

  @Test("a retired or unknown mode decodes to Hermes")
  func modeDecoding() throws {
    for raw in ["auto", "chat", "journal", "tab", "something new", "hermes"] {
      let data = Data("\"\(raw)\"".utf8)
      #expect(try JSONDecoder().decode(MemoMode.self, from: data) == .hermes)
    }
    #expect(try JSONDecoder().decode(MemoMode.self, from: Data("\"transcribe\"".utf8)) == .transcribe)
  }

  @Test("the record row names Hermes and Transcribe with an icon each")
  func recordRowModes() {
    #expect(MemoMode.hermes.recordTitle == "Hermes" && MemoMode.hermes.recordIcon == "sparkles")
    #expect(MemoMode.transcribe.recordTitle == "Transcribe" && MemoMode.transcribe.recordIcon == "text.alignleft")
  }
}

extension HistoryRowStatus {
  fileprivate var isInFlight: Bool {
    if case .inFlight = self { true } else { false }
  }
}
