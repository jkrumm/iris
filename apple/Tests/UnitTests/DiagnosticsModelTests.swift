import IrisCore
import Testing

@testable import Iris

final class FakePasteboard: Pasteboard {
  private(set) var copied: [String] = []
  func copy(_ text: String) { copied.append(text) }
}

@MainActor
@Suite("DiagnosticsModel")
struct DiagnosticsModelTests {
  let pasteboard = FakePasteboard()
  let model: DiagnosticsModel
  let memos = [
    MemoFactory.memo("old", age: 900), MemoFactory.memo("new", age: 10), MemoFactory.memo("mid", age: 300),
  ]

  init() {
    model = DiagnosticsModel(pasteboard: pasteboard)
  }

  @Test("the newest memo is selected until another is picked")
  func defaultSelection() {
    #expect(model.recent(memos).map(\.id) == ["new", "mid", "old"])
    #expect(model.selectedMemo(in: memos)?.id == "new")
    model.selectedID = "old"
    #expect(model.selectedMemo(in: memos)?.id == "old")
    model.selectedID = "gone"
    #expect(model.selectedMemo(in: memos)?.id == "new")
  }

  @Test("copying puts the selected memo's id on the pasteboard and confirms until cleared")
  func copy() {
    model.copyID(from: memos)
    #expect(pasteboard.copied == ["new"])
    #expect(model.isCopied)
    #expect(model.copyCount == 1)

    model.clearCopied()
    #expect(!model.isCopied)

    model.selectedID = "mid"
    model.copyID(from: memos)
    #expect(pasteboard.copied == ["new", "mid"])
    // Picking another memo drops the confirmation of the one before.
    model.selectedID = "old"
    #expect(!model.isCopied)
  }

  @Test("with no memo there is nothing to copy")
  func nothing() {
    model.copyID(from: [])
    #expect(pasteboard.copied.isEmpty)
    #expect(!model.isCopied)
  }

  @Test("the picker offers the ten newest")
  func pickerSize() {
    let many = (0..<25).map { MemoFactory.memo("m\($0)", age: Double($0)) }
    #expect(model.recent(many).count == 10)
    #expect(model.recent(many).first?.id == "m0")
  }

  @Test("the run id starts from what was saved and reports every change to the device log")
  func runID() {
    var seen: [String] = []
    let model = DiagnosticsModel(pasteboard: pasteboard, runID: "round-1", onRunIDChange: { seen.append($0) })
    #expect(model.runID == "round-1")
    #expect(seen.isEmpty, "a saved id is not a change")
    model.runID = "round-2"
    model.runID = "round-2"
    model.runID = ""
    #expect(seen == ["round-2", ""])
  }
}
