#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct ComposerSnapshotTests {
    private static let choices = [
      ChipChoice(id: "auto", title: "Auto", systemImage: "sparkles"), ChipChoice(id: "journal", title: "Journal"),
      ChipChoice(id: "hermes", title: "Hermes"), ChipChoice(id: "chat", title: "Chat"),
      ChipChoice(id: "tab", title: "Tab", systemImage: "terminal"),
    ]

    @Test("the mode picker with Chat selected", .tags(.snapshot))
    func modes() {
      let chips = ChoiceChips(choices: Self.choices, selection: .constant("chat"))
        .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(chips, width: 390, height: 110)
    }

    @Test("the empty field shows its placeholder", .tags(.snapshot))
    func emptyField() {
      let field = ComposerField(text: .constant(""), placeholder: "What should Iris do?", counter: "0 characters")
        .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(field, width: 390, height: 280)
    }

    @Test("a typed memo with its counter", .tags(.snapshot))
    func filledField() {
      let field = ComposerField(
        text: .constant("Router bestellen und Netzwerkplan prüfen. Erinnere mich Freitag an die Rechnung."),
        placeholder: "What should Iris do?", counter: "82 characters"
      )
      .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(field, width: 390, height: 280)
    }
  }
#endif
