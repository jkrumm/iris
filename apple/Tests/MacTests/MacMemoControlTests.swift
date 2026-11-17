import Foundation
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

  @Test("the speaker and the user's recording are told apart by name")
  func speakerVersusRecording() {
    #expect(MacMemoControl.readReply.help.localizedCaseInsensitiveContains("reply"))
    #expect(MacMemoControl.readReply.help.localizedCaseInsensitiveContains("summary"))
    #expect(MacMemoControl.readFull.help.localizedCaseInsensitiveContains("whole reply"))
    #expect(MacMemoControl.playRecording.help.localizedCaseInsensitiveContains("your recording"))
    #expect(!MacMemoControl.playRecording.help.localizedCaseInsensitiveContains("reply"))
  }
}
