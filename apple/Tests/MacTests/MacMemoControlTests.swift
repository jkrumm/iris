import Foundation
import IrisCore
import Testing

@testable import IrisMac

@Suite("Mac memo controls")
struct MacMemoControlTests {
  @Test("every toolbar control and context-menu entry has a tooltip, and no two share one")
  func everyControlHasAHelp() {
    let helps = MacMemoControl.allCases.map(\.help)
    #expect(helps.allSatisfy { !$0.isEmpty })
    #expect(Set(helps).count == helps.count)
    #expect(!MacMemoControl.retry(from: "Summarize").isEmpty)
  }

  @Test("only a transcript memo with a transcript offers Copy on its row")
  @MainActor func rowCopy() async {
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let transcript = try? await api.memo(id: SampleData.transcriptThreadID).memo
    #expect(transcript?.macRowCopyText == transcript?.plainTranscript)
    #expect(transcript?.macRowCopyText?.isEmpty == false)
    let conversation = try? await api.memo(id: "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34").memo
    #expect(conversation?.mode == .hermes && conversation?.macRowCopyText == nil)
  }

  @Test("the speaker and the user's recording are told apart by name")
  func speakerVersusRecording() {
    #expect(MacMemoControl.readReply.help.localizedCaseInsensitiveContains("reply"))
    #expect(MacMemoControl.readReply.help.localizedCaseInsensitiveContains("summary"))
    #expect(MacMemoControl.readFull.help.localizedCaseInsensitiveContains("whole reply"))
    #expect(MacMemoControl.playRecording.help.localizedCaseInsensitiveContains("your recording"))
    #expect(!MacMemoControl.playRecording.help.localizedCaseInsensitiveContains("reply"))
  }
}
