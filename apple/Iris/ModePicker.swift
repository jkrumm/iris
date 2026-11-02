import IrisCore
import IrisUI
import SwiftUI

/// The memo mode chips: the composer's picker and the record control's long press are this one component, each with the
/// modes it offers (a voice take cannot name a tab, so it leaves Tab out; a typed memo can).
struct ModePicker: View {
  let modes: [MemoMode]
  @Binding var selection: MemoMode

  var body: some View {
    ChoiceChips(
      choices: modes.map { ChipChoice(id: $0, title: $0.composerTitle, systemImage: $0.composerIcon) },
      selection: $selection)
  }
}

extension MemoMode {
  /// The modes a voice take offers: Chat and Transcribe included, Tab left out (the tab is named while speaking).
  static let voiceModes: [MemoMode] = [.auto, .journal, .hermes, .chat, .transcribe]

  var composerTitle: String {
    switch self {
    case .auto, .unknown: String(localized: "Auto", comment: "Memo mode")
    case .journal: String(localized: "Journal", comment: "Memo mode")
    case .hermes: String(localized: "Hermes", comment: "Memo mode")
    case .tab: String(localized: "Tab", comment: "Memo mode")
    case .chat: String(localized: "Chat", comment: "Memo mode")
    case .transcribe: String(localized: "Transcribe", comment: "Memo mode")
    }
  }

  /// One rule: every mode has a glyph of its own, so no chip of the row is bare and no two chips share one. Chat is the
  /// same speech bubble as the Chats chip on History.
  var composerIcon: String {
    switch self {
    case .auto, .unknown: "sparkles"
    case .journal: "book.closed"
    case .hermes: "paperplane"
    case .tab: "terminal"
    case .chat: "bubble.left"
    case .transcribe: "text.alignleft"
    }
  }

  /// One line on what the mode does with the memo, under the picker.
  var summary: String {
    switch self {
    case .auto, .unknown:
      String(localized: "Iris decides where it goes, and asks when it is unsure.", comment: "Memo mode summary")
    case .journal: String(localized: "Appended to today's journal.", comment: "Memo mode summary")
    case .hermes: String(localized: "Sent to Hermes as an instruction.", comment: "Memo mode summary")
    case .tab: String(localized: "Typed into a running agent tab.", comment: "Memo mode summary")
    case .chat:
      String(localized: "A plain conversation: an answer, no todo, no journal.", comment: "Memo mode summary")
    case .transcribe:
      String(localized: "Only the transcript: nothing is routed, answered or summarized.", comment: "Memo mode summary")
    }
  }
}
